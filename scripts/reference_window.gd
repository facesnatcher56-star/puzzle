class_name ReferenceWindow
extends Control

# A non-modal floating panel showing the finished picture. It is laid out manually (not via containers) so
# drag/resize/zoom math has a single source of truth for its geometry, and it keeps whatever position, size
# and zoom the player left it at across toggles. Everything about it lives here; the board only asks it
# whether an input event was consumed.

const TITLE_HEIGHT := 32.0
const GRIP_SIZE := 18.0
const MIN_SIZE := Vector2(140, 110)
const EDGE := 9.0 # how close to the border a press must be to resize from that edge
const LEFT := 1
const RIGHT := 2
const TOP := 4
const BOTTOM := 8

var texture: Texture2D
var panel: Panel
var title_bar: Control
var close_button: Button
var image_area: Control
var image_view: TextureRect
var grip: ColorRect
var positioned := false
var dragging := false
var resizing := false
var panning := false
var resize_edges := 0
var resize_start_rect := Rect2()
var resize_start_mouse := Vector2.ZERO
var zoom := 1.0
var touch_index := -1

func _init(initial_texture: Texture2D = null) -> void:
	texture = initial_texture

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	panel = Panel.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	title_bar = Control.new()
	title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_child(title_bar)
	var title := Label.new()
	title.text = "REFERENCE IMAGE  (drag to move)"
	title.add_theme_font_size_override("font_size", 15)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.offset_left = 10
	title_bar.add_child(title)

	close_button = Button.new()
	close_button.text = "×"
	close_button.tooltip_text = "Close"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(close)
	panel.add_child(close_button)

	image_area = Control.new()
	image_area.clip_contents = true
	image_area.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_child(image_area)
	image_view = TextureRect.new()
	image_view.texture = texture
	image_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE # sized by _update_image_layout, not by the picture's own size
	image_view.stretch_mode = TextureRect.STRETCH_SCALE
	image_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image_area.add_child(image_view)

	grip = ColorRect.new()
	grip.color = Color(1, 1, 1, 0.18)
	grip.mouse_filter = Control.MOUSE_FILTER_STOP
	grip.tooltip_text = "Drag any edge or corner to resize"
	panel.add_child(grip)

	panel.size = Vector2(560, 460)
	relayout()

# --- public interface ---

func open() -> void:
	visible = true

func close() -> void:
	visible = false

func is_open() -> bool:
	return visible

# Shows a different picture: closes the window and resets its zoom.
func set_image(new_texture: Texture2D) -> void:
	texture = new_texture
	if image_view == null:
		return
	image_view.texture = new_texture
	visible = false
	zoom = 1.0
	image_view.position = Vector2.ZERO
	_update_image_layout()
	_clamp_pan()

func window_rect() -> Rect2:
	return panel.get_global_rect()

# Keeps the window's size/position inside the viewport without resetting where the player left it,
# then re-lays-out its children from that size. Call when the viewport size changes.
func relayout() -> void:
	if panel == null:
		return
	var viewport_size := get_viewport_rect().size
	var max_size := Vector2(maxf(MIN_SIZE.x, viewport_size.x - 24), maxf(MIN_SIZE.y, viewport_size.y - 72))
	panel.size = Vector2(minf(panel.size.x, max_size.x), minf(panel.size.y, max_size.y))
	if not positioned:
		panel.position = ((viewport_size - panel.size) * 0.5).max(Vector2(12, 60))
		positioned = true
	panel.position = Vector2(
		clampf(panel.position.x, 12, maxf(12, viewport_size.x - panel.size.x - 12)),
		clampf(panel.position.y, 60, maxf(60, viewport_size.y - panel.size.y - 12))
	)
	_layout_children()

# Press/release/wheel. Returns true if the event was consumed (so board interaction underneath is skipped)
# even when it wasn't a drag/resize/pan start -- e.g. a click on blank panel padding shouldn't also pick up a piece.
func handle_mouse_button(event: InputEventMouseButton) -> bool:
	if not visible:
		return false
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if event.pressed and _image_rect().has_point(event.position):
			_zoom_at(event.position, 1.2 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.2)
			return true
		return window_rect().has_point(event.position)
	if event.button_index != MOUSE_BUTTON_LEFT:
		return window_rect().has_point(event.position)
	if not event.pressed:
		var was_active := dragging or resizing or panning
		_end_interaction()
		return was_active or window_rect().has_point(event.position)
	return _begin_interaction(event.position)

# Returns true while a drag/resize/pan started in this window is in progress (the board must ignore the motion).
func handle_mouse_motion(event: InputEventMouseMotion) -> bool:
	if visible and panel != null and not (dragging or resizing or panning):
		panel.mouse_default_cursor_shape = _cursor_for(_edges_at(event.position))
	return _drive(event.relative, event.position)

# A touch that lands on the window. `no_other_fingers` is false during a multi-finger gesture on the board.
func handle_touch_press(event: InputEventScreenTouch, no_other_fingers: bool) -> bool:
	if not visible or not no_other_fingers:
		return false
	if _begin_interaction(event.position):
		touch_index = event.index
		return true
	return false

func handle_touch_drag(event: InputEventScreenDrag) -> bool:
	if event.index != touch_index:
		return false
	_drive(event.relative, event.position)
	return true

func handle_touch_release(index: int) -> void:
	if index == touch_index:
		_end_interaction()
		touch_index = -1

# --- internals ---

func _begin_interaction(position: Vector2) -> bool:
	var edges := _edges_at(position)
	if edges != 0:
		resizing = true
		resize_edges = edges
		resize_start_rect = window_rect()
		resize_start_mouse = position
		return true
	if _title_rect().has_point(position):
		dragging = true
		return true
	if _image_rect().has_point(position):
		panning = true
		return true
	return window_rect().has_point(position)

func _end_interaction() -> void:
	dragging = false
	resizing = false
	panning = false

func _drive(relative: Vector2, position: Vector2) -> bool:
	if dragging:
		panel.position += relative
		relayout()
		return true
	if resizing:
		var delta := position - resize_start_mouse
		var rect := resize_start_rect
		if resize_edges & LEFT:
			var right := rect.end.x
			rect.position.x = minf(rect.position.x + delta.x, right - MIN_SIZE.x)
			rect.size.x = right - rect.position.x
		if resize_edges & RIGHT:
			rect.size.x = maxf(MIN_SIZE.x, rect.size.x + delta.x)
		if resize_edges & TOP:
			var bottom := rect.end.y
			rect.position.y = minf(rect.position.y + delta.y, bottom - MIN_SIZE.y)
			rect.size.y = bottom - rect.position.y
		if resize_edges & BOTTOM:
			rect.size.y = maxf(MIN_SIZE.y, rect.size.y + delta.y)
		panel.position = rect.position
		panel.size = rect.size
		relayout()
		return true
	if panning:
		_pan_image(relative)
		return true
	return false

func _layout_children() -> void:
	var size := panel.size
	title_bar.position = Vector2.ZERO
	title_bar.size = Vector2(size.x, TITLE_HEIGHT)
	close_button.size = Vector2(26, 26)
	close_button.position = Vector2(size.x - 32, 3)
	image_area.position = Vector2(6, TITLE_HEIGHT + 4)
	image_area.size = Vector2(size.x - 12, size.y - TITLE_HEIGHT - 12)
	grip.position = Vector2(size.x - GRIP_SIZE - 3, size.y - GRIP_SIZE - 3)
	grip.size = Vector2(GRIP_SIZE, GRIP_SIZE)
	_update_image_layout()
	_clamp_pan()

func _update_image_layout() -> void:
	if image_area == null or texture == null:
		return
	var area_size := image_area.size
	var tex_size := texture.get_size()
	if area_size.x <= 0 or area_size.y <= 0 or tex_size.x <= 0 or tex_size.y <= 0:
		return
	var fit := minf(area_size.x / tex_size.x, area_size.y / tex_size.y)
	image_view.size = tex_size * fit * zoom

func _clamp_pan() -> void:
	var area_size := image_area.size
	var display_size := image_view.size
	var pos := image_view.position
	if display_size.x <= area_size.x:
		pos.x = (area_size.x - display_size.x) * 0.5
	else:
		pos.x = clampf(pos.x, area_size.x - display_size.x, 0.0)
	if display_size.y <= area_size.y:
		pos.y = (area_size.y - display_size.y) * 0.5
	else:
		pos.y = clampf(pos.y, area_size.y - display_size.y, 0.0)
	image_view.position = pos

func _pan_image(relative: Vector2) -> void:
	image_view.position += relative
	_clamp_pan()

# Keeps the point under the cursor fixed on screen while the zoom level changes,
# the same trick the board camera uses.
func _zoom_at(screen_position: Vector2, multiplier: float) -> void:
	var area_pos := image_area.get_global_rect().position
	var old_size := image_view.size
	var fraction := (screen_position - area_pos - image_view.position) / old_size
	zoom = clampf(zoom * multiplier, 1.0, 8.0)
	_update_image_layout()
	image_view.position = screen_position - area_pos - fraction * image_view.size
	_clamp_pan()

# Which borders of the window a point is on (a bitmask of LEFT/RIGHT/TOP/BOTTOM; corners are two); 0 = none.
func _edges_at(position: Vector2) -> int:
	var rect := window_rect()
	if not rect.grow(EDGE * 0.5).has_point(position):
		return 0
	var edges := 0
	if position.x <= rect.position.x + EDGE:
		edges |= LEFT
	elif position.x >= rect.end.x - EDGE:
		edges |= RIGHT
	if position.y <= rect.position.y + EDGE:
		edges |= TOP
	elif position.y >= rect.end.y - EDGE:
		edges |= BOTTOM
	if _grip_rect().has_point(position):
		edges = RIGHT | BOTTOM
	# the close button keeps its own corner
	if close_button.get_global_rect().has_point(position):
		return 0
	return edges

func _cursor_for(edges: int) -> Control.CursorShape:
	match edges:
		LEFT, RIGHT: return Control.CURSOR_HSIZE
		TOP, BOTTOM: return Control.CURSOR_VSIZE
		LEFT | TOP, RIGHT | BOTTOM: return Control.CURSOR_FDIAGSIZE
		RIGHT | TOP, LEFT | BOTTOM: return Control.CURSOR_BDIAGSIZE
	return Control.CURSOR_ARROW

func _title_rect() -> Rect2:
	return title_bar.get_global_rect()

func _image_rect() -> Rect2:
	return image_area.get_global_rect()

func _grip_rect() -> Rect2:
	return grip.get_global_rect()
