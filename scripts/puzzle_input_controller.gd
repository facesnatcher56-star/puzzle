class_name PuzzleInputController
extends Node

# Turns mouse, keyboard and touch input into puzzle actions: picking up, dragging, rotating and dropping
# pieces, dragging pieces out of the bank, panning and zooming the camera, resizing the bank, and the
# enlarged hover/preview popup. It decides what a gesture means and asks the board, the network session and
# the camera to do it; it owns no puzzle state of its own beyond the gesture in progress.

var manager: PuzzleManager
var network: NetworkSession
var session: PuzzleSession
var board: PuzzleBoard
var camera: Camera2D
var bank: PieceBank
var reference: ReferenceWindow
var completion: CompletionController
var sfx: Sfx
var ui_root: Control
var ability_bar: AbilityBar

# gesture in progress
var dragging_table_id := -1
var drag_offset := Vector2.ZERO
var drag_start_position := Vector2.ZERO
var drag_start_rotation := 0
var mouse_panning := false
var resizing_bank := false
var bank_press_id := -1
var bank_press_screen := Vector2.ZERO
var bank_dragging := false
var selected_bank_id := -1
var fingers := {}
var touch_table_id := -1
var touch_panning := false
var pinch_distance := 0.0
var bank_scrolling := false

# popup showing an enlarged piece (hovering the bank or the board)
var hover_table_id := -1
var preview_panel: Panel
var preview_view: PuzzlePieceView
var drag_ghost: PuzzlePieceView

# finder glow while hovering/pressing the EDGES or CORNERS bank buttons
var highlight_timer: Timer
var hovering_filter_button := false

func _ready() -> void:
	highlight_timer = Timer.new()
	highlight_timer.one_shot = true
	highlight_timer.wait_time = 2.5
	highlight_timer.timeout.connect(func():
		if not hovering_filter_button:
			board.set_type_highlight(""))
	add_child(highlight_timer)

# Creates the preview popup under `parent` and wires up the bank's signals.
func attach_ui(parent: Control, piece_bank: PieceBank) -> void:
	ui_root = parent
	bank = piece_bank
	preview_panel = Panel.new()
	preview_panel.visible = false
	preview_panel.size = Vector2(278, 258)
	preview_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(preview_panel)
	bank.piece_hovered.connect(_on_bank_hovered)
	bank.piece_unhovered.connect(_on_bank_unhovered)
	bank.piece_pressed.connect(_on_bank_pressed)
	bank.action_requested.connect(on_bank_action)
	bank.action_hovered.connect(_on_bank_action_hovered)
	bank.action_unhovered.connect(_on_bank_action_unhovered)

# --- lifecycle hooks ---

# A new or restored puzzle replaced the old one: drop any gesture and popup tied to it.
func reset() -> void:
	dragging_table_id = -1
	selected_bank_id = -1
	bank_press_id = -1
	hide_preview()
	clear_ghost()

# A menu opened mid-drag: don't leave a piece glued to the cursor behind it.
func release_for_menu() -> void:
	if dragging_table_id >= 0:
		network.request_release(dragging_table_id, false)
		board.set_cluster_z(dragging_table_id, 0)
		dragging_table_id = -1
	touch_table_id = -1
	bank_press_id = -1
	clear_ghost()
	hide_preview()

func on_viewport_resized() -> void:
	if preview_panel != null and preview_panel.visible:
		preview_panel.position.x = clampf(preview_panel.position.x, 8, _viewport_size().x - preview_panel.size.x - 8)

# Keeps the hover popup in step with a piece that was just turned (by this player or a remote one).
func on_piece_changed(piece_id: int) -> void:
	var piece := manager.get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return
	if piece_id == hover_table_id and preview_view != null and not is_equal_approx(preview_view.rotation_degrees, float(piece.current_rotation)):
		show_preview(piece_id, get_viewport().get_mouse_position())

# --- coordinates ---

func _viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size

func is_table_screen(screen_position: Vector2) -> bool:
	if screen_position.y <= GameHud.HEIGHT or screen_position.y >= _viewport_size().y - bank.bank_height:
		return false
	# the ability bar floats over the bottom of the table; presses on it belong to it
	return ability_bar == null or not ability_bar.get_global_rect().has_point(screen_position)

func screen_to_world(screen_position: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_position

func zoom_at(screen_position: Vector2, multiplier: float) -> void:
	var before := screen_to_world(screen_position)
	var value := clampf(camera.zoom.x * multiplier, 0.15, 3.0)
	camera.zoom = Vector2.ONE * value
	var after := screen_to_world(screen_position)
	camera.position += before - after

# --- input entry point ---

# Called for every input event while no menu is open. (Escape and the menus are handled by the caller.)
func handle_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			rotate_selected()
		elif event.keycode >= KEY_1 and event.keycode <= KEY_4 and ability_bar != null:
			ability_bar.trigger_slot(event.keycode - KEY_1)
	if event is InputEventMagnifyGesture:
		zoom_at(event.position, event.factor)
		return
	if event is InputEventMouseButton:
		handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		handle_mouse_motion(event)
	elif event is InputEventScreenTouch:
		handle_touch(event)
	elif event is InputEventScreenDrag:
		handle_touch_drag(event)

func rotate_selected() -> void:
	var piece_id := dragging_table_id if dragging_table_id >= 0 else board.selected_id
	if piece_id >= 0 and network.request_rotate(piece_id) and dragging_table_id >= 0:
		# A joined cluster rotates around its middle, changing the held member's top-left position.
		# Refresh the grab offset so the next mouse motion does not jump it back under the cursor.
		drag_offset = screen_to_world(get_viewport().get_mouse_position()) - manager.get_piece(piece_id).current_position

func handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and dragging_table_id >= 0:
		if network.request_rotate(dragging_table_id):
			drag_offset = screen_to_world(event.position) - manager.get_piece(dragging_table_id).current_position
		return
	if reference.handle_mouse_button(event):
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed and is_table_screen(event.position):
		zoom_at(event.position, 1.12)
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed and is_table_screen(event.position):
		zoom_at(event.position, 1.0 / 1.12)
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		mouse_panning = event.pressed and is_table_screen(event.position)
		return
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and is_table_screen(event.position):
		var hit := board.pick(screen_to_world(event.position))
		if hit >= 0:
			board.select(hit)
			rotate_selected()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if not event.pressed:
		resizing_bank = false
		if bank_press_id >= 0:
			if bank_dragging and is_table_screen(event.position):
				place_bank_piece(bank_press_id, event.position)
			bank_press_id = -1
			clear_ghost()
		if dragging_table_id >= 0:
			drop_piece(dragging_table_id)
			board.select(-1 if manager.is_locked(dragging_table_id) else dragging_table_id) # a group that just joined the main puzzle is not left selected
			dragging_table_id = -1
		mouse_panning = false
		return
	if absf(event.position.x - _viewport_size().x * 0.5) < 42 and absf(event.position.y - bank.position.y) < 13 and not bank.collapsed:
		resizing_bank = true
		return
	if not is_table_screen(event.position):
		return
	if Input.is_action_pressed("pan_table"):
		mouse_panning = true
		return
	if selected_bank_id >= 0:
		place_bank_piece(selected_bank_id, event.position)
		return
	var world := screen_to_world(event.position)
	var picked := board.pick(world)
	if ability_bar != null and ability_bar.is_targeting():
		ability_bar.complete_targeting(picked) # the click chooses the power's target instead of picking anything up
		return
	board.select(picked)
	if picked >= 0 and network.request_pickup(picked):
		sfx.pickup()
		dragging_table_id = picked
		drag_start_position = manager.get_piece(picked).current_position
		drag_start_rotation = manager.get_piece(picked).current_rotation
		drag_offset = world - manager.get_piece(picked).current_position
		board.bring_cluster_forward(picked)
	elif picked < 0 or manager.is_locked(picked):
		mouse_panning = true # left-dragging empty table (or the locked board) moves the camera
		# (a locked section stays selected, so a power can be aimed at the main puzzle)

func handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if reference.handle_mouse_motion(event):
		return
	if resizing_bank:
		bank.set_height(_viewport_size().y - event.position.y)
		return
	if bank_press_id >= 0:
		if not bank_dragging and event.position.distance_to(bank_press_screen) > 8:
			start_bank_drag(event.position)
		if bank_dragging:
			update_ghost(event.position)
		return
	if mouse_panning:
		camera.position -= event.relative / camera.zoom.x
		hide_preview()
	elif dragging_table_id >= 0:
		network.request_move(dragging_table_id, screen_to_world(event.position) - drag_offset)
		hide_preview()
	else:
		update_table_hover(event.position)

func handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if reference.handle_touch_press(event, fingers.is_empty()):
			fingers[event.index] = event.position
			return
		fingers[event.index] = event.position
		if fingers.size() == 2:
			pinch_distance = _finger_distance()
			touch_panning = true
			return
		var from_grip := event.position - Vector2(_viewport_size().x * 0.5, bank.position.y)
		if absf(from_grip.x) < 60 and from_grip.y > -20 and from_grip.y < 10 and not bank.collapsed:
			resizing_bank = true
			return
		if not is_table_screen(event.position):
			return
		if selected_bank_id >= 0:
			place_bank_piece(selected_bank_id, event.position)
			return
		var world := screen_to_world(event.position)
		var picked := board.pick(world)
		if ability_bar != null and ability_bar.is_targeting():
			ability_bar.complete_targeting(picked)
			return
		board.select(picked)
		if event.double_tap and picked >= 0:
			rotate_selected()
			return
		if picked >= 0 and network.request_pickup(picked):
			touch_table_id = picked
			drag_start_position = manager.get_piece(picked).current_position
			drag_start_rotation = manager.get_piece(picked).current_rotation
			drag_offset = world - manager.get_piece(picked).current_position
			board.bring_cluster_forward(picked)
		else:
			touch_panning = true
	else:
		fingers.erase(event.index)
		reference.handle_touch_release(event.index)
		resizing_bank = false
		bank_scrolling = false
		if bank_press_id >= 0:
			if bank_dragging and is_table_screen(event.position):
				place_bank_piece(bank_press_id, event.position)
			bank_press_id = -1
			clear_ghost()
		if touch_table_id >= 0:
			drop_piece(touch_table_id)
			board.select(-1 if manager.is_locked(touch_table_id) else touch_table_id)
			touch_table_id = -1
		if fingers.is_empty():
			touch_panning = false
			pinch_distance = 0

func handle_touch_drag(event: InputEventScreenDrag) -> void:
	var previous: Vector2 = fingers.get(event.index, event.position - event.relative)
	fingers[event.index] = event.position
	if reference.handle_touch_drag(event):
		return
	if resizing_bank:
		bank.set_height(_viewport_size().y - event.position.y)
		return
	if bank_press_id >= 0:
		if bank_scrolling:
			bank.scroll.scroll_horizontal -= int(event.relative.x)
			return
		if not bank_dragging and event.position.distance_to(bank_press_screen) > 8:
			# A sideways swipe that stays in the bank scrolls it; anything else pulls the piece out.
			var delta := event.position - bank_press_screen
			if not is_table_screen(event.position) and absf(delta.x) > absf(delta.y):
				bank_scrolling = true
				selected_bank_id = -1
				bank.set_selected(-1)
				hide_preview()
				bank.scroll.scroll_horizontal -= int(delta.x)
				return
			start_bank_drag(event.position)
		if bank_dragging:
			update_ghost(event.position)
		return
	if fingers.size() >= 2:
		var midpoint := _finger_midpoint()
		var distance := _finger_distance()
		if pinch_distance > 10:
			zoom_at(midpoint, distance / pinch_distance)
		pinch_distance = distance
		camera.position -= (event.position - previous) * 0.5 / camera.zoom.x
	elif touch_table_id >= 0:
		network.request_move(touch_table_id, screen_to_world(event.position) - drag_offset)
	elif touch_panning and is_table_screen(event.position):
		camera.position -= event.relative / camera.zoom.x

func _finger_distance() -> float:
	var keys := fingers.keys()
	if keys.size() < 2:
		return 0
	return (fingers[keys[0]] as Vector2).distance_to(fingers[keys[1]])

func _finger_midpoint() -> Vector2:
	var keys := fingers.keys()
	return ((fingers[keys[0]] as Vector2) + (fingers[keys[1]] as Vector2)) * 0.5

# --- placing and dropping ---

func place_bank_piece(piece_id: int, screen_position: Vector2) -> void:
	var position := screen_to_world(screen_position) - manager.get_piece(piece_id).piece_size * 0.5
	if not network.request_place_from_bank(piece_id, position):
		return
	# request_place_from_bank synchronously emits piece_changed, which the board already used to create and
	# position the view -- creating another one here would leave a duplicate, orphaned copy behind.
	selected_bank_id = -1
	bank.set_selected(-1)
	hide_preview()
	board.select(piece_id)
	drop_piece(piece_id)
	board.select(piece_id)

# Ends a drag: nudges the group clear of anything it would hide, releases it (which snaps it to neighbours),
# then refreshes the stacking order and finder glow.
func drop_piece(piece_id: int) -> void:
	var attempted := true # a piece placed from the bank is a deliberate placement
	if piece_id == dragging_table_id or piece_id == touch_table_id:
		var piece := manager.get_piece(piece_id)
		attempted = piece.current_position.distance_to(drag_start_position) > minf(manager.cell_size.x, manager.cell_size.y) * 0.08 or piece.current_rotation != drag_start_rotation
	board.nudge_clear_of_covered(piece_id)
	completion.begin_drop(piece_id)
	network.request_release(piece_id, attempted)
	completion.end_drop()
	board.set_cluster_z(piece_id, 0)
	board.restack()
	board.refresh_type_highlight()

# --- dragging a piece out of the bank ---

func start_bank_drag(screen_position: Vector2) -> void:
	bank_dragging = true
	hide_preview()
	drag_ghost = PuzzleBoard.PIECE_SCENE.instantiate()
	ui_root.add_child(drag_ghost)
	var piece_size := manager.get_piece(bank_press_id).piece_size
	drag_ghost.setup(manager.get_piece(bank_press_id), session.source, piece_size)
	drag_ghost.modulate.a = 0.86
	update_ghost(screen_position)

func update_ghost(screen_position: Vector2) -> void:
	if drag_ghost == null:
		return
	var over_table := is_table_screen(screen_position)
	var piece_size := manager.get_piece(bank_press_id).piece_size
	var factor := camera.zoom.x if over_table else minf(85.0 / piece_size.x, 85.0 / piece_size.y)
	drag_ghost.place_centered(screen_position, factor)

func clear_ghost() -> void:
	if drag_ghost:
		drag_ghost.queue_free()
		drag_ghost = null
	bank_dragging = false

# --- bank buttons and tiles ---

func on_bank_action(action: String) -> void:
	if network.is_client() and action in ["spread", "reset", "new"]:
		return
	if action.begins_with("filter:"):
		bank.set_filter(action.trim_prefix("filter:"))
		# Touch has no hover, so a tap flashes the matching loose pieces for a moment instead.
		if action == "filter:EDGES" or action == "filter:CORNERS":
			board.set_type_highlight(action.trim_prefix("filter:"))
			highlight_timer.start()
	elif action == "assign_tray":
		if selected_bank_id >= 0 and manager.move_piece_to_tray(selected_bank_id, 1):
			bank.refresh()
	elif action == "spread":
		board.spread()
	elif action == "reset":
		session.start_puzzle(false)
	elif action == "new":
		session.start_puzzle(true)
	elif action == "reference":
		if reference.is_open():
			reference.close()
		else:
			reference.open()
			hide_preview()
	elif action == "collapse":
		bank.toggle_collapsed()
		hide_preview()

func _on_bank_action_hovered(action: String) -> void:
	if action == "filter:EDGES" or action == "filter:CORNERS":
		hovering_filter_button = true
		board.set_type_highlight(action.trim_prefix("filter:"))

func _on_bank_action_unhovered(action: String) -> void:
	if action == "filter:EDGES" or action == "filter:CORNERS":
		hovering_filter_button = false
		board.set_type_highlight("")

func _on_bank_hovered(piece_id: int, screen_position: Vector2) -> void:
	show_preview(piece_id, screen_position)

func _on_bank_unhovered(piece_id: int) -> void:
	if selected_bank_id != piece_id or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		hide_preview()

func _on_bank_pressed(piece_id: int, screen_position: Vector2) -> void:
	selected_bank_id = piece_id
	bank.set_selected(piece_id)
	bank_press_id = piece_id
	bank_press_screen = screen_position
	bank_dragging = false
	show_preview(piece_id, screen_position)

# --- the enlarged-piece popup ---

func show_preview(piece_id: int, screen_position: Vector2) -> void:
	var piece := manager.get_piece(piece_id)
	if piece == null:
		return
	if preview_view != null:
		preview_view.queue_free()
	preview_view = PuzzleBoard.PIECE_SCENE.instantiate()
	preview_panel.add_child(preview_view)
	preview_view.setup(piece, session.source, piece.piece_size)
	var factor := minf(170.0 / piece.piece_size.x, 170.0 / piece.piece_size.y)
	preview_view.place_centered(Vector2(139, 121), factor)
	_position_preview(piece.is_on_table, screen_position)
	preview_panel.visible = true
	preview_panel.move_to_front()

func _position_preview(on_table: bool, screen_position: Vector2) -> void:
	var width := _viewport_size().x
	if on_table:
		# Hovering a piece on the board: float the enlarged view beside the cursor instead of above the bank.
		var x := screen_position.x + 32
		if x + 278 > width - 8:
			x = screen_position.x - 32 - 278
		var max_y := maxf(60.0, bank.position.y - 266.0)
		preview_panel.position = Vector2(clampf(x, 8, width - 286), clampf(screen_position.y - 129, 60, max_y))
	else:
		preview_panel.position = Vector2(clampf(screen_position.x - 139, 8, width - 286), bank.position.y - 270)

# `menu_open` blocks hovering while a menu covers the board.
func update_table_hover(screen_position: Vector2, menu_open: bool = false) -> void:
	var piece_id := -1
	var blocked := menu_open or (reference.is_open() and reference.window_rect().has_point(screen_position))
	if not blocked and is_table_screen(screen_position):
		piece_id = board.pick(screen_to_world(screen_position))
	if piece_id < 0:
		if hover_table_id >= 0:
			hide_preview()
		return
	if piece_id != hover_table_id:
		show_preview(piece_id, screen_position)
		hover_table_id = piece_id
	elif preview_panel.visible:
		_position_preview(true, screen_position)

func hide_preview() -> void:
	hover_table_id = -1
	if preview_panel:
		preview_panel.visible = false
	if preview_view:
		preview_view.queue_free()
		preview_view = null
