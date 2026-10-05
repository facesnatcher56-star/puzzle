extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("INTERACTION TEST FAILED: " + message)

func _mouse_button(position: Vector2, pressed: bool, button: int = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = button
	event.pressed = pressed
	root.push_input(event, true)

func _mouse_motion(position: Vector2, relative: Vector2 = Vector2.ZERO) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = relative
	root.push_input(event, true)

func _touch(position: Vector2, pressed: bool, index: int = 0) -> void:
	var event := InputEventScreenTouch.new()
	event.position = position
	event.pressed = pressed
	event.index = index
	root.push_input(event, true)

func _touch_drag(position: Vector2, relative: Vector2, index: int = 0) -> void:
	var event := InputEventScreenDrag.new()
	event.position = position
	event.relative = relative
	event.index = index
	root.push_input(event, true)

func _double_tap(position: Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.position = position
	event.pressed = true
	event.double_tap = true
	root.push_input(event, true)
	_touch(position, false)

func _run() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var game: Node2D = scene.instantiate()
	root.add_child(game)
	game.lobby.hide_menu()
	game.session.size_index = 1
	game.session.random_rotation = false
	game.session.start_puzzle(false)
	await process_frame
	await process_frame
	var bank_item: PieceBankItem = game.bank.row.get_child(0)
	var first_id := bank_item.piece_id
	var bank_point := bank_item.global_position + Vector2(45, 50)
	_mouse_motion(bank_point)
	await process_frame
	_check(game.input_controller.preview_panel.visible, "hover opens preview")
	_mouse_motion(Vector2(500, 300))
	await process_frame
	_check(not game.input_controller.preview_panel.visible, "leaving thumbnail closes preview")
	_mouse_button(bank_point, true)
	_mouse_button(bank_point, false)
	await process_frame
	_check(game.input_controller.selected_bank_id == first_id, "click selects bank piece")
	var drop_point := Vector2(760, 390)
	_mouse_button(drop_point, true)
	_mouse_button(drop_point, false)
	await process_frame
	_check(game.manager.pieces[first_id].is_on_table, "second click places selected piece")
	var piece_position: Vector2 = game.manager.pieces[first_id].current_position
	var grab: Vector2 = game.get_viewport().get_canvas_transform() * (piece_position + game.manager.pieces[first_id].piece_size * 0.5)
	_mouse_button(grab, true)
	_mouse_motion(grab + Vector2(45, 20), Vector2(45, 20))
	_mouse_button(grab + Vector2(45, 20), false)
	await process_frame
	_check(game.manager.pieces[first_id].current_position.distance_to(piece_position) > 20, "table drag moves piece")
	var zoom_before: float = game.camera.zoom.x
	_mouse_button(Vector2(600, 300), true, MOUSE_BUTTON_WHEEL_UP)
	await process_frame
	_check(game.camera.zoom.x > zoom_before, "wheel zooms")
	var pan_before: Vector2 = game.camera.position
	_mouse_button(Vector2(600, 300), true, MOUSE_BUTTON_MIDDLE)
	_mouse_motion(Vector2(640, 300), Vector2(40, 0))
	_mouse_button(Vector2(640, 300), false, MOUSE_BUTTON_MIDDLE)
	await process_frame
	_check(game.camera.position.distance_to(pan_before) > 20, "middle drag pans")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_SPACE
	key.pressed = true
	Input.parse_input_event(key)
	await process_frame
	_check(Input.is_action_pressed("pan_table"), "Space input mapping activates")
	var space_pan_before: Vector2 = game.camera.position
	_mouse_button(Vector2(100, 220), true)
	_mouse_motion(Vector2(140, 220), Vector2(40, 0))
	_mouse_button(Vector2(140, 220), false)
	var key_release := InputEventKey.new()
	key_release.physical_keycode = KEY_SPACE
	key_release.pressed = false
	Input.parse_input_event(key_release)
	await process_frame
	_check(game.camera.position.distance_to(space_pan_before) > 20, "Space and left drag pans")
	var next_item: PieceBankItem = game.bank.row.get_child(0)
	var second_id := next_item.piece_id
	var next_point := next_item.global_position + Vector2(45, 50)
	_mouse_button(next_point, true)
	_mouse_motion(Vector2(860, 380), Vector2(860, 380) - next_point)
	_mouse_button(Vector2(860, 380), false)
	await process_frame
	_check(game.manager.pieces[second_id].is_on_table, "bank drag places piece")
	var touch_item: PieceBankItem = game.bank.row.get_child(0)
	var third_id := touch_item.piece_id
	var touch_point := touch_item.global_position + Vector2(45, 50)
	_touch(touch_point, true)
	_touch(touch_point, false)
	await process_frame
	_check(game.input_controller.selected_bank_id == third_id, "touch selects bank piece")
	_touch(Vector2(980, 390), true)
	_touch(Vector2(980, 390), false)
	await process_frame
	_check(game.manager.pieces[third_id].is_on_table, "touch tap places piece")
	var touch_piece_before: Vector2 = game.manager.pieces[third_id].current_position
	var touch_grab: Vector2 = game.get_viewport().get_canvas_transform() * (touch_piece_before + game.manager.pieces[third_id].piece_size * 0.5)
	_touch(touch_grab, true)
	_touch_drag(touch_grab + Vector2(35, 15), Vector2(35, 15))
	_touch(touch_grab + Vector2(35, 15), false)
	await process_frame
	_check(game.manager.pieces[third_id].current_position.distance_to(touch_piece_before) > 20, "one finger drags table piece")
	var drag_touch_item: PieceBankItem = game.bank.row.get_child(0)
	var fourth_id := drag_touch_item.piece_id
	var drag_touch_start := drag_touch_item.global_position + Vector2(45, 50)
	_touch(drag_touch_start, true)
	_touch_drag(Vector2(1050, 370), Vector2(1050, 370) - drag_touch_start)
	_touch(Vector2(1050, 370), false)
	await process_frame
	_check(game.manager.pieces[fourth_id].is_on_table, "one finger drags bank piece onto table")
	var touch_pan_before: Vector2 = game.camera.position
	_touch(Vector2(150, 230), true)
	_touch_drag(Vector2(200, 230), Vector2(50, 0))
	_touch(Vector2(200, 230), false)
	await process_frame
	_check(game.camera.position.distance_to(touch_pan_before) > 20, "one finger pans empty table")
	var pinch_before: float = game.camera.zoom.x
	_touch(Vector2(200, 280), true, 0)
	_touch(Vector2(300, 280), true, 1)
	_touch_drag(Vector2(340, 280), Vector2(40, 0), 1)
	_touch(Vector2(200, 280), false, 0)
	_touch(Vector2(340, 280), false, 1)
	await process_frame
	_check(game.camera.zoom.x > pinch_before, "pinch zooms")
	var height_before: float = game.bank.bank_height
	var handle := Vector2(640, game.bank.position.y)
	_mouse_button(handle, true)
	_mouse_motion(handle + Vector2(0, -40), Vector2(0, -40))
	_mouse_button(handle + Vector2(0, -40), false)
	await process_frame
	_check(game.bank.bank_height > height_before + 30, "bank grip resizes bank")
	game.session.start_puzzle(false)
	var group_start := Vector2(430, 300)
	game.input_controller.place_bank_piece(0, group_start)
	game.input_controller.place_bank_piece(1, group_start + Vector2(game.manager.pieces[0].piece_size.x * game.camera.zoom.x + 3, 0))
	await process_frame
	_check(game.manager.cluster_members(0).size() == 2, "two bank pieces join away from board target")
	_check(game.board.views[0].selected and game.board.views[1].selected, "joined group selection is visible")
	var group_before: Vector2 = game.manager.pieces[0].current_position
	var member_before: Vector2 = game.manager.pieces[1].current_position
	var group_grab: Vector2 = game.get_viewport().get_canvas_transform() * (member_before + game.manager.pieces[1].piece_size * 0.5)
	_mouse_button(group_grab, true)
	_mouse_motion(group_grab + Vector2(60, 25), Vector2(60, 25))
	_mouse_button(group_grab + Vector2(60, 25), false)
	await process_frame
	var group_delta: Vector2 = game.manager.pieces[0].current_position - group_before
	var member_delta: Vector2 = game.manager.pieces[1].current_position - member_before
	_check(group_delta.length() > 30 and group_delta.distance_to(member_delta) < 0.01, "dragging a joined piece moves both views together")
	var touch_group_before: Vector2 = game.manager.pieces[0].current_position
	var touch_member_before: Vector2 = game.manager.pieces[1].current_position
	var touch_group_grab: Vector2 = game.get_viewport().get_canvas_transform() * (touch_group_before + game.manager.pieces[0].piece_size * 0.5)
	_touch(touch_group_grab, true)
	_touch_drag(touch_group_grab + Vector2(30, -20), Vector2(30, -20))
	_touch(touch_group_grab + Vector2(30, -20), false)
	await process_frame
	var touch_group_delta: Vector2 = game.manager.pieces[0].current_position - touch_group_before
	var touch_member_delta: Vector2 = game.manager.pieces[1].current_position - touch_member_before
	_check(touch_group_delta.length() > 20 and touch_group_delta.distance_to(touch_member_delta) < 0.01, "touch dragging a joined piece moves group")
	var emulated := InputEventMouseButton.new()
	emulated.device = InputEvent.DEVICE_ID_EMULATION
	emulated.button_index = MOUSE_BUTTON_WHEEL_UP
	emulated.pressed = true
	emulated.position = Vector2(600, 300)
	var emulated_zoom_before: float = game.camera.zoom.x
	root.push_input(emulated, true)
	await process_frame
	_check(is_equal_approx(game.camera.zoom.x, emulated_zoom_before), "mouse events emulated from touch are ignored")
	var swipe_item: PieceBankItem = game.bank.row.get_child(2)
	var swipe_start := swipe_item.global_position + Vector2(45, 50)
	game.bank.scroll.scroll_horizontal = 0
	_touch(swipe_start, true)
	_touch_drag(swipe_start + Vector2(-60, 0), Vector2(-60, 0))
	_touch_drag(swipe_start + Vector2(-120, 0), Vector2(-60, 0))
	_touch(swipe_start + Vector2(-120, 0), false)
	await process_frame
	_check(game.bank.scroll.scroll_horizontal > 60, "sideways swipe scrolls the bank")
	_check(not game.manager.pieces[swipe_item.piece_id].is_on_table and game.input_controller.selected_bank_id == -1, "bank swipe neither places nor selects a piece")
	var touch_height_before: float = game.bank.bank_height
	var touch_grip := Vector2(game.get_viewport_rect().size.x * 0.5 + 30, game.bank.position.y - 5)
	_touch(touch_grip, true)
	_touch_drag(touch_grip + Vector2(0, 40), Vector2(0, 40))
	_touch(touch_grip + Vector2(0, 40), false)
	await process_frame
	_check(game.bank.bank_height < touch_height_before - 30, "touch on bank grip resizes bank")
	game.session.random_rotation = true
	game.session.start_puzzle(false)
	await process_frame
	var tap_point := Vector2(700, 300)
	game.input_controller.place_bank_piece(game.bank.row.get_child(0).piece_id, tap_point)
	var tap_id: int = game.board.selected_id
	var rotation_before: int = game.manager.pieces[tap_id].current_rotation
	var tap_grab: Vector2 = game.get_viewport().get_canvas_transform() * (game.manager.pieces[tap_id].current_position + game.manager.pieces[tap_id].piece_size * 0.5)
	_touch(tap_grab, true)
	_touch(tap_grab, false)
	_double_tap(tap_grab)
	await process_frame
	_check(game.manager.pieces[tap_id].current_rotation != rotation_before, "double-tap rotates a table piece")
	if failures == 0:
		print("INTERACTION TEST PASSED: free cluster join/drag, bank click/drag/resize, wheel/Space/middle pan, touch select/drag/place/pan/pinch/swipe/grip/double-tap")
	quit(0 if failures == 0 else 1)
