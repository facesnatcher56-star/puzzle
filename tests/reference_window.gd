extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("REFERENCE WINDOW TEST FAILED: " + message)

func _press(window: ReferenceWindow, position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = position
	window.handle_mouse_button(event)

func _motion(window: ReferenceWindow, from: Vector2, to: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = to
	event.relative = to - from
	window.handle_mouse_motion(event)

# Presses at `start`, drags by `delta`, releases; returns the window's rect afterwards.
func _drag(window: ReferenceWindow, start: Vector2, delta: Vector2) -> Rect2:
	_press(window, start, true)
	_motion(window, start, start + delta)
	_press(window, start + delta, false)
	return window.window_rect()

func _run() -> void:
	var window := ReferenceWindow.new(load("res://assets/emberbound.png"))
	root.add_child(window)
	await process_frame
	window.open()
	window.panel.size = Vector2(500, 400)
	window.panel.position = Vector2(400, 200)
	window.relayout()
	var rect := window.window_rect()
	var middle := rect.get_center()
	var right := _drag(window, Vector2(rect.end.x - 2, middle.y), Vector2(80, 0))
	_check(is_equal_approx(right.size.x, rect.size.x + 80) and right.position == rect.position, "the right edge widens it")
	rect = window.window_rect()
	var left := _drag(window, Vector2(rect.position.x + 2, rect.get_center().y), Vector2(-60, 0))
	_check(is_equal_approx(left.size.x, rect.size.x + 60) and is_equal_approx(left.end.x, rect.end.x), "the left edge widens it and keeps the right side fixed")
	rect = window.window_rect()
	var top := _drag(window, Vector2(rect.get_center().x, rect.position.y + 2), Vector2(0, 50))
	_check(is_equal_approx(top.size.y, rect.size.y - 50) and is_equal_approx(top.end.y, rect.end.y), "the top edge shortens it and keeps the bottom fixed")
	rect = window.window_rect()
	var corner := _drag(window, Vector2(rect.position.x + 2, rect.end.y - 2), Vector2(-40, 70))
	_check(is_equal_approx(corner.size.x, rect.size.x + 40) and is_equal_approx(corner.size.y, rect.size.y + 70) and is_equal_approx(corner.end.x, rect.end.x), "the bottom-left corner resizes both ways")
	rect = window.window_rect()
	var tiny := _drag(window, Vector2(rect.end.x - 2, rect.end.y - 2), Vector2(-5000, -5000))
	_check(tiny.size.x >= ReferenceWindow.MIN_SIZE.x - 0.01 and tiny.size.y >= ReferenceWindow.MIN_SIZE.y - 0.01 and tiny.size.x < 200, "it can be made small, but never smaller than the minimum")
	rect = window.window_rect()
	var moved := _drag(window, Vector2(rect.position.x + 40, rect.position.y + 10), Vector2(30, 20))
	_check(moved.size == rect.size and moved.position != rect.position, "the title bar still moves it")
	# the picture is fitted to the window, and the wheel zooms toward the pointer
	window.panel.size = Vector2(500, 400)
	window.relayout()
	rect = window.window_rect()
	var area := window.image_area.get_global_rect()
	_check(window.image_view.size.x <= area.size.x + 0.5 and window.image_view.size.y <= area.size.y + 0.5, "the picture fits inside the window at first")
	var image_at_first := window.image_view.get_global_rect()
	var pointer := image_at_first.position + image_at_first.size * Vector2(0.5, 0.3)
	var fraction_before := (pointer - window.image_view.get_global_rect().position) / window.image_view.size
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = pointer
	for i in range(4):
		_check(window.handle_mouse_button(wheel), "the wheel over the window is handled by it")
	_check(window.zoom > 1.5 and window.image_view.size.x > image_at_first.size.x * 1.5, "wheel up zooms in")
	var fraction_after := (pointer - window.image_view.get_global_rect().position) / window.image_view.size
	_check(fraction_after.distance_to(fraction_before) < 0.01, "...toward the pointer: the spot under it stays put")
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	for i in range(12):
		window.handle_mouse_button(wheel)
	_check(is_equal_approx(window.zoom, 1.0), "wheel down zooms back out to the fitted picture")
	wheel.position = Vector2(2, 2) # outside the window
	var zoom_before := window.zoom
	_check(not window.handle_mouse_button(wheel) and window.zoom == zoom_before, "the wheel outside the window is left to the board")
	if failures > 0:
		quit(1)
		return
	print("REFERENCE WINDOW TEST PASSED")
	quit()
