extends Node2D

const SOURCE_IMAGE: Texture2D = preload("res://assets/emberbound.png")
const PIECE_SCENE: PackedScene = preload("res://scenes/puzzle_piece.tscn")
const BOARD_SIZE := Vector2(1122, 1402)
const SIZES := [Vector2i(4, 6), Vector2i(6, 8), Vector2i(8, 12), Vector2i(10, 25)]

@onready var camera: Camera2D = $Camera2D
@onready var piece_layer: Node2D = $Pieces
@onready var ui_layer: CanvasLayer = $UI

var manager := PuzzleManager.new()
var source: Texture2D = SOURCE_IMAGE
var columns := 8
var rows := 6
var cell := Vector2(132, 117.333)
var seed_value := 52813
var table_views := {}
var selected_table_id := -1
var dragging_table_id := -1
var drag_offset := Vector2.ZERO
var mouse_panning := false
var resizing_bank := false
var bank_press_id := -1
var bank_press_screen := Vector2.ZERO
var bank_dragging := false
var selected_bank_id := -1
var fingers := {}
var touch_table_id := -1
var touch_last := Vector2.ZERO
var touch_panning := false
var pinch_distance := 0.0
var bank_scrolling := false
var rotation_enabled := true

var ui_root: Control
var bank: PieceBank
var preview_panel: Panel
var preview_view: PuzzlePieceView
var drag_ghost: PuzzlePieceView
var reference_overlay: Control
var reference_panel: PanelContainer
var complete_banner: PanelContainer
var complete_label: Label
var rotation_button: Button
var size_picker: OptionButton
var top_hint: Label

func _ready() -> void:
	_apply_mobile_scale()
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if source == null:
		push_error("Bundled puzzle image failed to load: res://assets/emberbound.png")
		return
	manager.piece_changed.connect(_on_piece_changed)
	manager.bank_changed.connect(func(): bank.refresh())
	manager.pieces_joined.connect(_on_pieces_joined)
	manager.puzzle_completed.connect(_on_completed)
	_build_ui()
	_start_puzzle(false)
	get_viewport().size_changed.connect(_on_viewport_resized)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if reference_overlay != null and reference_overlay.visible:
			reference_overlay.visible = false
		else:
			get_tree().quit()

# Phones report a large pixel canvas, which shrinks the 1280x800 layout to unreadable
# sizes. Scale the UI so the base layout maps to roughly 1.2 logical units per dp.
func _apply_mobile_scale() -> void:
	if not OS.has_feature("mobile"):
		return
	var screen := Vector2(DisplayServer.window_get_size())
	var dpi := maxf(DisplayServer.screen_get_dpi(), 120)
	var stretch := minf(screen.x / 1280.0, screen.y / 800.0)
	var target_height := clampf(screen.y * 160.0 / dpi * 1.2, 500, 800)
	get_window().content_scale_factor = maxf(1.0, screen.y / (stretch * target_height))

func _draw() -> void:
	draw_rect(Rect2(Vector2(-5000, -5000), Vector2(10000, 10000)), Color("293a3e"), true)
	for x in range(-4800, 5000, 160):
		draw_line(Vector2(x, -5000), Vector2(x, 5000), Color(1, 1, 1, 0.014), 1)
	for y in range(-4800, 5000, 160):
		draw_line(Vector2(-5000, y), Vector2(5000, y), Color(1, 1, 1, 0.014), 1)
	var board := Rect2(-BOARD_SIZE * 0.5, BOARD_SIZE)
	draw_rect(board.grow(17), Color(0.05, 0.08, 0.09, 0.45), true)
	draw_rect(board.grow(7), Color("ab9e83"), true)
	draw_rect(board, Color("637374"), true)
	draw_rect(board, Color("d5c8aa"), false, 3)

func _start_puzzle(new_seed: bool) -> void:
	if new_seed:
		seed_value += 1
	for child in piece_layer.get_children():
		child.queue_free()
	table_views.clear()
	selected_table_id = -1
	dragging_table_id = -1
	selected_bank_id = -1
	bank_press_id = -1
	_hide_preview()
	_clear_ghost()
	var grid: Vector2i = SIZES[size_picker.selected]
	columns = grid.x
	rows = grid.y
	cell = Vector2(BOARD_SIZE.x / columns, BOARD_SIZE.y / rows)
	var generated := PuzzleGenerator.generate(source, columns, rows, seed_value, BOARD_SIZE, rotation_enabled)
	if generated.size() != columns * rows:
		push_error("Puzzle generation failed: expected %d pieces, got %d" % [columns * rows, generated.size()])
		return
	manager.configure(generated, cell, columns, rows)
	if bank.collapsed:
		bank.toggle_collapsed()
	bank.configure(generated, source, cell, seed_value)
	complete_banner.visible = false
	_fit_camera()
	queue_redraw()

func _fit_camera() -> void:
	var viewport_size := get_viewport_rect().size
	var available := Vector2(viewport_size.x - 64, viewport_size.y - bank.bank_height - 85)
	var fit := minf(available.x / BOARD_SIZE.x, available.y / BOARD_SIZE.y)
	camera.zoom = Vector2.ONE * fit
	camera.position = Vector2(0, (bank.bank_height - 53) * 0.5 / fit)

func _build_ui() -> void:
	ui_root = Control.new()
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(ui_root)
	var top_bg := ColorRect.new()
	top_bg.color = Color("17252dcc")
	top_bg.anchor_right = 1
	top_bg.offset_bottom = 53
	top_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	ui_root.add_child(top_bg)
	var top := HBoxContainer.new()
	top.position = Vector2(15, 9)
	top.anchor_right = 1
	top.offset_right = -20
	top.offset_bottom = 36
	top.add_theme_constant_override("separation", 9)
	top_bg.add_child(top)
	var title := Label.new()
	title.text = "EMBERBOUND JIGSAW"
	title.add_theme_font_size_override("font_size", 19)
	title.add_theme_color_override("font_color", Color("f4e5c3"))
	title.custom_minimum_size.x = 180
	top.add_child(title)
	var size_label := Label.new()
	size_label.text = "PIECES"
	size_label.add_theme_font_size_override("font_size", 12)
	top.add_child(size_label)
	size_picker = OptionButton.new()
	size_picker.focus_mode = Control.FOCUS_NONE
	for grid in SIZES:
		size_picker.add_item(str(grid.x * grid.y))
	size_picker.select(3)
	size_picker.item_selected.connect(func(_index: int): _start_puzzle(false))
	top.add_child(size_picker)
	var rotation_toggle := CheckButton.new()
	rotation_toggle.text = "Rotation"
	rotation_toggle.button_pressed = rotation_enabled
	rotation_toggle.tooltip_text = "Random quarter-turns. Changing this restarts the puzzle."
	rotation_toggle.focus_mode = Control.FOCUS_NONE
	rotation_toggle.toggled.connect(_set_rotation_enabled)
	top.add_child(rotation_toggle)
	rotation_button = Button.new()
	rotation_button.text = "↻ Rotate (R)"
	rotation_button.visible = rotation_enabled
	rotation_button.pressed.connect(_rotate_selected)
	top.add_child(rotation_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	top_hint = Label.new()
	top_hint.text = "Match touching edges anywhere  •  Drag joined groups  •  Wheel zoom"
	if DisplayServer.is_touchscreen_available():
		top_hint.text = "Pinch to zoom  •  Double-tap to rotate  •  Swipe bank to scroll"
	top_hint.add_theme_color_override("font_color", Color("b8c8c8"))
	top_hint.add_theme_font_size_override("font_size", 12)
	top_hint.visible = get_viewport_rect().size.x >= 1050
	top.add_child(top_hint)
	bank = PieceBank.new()
	ui_root.add_child(bank)
	bank.piece_hovered.connect(_on_bank_hovered)
	bank.piece_unhovered.connect(_on_bank_unhovered)
	bank.piece_pressed.connect(_on_bank_pressed)
	bank.action_requested.connect(_on_bank_action)
	preview_panel = Panel.new()
	preview_panel.visible = false
	preview_panel.size = Vector2(278, 258)
	preview_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(preview_panel)
	complete_banner = PanelContainer.new()
	complete_banner.visible = false
	complete_banner.anchor_left = 0.5
	complete_banner.anchor_right = 0.5
	complete_banner.offset_left = -285
	complete_banner.offset_right = 285
	complete_banner.offset_top = 65
	complete_banner.offset_bottom = 121
	ui_root.add_child(complete_banner)
	var complete_row := HBoxContainer.new()
	complete_row.add_theme_constant_override("separation", 12)
	complete_banner.add_child(complete_row)
	complete_label = Label.new()
	complete_label.add_theme_color_override("font_color", Color("f6e0ac"))
	complete_row.add_child(complete_label)
	var restart := Button.new()
	restart.text = "Restart"
	restart.pressed.connect(func(): _start_puzzle(false))
	complete_row.add_child(restart)
	var next := Button.new()
	next.text = "New puzzle"
	next.pressed.connect(func(): _start_puzzle(true))
	complete_row.add_child(next)
	_build_reference()

func _build_reference() -> void:
	reference_overlay = Control.new()
	reference_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	reference_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	reference_overlay.visible = false
	ui_root.add_child(reference_overlay)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.04, 0.05, 0.8)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	reference_overlay.add_child(shade)
	reference_panel = PanelContainer.new()
	reference_panel.anchor_left = 0.5
	reference_panel.anchor_right = 0.5
	reference_panel.anchor_top = 0.5
	reference_panel.anchor_bottom = 0.5
	reference_overlay.add_child(reference_panel)
	_layout_reference()
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 10)
	reference_panel.add_child(stack)
	var bar := HBoxContainer.new()
	stack.add_child(bar)
	var title := Label.new()
	title.text = "REFERENCE IMAGE"
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)
	var close := Button.new()
	close.text = "Close  ×"
	close.pressed.connect(func(): reference_overlay.visible = false)
	bar.add_child(close)
	var image := TextureRect.new()
	image.texture = source
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	image.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(image)

func _on_viewport_resized() -> void:
	_layout_reference()
	# Android settles its immersive window size after launch; refit so the board starts fully visible.
	if OS.has_feature("mobile"):
		_fit_camera()
	top_hint.visible = get_viewport_rect().size.x >= 1050
	if preview_panel.visible:
		preview_panel.position.x = clampf(preview_panel.position.x, 8, get_viewport_rect().size.x - preview_panel.size.x - 8)

func _layout_reference() -> void:
	if reference_panel == null:
		return
	var viewport_size := get_viewport_rect().size
	var panel_size := Vector2(minf(950, viewport_size.x - 32), minf(700, viewport_size.y - 80))
	reference_panel.offset_left = -panel_size.x * 0.5
	reference_panel.offset_right = panel_size.x * 0.5
	reference_panel.offset_top = -panel_size.y * 0.5
	reference_panel.offset_bottom = panel_size.y * 0.5

func _on_bank_action(action: String) -> void:
	if action.begins_with("filter:"):
		bank.set_filter(action.trim_prefix("filter:"))
	elif action == "assign_tray":
		if selected_bank_id >= 0 and manager.move_piece_to_tray(selected_bank_id, 1):
			bank.refresh()
	elif action == "spread":
		_spread_table_pieces()
	elif action == "reset":
		_start_puzzle(false)
	elif action == "new":
		_start_puzzle(true)
	elif action == "reference":
		reference_overlay.visible = true
		_hide_preview()
	elif action == "collapse":
		bank.toggle_collapsed()
		_hide_preview()

func _on_bank_hovered(piece_id: int, screen_position: Vector2) -> void:
	_show_preview(piece_id, screen_position)

func _on_bank_unhovered(piece_id: int) -> void:
	if selected_bank_id != piece_id or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_hide_preview()

func _on_bank_pressed(piece_id: int, screen_position: Vector2) -> void:
	selected_bank_id = piece_id
	bank.set_selected(piece_id)
	bank_press_id = piece_id
	bank_press_screen = screen_position
	bank_dragging = false
	_show_preview(piece_id, screen_position)

func _show_preview(piece_id: int, screen_position: Vector2) -> void:
	var piece := manager.get_piece(piece_id)
	if piece == null or piece.is_on_table:
		return
	if preview_view != null:
		preview_view.queue_free()
	preview_view = PIECE_SCENE.instantiate()
	preview_panel.add_child(preview_view)
	preview_view.setup(piece, source, cell)
	var factor := minf(213.0 / cell.x, 213.0 / cell.y)
	preview_view.place_centered(Vector2(139, 121), factor)
	var width := get_viewport_rect().size.x
	preview_panel.position = Vector2(clampf(screen_position.x - 139, 8, width - 286), bank.position.y - 270)
	preview_panel.visible = true
	preview_panel.move_to_front()

func _hide_preview() -> void:
	if preview_panel:
		preview_panel.visible = false
	if preview_view:
		preview_view.queue_free()
		preview_view = null

func _start_bank_drag(screen_position: Vector2) -> void:
	bank_dragging = true
	_hide_preview()
	drag_ghost = PIECE_SCENE.instantiate()
	ui_root.add_child(drag_ghost)
	drag_ghost.setup(manager.get_piece(bank_press_id), source, cell)
	drag_ghost.modulate.a = 0.86
	_update_ghost(screen_position)

func _update_ghost(screen_position: Vector2) -> void:
	if drag_ghost == null:
		return
	var over_table := _is_table_screen(screen_position)
	var factor := camera.zoom.x if over_table else minf(85.0 / cell.x, 85.0 / cell.y)
	drag_ghost.place_centered(screen_position, factor)

func _clear_ghost() -> void:
	if drag_ghost:
		drag_ghost.queue_free()
		drag_ghost = null
	bank_dragging = false

func _is_table_screen(screen_position: Vector2) -> bool:
	return screen_position.y > 53 and screen_position.y < get_viewport_rect().size.y - bank.bank_height

func _screen_to_world(screen_position: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_position

func _zoom_at(screen_position: Vector2, multiplier: float) -> void:
	var before := _screen_to_world(screen_position)
	var value := clampf(camera.zoom.x * multiplier, 0.15, 3.0)
	camera.zoom = Vector2.ONE * value
	var after := _screen_to_world(screen_position)
	camera.position += before - after

func _input(event: InputEvent) -> void:
	# Touch is handled directly; mouse events emulated from touch exist only so GUI buttons respond.
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			reference_overlay.visible = false
		elif event.keycode == KEY_R and rotation_enabled:
			_rotate_selected()
	if reference_overlay.visible:
		return
	if event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_touch_drag(event)

func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed and _is_table_screen(event.position):
		_zoom_at(event.position, 1.12)
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed and _is_table_screen(event.position):
		_zoom_at(event.position, 1.0 / 1.12)
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		mouse_panning = event.pressed and _is_table_screen(event.position)
		return
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and rotation_enabled and _is_table_screen(event.position):
		var hit := _pick_table_piece(_screen_to_world(event.position))
		if hit >= 0:
			_select_table_piece(hit)
			_rotate_selected()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if not event.pressed:
		resizing_bank = false
		if bank_press_id >= 0:
			if bank_dragging and _is_table_screen(event.position):
				_place_bank_piece(bank_press_id, event.position)
			bank_press_id = -1
			_clear_ghost()
		if dragging_table_id >= 0:
			manager.request_release(dragging_table_id)
			_set_cluster_z(dragging_table_id, 0)
			_select_table_piece(dragging_table_id)
			dragging_table_id = -1
		mouse_panning = false
		return
	if absf(event.position.x - get_viewport_rect().size.x * 0.5) < 42 and absf(event.position.y - bank.position.y) < 13 and not bank.collapsed:
		resizing_bank = true
		return
	if not _is_table_screen(event.position):
		return
	if Input.is_action_pressed("pan_table"):
		mouse_panning = true
		return
	if selected_bank_id >= 0:
		_place_bank_piece(selected_bank_id, event.position)
		return
	var world := _screen_to_world(event.position)
	var picked := _pick_table_piece(world)
	_select_table_piece(picked)
	if picked >= 0 and manager.request_pickup(picked):
		dragging_table_id = picked
		drag_offset = world - manager.get_piece(picked).current_position
		_bring_cluster_forward(picked)

func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if resizing_bank:
		bank.set_height(get_viewport_rect().size.y - event.position.y)
		return
	if bank_press_id >= 0:
		if not bank_dragging and event.position.distance_to(bank_press_screen) > 8:
			_start_bank_drag(event.position)
		if bank_dragging:
			_update_ghost(event.position)
		return
	if mouse_panning:
		camera.position -= event.relative / camera.zoom.x
	elif dragging_table_id >= 0:
		manager.request_move(dragging_table_id, _screen_to_world(event.position) - drag_offset)

func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		fingers[event.index] = event.position
		if fingers.size() == 2:
			pinch_distance = _finger_distance()
			touch_panning = true
			return
		var from_grip := event.position - Vector2(get_viewport_rect().size.x * 0.5, bank.position.y)
		if absf(from_grip.x) < 60 and from_grip.y > -20 and from_grip.y < 10 and not bank.collapsed:
			resizing_bank = true
			return
		if not _is_table_screen(event.position):
			return
		if selected_bank_id >= 0:
			_place_bank_piece(selected_bank_id, event.position)
			return
		var world := _screen_to_world(event.position)
		var picked := _pick_table_piece(world)
		_select_table_piece(picked)
		if event.double_tap and picked >= 0 and rotation_enabled:
			_rotate_selected()
			return
		if picked >= 0 and manager.request_pickup(picked):
			touch_table_id = picked
			drag_offset = world - manager.get_piece(picked).current_position
			_bring_cluster_forward(picked)
		else:
			touch_panning = true
		touch_last = event.position
	else:
		fingers.erase(event.index)
		resizing_bank = false
		bank_scrolling = false
		if bank_press_id >= 0:
			if bank_dragging and _is_table_screen(event.position):
				_place_bank_piece(bank_press_id, event.position)
			bank_press_id = -1
			_clear_ghost()
		if touch_table_id >= 0:
			manager.request_release(touch_table_id)
			_set_cluster_z(touch_table_id, 0)
			_select_table_piece(touch_table_id)
			touch_table_id = -1
		if fingers.is_empty():
			touch_panning = false
			pinch_distance = 0

func _handle_touch_drag(event: InputEventScreenDrag) -> void:
	var previous: Vector2 = fingers.get(event.index, event.position - event.relative)
	fingers[event.index] = event.position
	if resizing_bank:
		bank.set_height(get_viewport_rect().size.y - event.position.y)
		return
	if bank_press_id >= 0:
		if bank_scrolling:
			bank.scroll.scroll_horizontal -= int(event.relative.x)
			return
		if not bank_dragging and event.position.distance_to(bank_press_screen) > 8:
			# A sideways swipe that stays in the bank scrolls it; anything else pulls the piece out.
			var delta := event.position - bank_press_screen
			if not _is_table_screen(event.position) and absf(delta.x) > absf(delta.y):
				bank_scrolling = true
				selected_bank_id = -1
				bank.set_selected(-1)
				_hide_preview()
				bank.scroll.scroll_horizontal -= int(delta.x)
				return
			_start_bank_drag(event.position)
		if bank_dragging:
			_update_ghost(event.position)
		return
	if fingers.size() >= 2:
		var midpoint := _finger_midpoint()
		var distance := _finger_distance()
		if pinch_distance > 10:
			_zoom_at(midpoint, distance / pinch_distance)
		pinch_distance = distance
		camera.position -= (event.position - previous) * 0.5 / camera.zoom.x
	elif touch_table_id >= 0:
		manager.request_move(touch_table_id, _screen_to_world(event.position) - drag_offset)
	elif touch_panning and _is_table_screen(event.position):
		camera.position -= event.relative / camera.zoom.x

func _finger_distance() -> float:
	var keys := fingers.keys()
	if keys.size() < 2:
		return 0
	return (fingers[keys[0]] as Vector2).distance_to(fingers[keys[1]])

func _finger_midpoint() -> Vector2:
	var keys := fingers.keys()
	return ((fingers[keys[0]] as Vector2) + (fingers[keys[1]] as Vector2)) * 0.5

func _pick_table_piece(world: Vector2) -> int:
	var children := piece_layer.get_children()
	for i in range(children.size() - 1, -1, -1):
		var view := children[i] as PuzzlePieceView
		if view != null and view.hit_test(world):
			return view.data.piece_id
	return -1

func _select_table_piece(piece_id: int) -> void:
	for view in table_views.values():
		view.set_selected(false)
	selected_table_id = piece_id
	if piece_id >= 0:
		for member_id in manager.cluster_members(piece_id):
			if table_views.has(member_id):
				table_views[member_id].set_selected(true)

func _bring_cluster_forward(piece_id: int) -> void:
	for member_id in manager.cluster_members(piece_id):
		if table_views.has(member_id):
			table_views[member_id].move_to_front()
			table_views[member_id].z_index = 10

func _set_cluster_z(piece_id: int, value: int) -> void:
	for member_id in manager.cluster_members(piece_id):
		if table_views.has(member_id):
			table_views[member_id].z_index = value

func _place_bank_piece(piece_id: int, screen_position: Vector2) -> void:
	var position := _screen_to_world(screen_position) - cell * 0.5
	if not manager.request_place_from_bank(piece_id, position):
		return
	var view: PuzzlePieceView = PIECE_SCENE.instantiate()
	piece_layer.add_child(view)
	view.setup(manager.get_piece(piece_id), source, cell)
	view.position = position
	table_views[piece_id] = view
	_on_piece_changed(piece_id)
	selected_bank_id = -1
	bank.set_selected(-1)
	_hide_preview()
	_select_table_piece(piece_id)
	manager.request_release(piece_id)
	_select_table_piece(piece_id)

func _on_piece_changed(piece_id: int) -> void:
	var piece := manager.get_piece(piece_id)
	if table_views.has(piece_id):
		var view: PuzzlePieceView = table_views[piece_id]
		view.place_centered(piece.current_position + cell * 0.5)

func _on_pieces_joined(_cluster_id: int, member_ids: Array) -> void:
	bank.update_counts()
	for member_id in member_ids:
		if table_views.has(member_id):
			var view: PuzzlePieceView = table_views[member_id]
			view.modulate = Color(1.18, 1.10, 0.85)
			create_tween().tween_property(view, "modulate", Color.WHITE, 0.28)

func _rotate_selected() -> void:
	if rotation_enabled and selected_table_id >= 0:
		manager.request_rotate(selected_table_id)

func _spread_table_pieces() -> void:
	var group_ids := manager.clusters.keys()
	if group_ids.is_empty():
		return
	group_ids.sort()
	var origin := Vector2(BOARD_SIZE.x * 0.62, -BOARD_SIZE.y * 0.42)
	var cursor := origin
	var row_height := 0.0
	var available_width := BOARD_SIZE.x * 1.7
	var gap := minf(cell.x, cell.y) * 0.72
	for group_id in group_ids:
		var members: Array = manager.clusters[group_id]
		var first: PuzzlePieceState = manager.pieces[members[0]]
		var bounds := Rect2(first.current_position + cell * 0.5, Vector2.ZERO)
		for member_id in members:
			var member: PuzzlePieceState = manager.pieces[member_id]
			for point in member.outline:
				var world_point := member.current_position + cell * 0.5 + (point - cell * 0.5).rotated(deg_to_rad(member.current_rotation))
				bounds = bounds.expand(world_point)
		if cursor.x > origin.x and cursor.x + bounds.size.x > origin.x + available_width:
			cursor = Vector2(origin.x, cursor.y + row_height)
			row_height = 0
		manager.request_move(first.piece_id, first.current_position + cursor - bounds.position)
		cursor.x += bounds.size.x + gap
		row_height = maxf(row_height, bounds.size.y + gap)

func _on_completed() -> void:
	_select_table_piece(-1)
	bank.toggle_collapsed() if not bank.collapsed else null
	var seconds := manager.elapsed_seconds()
	complete_label.text = "Puzzle Complete  •  %02d:%02d" % [seconds / 60, seconds % 60]
	complete_banner.visible = true

func _set_rotation_enabled(value: bool) -> void:
	rotation_enabled = value
	rotation_button.visible = value
	_start_puzzle(false)
