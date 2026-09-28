class_name PieceBankItem
extends Control

signal hovered(piece_id: int, screen_position: Vector2)
signal unhovered(piece_id: int)
signal pressed(piece_id: int, screen_position: Vector2)

var piece_id: int
var view: PuzzlePieceView
var active := false

func setup(piece: PuzzlePieceState, source: Texture2D, cell: Vector2) -> void:
	piece_id = piece.piece_id
	custom_minimum_size = Vector2(100, 101)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	view = preload("res://scenes/puzzle_piece.tscn").instantiate()
	add_child(view)
	view.setup(piece, source, cell)
	var factor := minf(70.0 / cell.x, 70.0 / cell.y)
	view.scale = Vector2.ONE * factor
	view.position = Vector2(50, 48) - cell * factor * 0.5
	mouse_entered.connect(func(): hovered.emit(piece_id, get_global_mouse_position()))
	mouse_exited.connect(func(): unhovered.emit(piece_id))

func set_active(value: bool) -> void:
	active = value
	queue_redraw()

func _draw() -> void:
	var bg := Color("43505a") if active else Color("303c45")
	draw_rect(Rect2(Vector2(3, 3), size - Vector2(6, 6)), bg, true)
	draw_rect(Rect2(Vector2(3, 3), size - Vector2(6, 6)), Color("ddb96c") if active else Color("52616b"), false, 1.5)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		pressed.emit(piece_id, event.position + global_position)
		accept_event()
	elif event is InputEventScreenTouch and event.pressed:
		pressed.emit(piece_id, event.position)
		accept_event()
