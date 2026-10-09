extends SceneTree

var failures := 0
var events := []
var menus := 0
var backs := 0
var zooms := []

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("GAMEPAD TEST FAILED: " + message)

func _run() -> void:
	var camera := Camera2D.new()
	root.add_child(camera)
	var pad := GamepadController.new()
	pad.camera = camera
	pad.sink = func(e): events.append(e)
	pad.zoom_at = func(at, factor): zooms.append([at, factor])
	pad.is_table = func(at): return at.y > 100
	var playing := [true]
	pad.enabled = func(): return playing[0]
	pad.menu_pressed.connect(func(): menus += 1)
	pad.back_pressed.connect(func(): backs += 1)
	root.add_child(pad)
	await process_frame
	var size := root.get_visible_rect().size
	pad._wake()
	pad.cursor = size * 0.5
	var start := pad.cursor
	# the stick moves the cursor and says so as a mouse motion
	pad.step(0.1, Vector2(0.1, 0), Vector2.ZERO, 0.0, 0.0)
	_check(pad.cursor == start and events.is_empty(), "a stick inside the dead zone does nothing")
	pad.step(0.1, Vector2(1, 0), Vector2.ZERO, 0.0, 0.0)
	_check(pad.cursor.x > start.x + 50 and pad.cursor.y == start.y and events.size() == 1 and events[0] is InputEventMouseMotion and events[0].position == pad.cursor, "the left stick moves the cursor and sends a mouse motion")
	_check(events[0].device == GamepadController.DEVICE, "the events are marked as the controller's own")
	var half := GamepadController.shape(Vector2(0.6, 0)).length()
	_check(half < 0.35 and GamepadController.shape(Vector2(1, 0)).length() == 1.0, "small tilts are fine moves, full tilt is full speed")
	for i in range(100):
		pad.step(0.1, Vector2(1, 1), Vector2.ZERO, 0.0, 0.0)
	_check(pad.cursor == size, "the cursor stays inside the window")
	# A is a left click, held for a drag
	events.clear()
	pad.press(JOY_BUTTON_A, true)
	_check(events.size() == 1 and events[0] is InputEventMouseButton and events[0].pressed and events[0].button_index == MOUSE_BUTTON_LEFT and events[0].position == pad.cursor, "A presses the left button at the cursor")
	pad.press(JOY_BUTTON_A, true)
	_check(events.size() == 1, "...once")
	pad.step(0.1, Vector2(-1, 0), Vector2.ZERO, 0.0, 0.0)
	_check(events.back() is InputEventMouseMotion and events.back().button_mask == MOUSE_BUTTON_MASK_LEFT, "moving with A held is a drag")
	pad.press(JOY_BUTTON_A, false)
	_check(events.back() is InputEventMouseButton and not events.back().pressed, "letting go of A releases it")
	# the slow modifier
	var before := pad.cursor
	pad.step(0.1, Vector2(1, 0), Vector2.ZERO, 0.0, 0.0)
	var fast := pad.cursor.x - before.x
	pad._precise = true
	before = pad.cursor
	pad.step(0.1, Vector2(1, 0), Vector2.ZERO, 0.0, 0.0)
	_check(pad.cursor.x - before.x < fast * 0.5, "holding LB slows the cursor")
	pad._precise = false
	# right stick pans, triggers zoom
	camera.position = Vector2.ZERO
	var panned := Vector2.ZERO
	camera.zoom = Vector2.ONE * 2.0
	pad.step(0.1, Vector2.ZERO, Vector2(1, 0), 0.0, 0.0)
	_check(camera.position.x > 20.0 and camera.position.y == 0.0, "the right stick pans the board (less when zoomed in)")
	pad.cursor = Vector2(300, 400)
	pad.step(0.1, Vector2.ZERO, Vector2.ZERO, 1.0, 0.0)
	_check(zooms.size() == 1 and zooms[0][1] > 1.0 and zooms[0][0] == pad.cursor, "the right trigger zooms in around the cursor")
	pad.step(0.1, Vector2.ZERO, Vector2.ZERO, 0.0, 1.0)
	_check(zooms.size() == 2 and zooms[1][1] < 1.0, "the left trigger zooms out")
	pad.cursor = Vector2(300, 40)
	pad.step(0.1, Vector2.ZERO, Vector2.ZERO, 1.0, 0.0)
	_check(zooms.size() == 2, "zooming only works over the table")
	# over the piece bank the sticks and bumpers work the bank instead
	var scrolled := []
	var pages := []
	var trays := []
	pad.over_bank = func(at): return at.y > 600
	pad.bank_scroll = func(px): scrolled.append(px)
	pad.bank_page = func(d): pages.append(d)
	pad.bank_tray = func(d): trays.append(d)
	pad.cursor = Vector2(300, 700)
	panned = camera.position
	pad.step(0.1, Vector2.ZERO, Vector2(1, 0), 0.0, 0.0)
	_check(scrolled.size() == 1 and scrolled[0] > 0.0 and camera.position == panned, "over the bank the right stick scrolls the pieces, not the board")
	pad.step(0.1, Vector2.ZERO, Vector2(-1, 0), 0.0, 0.0)
	_check(scrolled.back() < 0.0, "...in both directions")
	pad.step(0.1, Vector2.ZERO, Vector2.ZERO, 1.0, 0.0)
	pad.step(0.1, Vector2.ZERO, Vector2.ZERO, 1.0, 0.0)
	_check(pages == [1] and zooms.size() == 2, "a trigger pulls one page along (once per pull), without zooming")
	pad.step(0.1, Vector2.ZERO, Vector2.ZERO, 0.0, 0.0)
	pad.step(0.1, Vector2.ZERO, Vector2.ZERO, 0.0, 1.0)
	_check(pages == [1, -1], "...and the other trigger a page back")
	events.clear()
	pad.press(JOY_BUTTON_RIGHT_SHOULDER, true)
	pad.press(JOY_BUTTON_LEFT_SHOULDER, true)
	_check(trays == [1, -1] and events.is_empty(), "over the bank the bumpers switch tray and do not turn a piece")
	pad.cursor = Vector2(300, 400)
	# buttons
	events.clear()
	pad.press(JOY_BUTTON_RIGHT_SHOULDER, true)
	_check(events.size() == 2 and events[0] is InputEventKey and events[0].keycode == KEY_R and events[0].pressed, "RB turns the piece (the R key)")
	events.clear()
	pad.press(JOY_BUTTON_DPAD_UP, true)
	_check(events.size() == 2 and events[0].keycode == KEY_2, "the D-pad triggers abilities")
	pad.press(JOY_BUTTON_START, true)
	pad.press(JOY_BUTTON_B, true)
	_check(menus == 1 and backs == 1, "Start opens the menu and B goes back")
	# with a menu open the game buttons are left alone, but A still clicks
	playing[0] = false
	events.clear()
	panned = camera.position
	pad.press(JOY_BUTTON_RIGHT_SHOULDER, true)
	pad.step(0.1, Vector2.ZERO, Vector2(1, 0), 1.0, 0.0)
	_check(events.is_empty() and camera.position == panned and zooms.size() == 2, "in a menu the board is not turned, panned or zoomed")
	pad.press(JOY_BUTTON_A, true)
	_check(events.size() == 1 and events[0] is InputEventMouseButton, "...but A still clicks")
	print("gamepad test done, failures: ", failures)
	for child in root.get_children():
		child.free()
	quit(1 if failures > 0 else 0)
