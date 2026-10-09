class_name GamepadController
extends Node

# Plays the game with a controller (Steam Deck, Xbox, PlayStation, ...). It drives a virtual mouse cursor and sends
# the same mouse and key events a player would, so the board, the bank, the menus and the ability bar all work
# without knowing a controller exists.
#
#   left stick     move the cursor            (hold LB for slow, precise moves)
#   A              press: pick up / press a button; hold to drag a piece; release to drop it
#   right stick    pan the board; over the piece bank, scroll along the row of pieces
#   triggers       zoom in (RT) and out (LT) around the cursor; over the bank, a page back or forward
#   RB or X        turn the held or selected piece; over the bank, LB and RB switch tray (ALL, EDGE, CORNER, TRAY 1)
#   D-pad          abilities 1-4 (left, up, right, down)
#   Y              the reference picture
#   B              back: cancel an aimed power, close the picture, step back through a menu
#   Start          pause menu
#
# The cursor is drawn here and the system one hidden while a controller is being used; moving a real mouse hands
# control straight back. (Under Steam Input the controller must be using a gamepad layout, not a mouse/keyboard one.)

signal back_pressed
signal menu_pressed
signal reference_pressed

const DEADZONE := 0.22
const CURSOR_SPEED := 950.0 # pixels per second at full tilt (a squared response keeps small moves fine)
const PRECISE_FACTOR := 0.3
const PAN_SPEED := 900.0 # screen pixels per second
const BANK_SCROLL_SPEED := 1500.0 # pixels per second along the bank
const ZOOM_PER_SECOND := 2.2 # the zoom factor per second with a trigger fully pulled
const DEVICE := 4242 # marks the events made here, so they are not mistaken for a real mouse

var camera: Camera2D
var enabled := Callable() # () -> bool : the board is being played (no menu open); menus still get the cursor and A
var is_table := Callable() # (screen position) -> bool : the position is over the table, where zooming applies
var zoom_at := Callable() # (screen position, factor)
var over_bank := Callable() # (screen position) -> bool : the position is over the piece bank
var bank_scroll := Callable() # (pixels) : slide the bank's row of pieces
var bank_page := Callable() # (direction) : a screenful along the row
var bank_tray := Callable() # (step) : the next or previous tray
var sink := Callable() # (event) : where events go; the viewport by default

var cursor := Vector2.ZERO
var active := false # a controller was used more recently than the mouse
var _a_down := false
var _precise := false
var _page_latched := false
var _view: Control
var _layer: CanvasLayer

func _ready() -> void:
	process_priority = -10
	_layer = CanvasLayer.new()
	_layer.layer = 100
	add_child(_layer)
	_view = _CursorView.new()
	_view.owner_controller = self
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_view.visible = false
	_layer.add_child(_view)

func _process(delta: float) -> void:
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		return
	var left := Vector2.ZERO
	var right := Vector2.ZERO
	var trigger_in := 0.0
	var trigger_out := 0.0
	for pad in pads:
		left += Vector2(Input.get_joy_axis(pad, JOY_AXIS_LEFT_X), Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y))
		right += Vector2(Input.get_joy_axis(pad, JOY_AXIS_RIGHT_X), Input.get_joy_axis(pad, JOY_AXIS_RIGHT_Y))
		trigger_in = maxf(trigger_in, Input.get_joy_axis(pad, JOY_AXIS_TRIGGER_RIGHT))
		trigger_out = maxf(trigger_out, Input.get_joy_axis(pad, JOY_AXIS_TRIGGER_LEFT))
		_precise = Input.is_joy_button_pressed(pad, JOY_BUTTON_LEFT_SHOULDER)
	step(delta, left, right, trigger_in, trigger_out)

# --- movement ---

static func shape(stick: Vector2) -> Vector2:
	var length := stick.length()
	if length < DEADZONE:
		return Vector2.ZERO
	var scaled := (minf(length, 1.0) - DEADZONE) / (1.0 - DEADZONE)
	return stick / length * scaled * scaled # squared: fine control near the centre, full speed at the edge

func _viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size

# Applies one frame of stick and trigger positions.
func step(delta: float, left: Vector2, right: Vector2, trigger_in: float, trigger_out: float) -> void:
	var move := shape(left)
	var pan := shape(right)
	var zoom_amount := (trigger_in if trigger_in > DEADZONE else 0.0) - (trigger_out if trigger_out > DEADZONE else 0.0)
	if move == Vector2.ZERO and pan == Vector2.ZERO and zoom_amount == 0.0:
		_page_latched = false
		return
	_wake()
	var moved := false
	if move != Vector2.ZERO:
		var before := cursor
		cursor = (cursor + move * CURSOR_SPEED * (PRECISE_FACTOR if _precise else 1.0) * delta).clamp(Vector2.ZERO, _viewport_size())
		moved = cursor != before
		if moved:
			_motion(cursor - before)
	if _playing():
		var changed := false
		if _over_bank():
			if pan != Vector2.ZERO and bank_scroll.is_valid():
				bank_scroll.call((pan.x + pan.y) * BANK_SCROLL_SPEED * delta)
			if absf(zoom_amount) < 0.3:
				_page_latched = false
			elif absf(zoom_amount) > 0.6 and not _page_latched and bank_page.is_valid():
				_page_latched = true
				bank_page.call(1 if zoom_amount > 0.0 else -1)
			zoom_amount = 0.0
			pan = Vector2.ZERO
		if pan != Vector2.ZERO and camera != null:
			camera.position += pan * PAN_SPEED * delta / camera.zoom.x
			changed = true
		if zoom_amount != 0.0 and zoom_at.is_valid() and (not is_table.is_valid() or is_table.call(cursor)):
			zoom_at.call(cursor, pow(ZOOM_PER_SECOND, zoom_amount * delta))
			changed = true
		if changed and not moved:
			_motion(Vector2.ZERO) # a held piece or the hover follows the board moving under the cursor
	_view.queue_redraw()

func _over_bank() -> bool:
	return over_bank.is_valid() and bool(over_bank.call(cursor))

# --- buttons ---

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.device != DEVICE and event.device != InputEvent.DEVICE_ID_EMULATION:
		if active:
			active = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			_view.visible = false
		return
	if event is InputEventJoypadButton:
		if press(event.button_index, event.pressed):
			get_viewport().set_input_as_handled() # the built-in ui_accept etc. must not act as well
	elif event is InputEventJoypadMotion and (event.axis == JOY_AXIS_LEFT_X or event.axis == JOY_AXIS_LEFT_Y) and absf(event.axis_value) > DEADZONE:
		get_viewport().set_input_as_handled() # the stick moves the cursor, not the menu focus

# One button going down or up. True if it is one of ours.
func press(button: int, pressed: bool) -> bool:
	if button == JOY_BUTTON_A:
		_wake()
		if pressed != _a_down:
			_a_down = pressed
			_click(pressed)
		return true
	if (button == JOY_BUTTON_LEFT_SHOULDER or button == JOY_BUTTON_RIGHT_SHOULDER) and _playing() and _over_bank() and bank_tray.is_valid():
		if pressed:
			bank_tray.call(1 if button == JOY_BUTTON_RIGHT_SHOULDER else -1)
		return true
	if button == JOY_BUTTON_LEFT_SHOULDER:
		return true
	if button == JOY_BUTTON_START:
		if pressed:
			menu_pressed.emit()
		return true
	if button == JOY_BUTTON_B:
		if pressed:
			back_pressed.emit()
		return true
	if not _playing():
		return false
	match button:
		JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_X:
			if pressed:
				_key(KEY_R)
		JOY_BUTTON_DPAD_LEFT:
			if pressed:
				_key(KEY_1)
		JOY_BUTTON_DPAD_UP:
			if pressed:
				_key(KEY_2)
		JOY_BUTTON_DPAD_RIGHT:
			if pressed:
				_key(KEY_3)
		JOY_BUTTON_DPAD_DOWN:
			if pressed:
				_key(KEY_4)
		JOY_BUTTON_Y:
			if pressed:
				reference_pressed.emit()
		_:
			return false
	_wake()
	return true

# --- sending events ---

func _playing() -> bool:
	return not enabled.is_valid() or bool(enabled.call())

# The first use of the controller (or of a mouse afterwards) takes over the cursor.
func _wake() -> void:
	if active:
		return
	active = true
	var mouse := get_viewport().get_mouse_position()
	cursor = mouse if get_viewport().get_visible_rect().has_point(mouse) else _viewport_size() * 0.5
	if _view != null:
		_view.visible = true
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

func _send(event: InputEvent) -> void:
	if sink.is_valid():
		sink.call(event)
	else:
		get_viewport().push_input(event, true) # positions are already the viewport's own

func _motion(relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.device = DEVICE
	event.position = cursor
	event.global_position = cursor
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if _a_down else 0
	_send(event)

func _click(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.device = DEVICE
	event.position = cursor
	event.global_position = cursor
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	_send(event)

func _key(keycode: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.device = DEVICE
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = pressed
		_send(event)

# --- the cursor ---

class _CursorView extends Control:
	var owner_controller: GamepadController

	func _draw() -> void:
		if owner_controller == null:
			return
		var at := owner_controller.cursor
		var held := owner_controller._a_down
		var radius := 9.0 if held else 12.0
		draw_arc(at, radius + 1.5, 0.0, TAU, 28, Color(0, 0, 0, 0.75), 4.0, true)
		draw_arc(at, radius, 0.0, TAU, 28, Color("f2d58b") if held else Color.WHITE, 2.0, true)
		draw_circle(at, 2.5, Color("f2d58b"))
