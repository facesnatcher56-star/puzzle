extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("GEOMETRY TEST FAILED: " + message)

func _has_point(outline: PackedVector2Array, target: Vector2) -> bool:
	for p in outline:
		if p.distance_to(target) < 0.01:
			return true
	return false

func _check_border(columns: int, rows: int, board: Vector2, seed_value: int, label: String) -> void:
	var source: Texture2D = load("res://assets/emberbound.png")
	var pieces := PuzzleGenerator.generate(source, columns, rows, seed_value, board, true)
	for piece in pieces:
		var sz := piece.piece_size
		var tag := "%s seed %d piece %d" % [label, seed_value, piece.piece_id]
		var top := piece.row == 0
		var bottom := piece.row == rows - 1
		var left := piece.column == 0
		var right := piece.column == columns - 1
		if top:
			_check(_has_point(piece.outline, Vector2(0, 0)) and _has_point(piece.outline, Vector2(sz.x, 0)), tag + ": top edge is a straight line with square corners")
		if bottom:
			_check(_has_point(piece.outline, Vector2(0, sz.y)) and _has_point(piece.outline, Vector2(sz.x, sz.y)), tag + ": bottom edge is straight with square corners")
		if left:
			_check(_has_point(piece.outline, Vector2(0, 0)) and _has_point(piece.outline, Vector2(0, sz.y)), tag + ": left edge is straight with square corners")
		if right:
			_check(_has_point(piece.outline, Vector2(sz.x, 0)) and _has_point(piece.outline, Vector2(sz.x, sz.y)), tag + ": right edge is straight with square corners")
		if top or bottom or left or right:
			for p in piece.outline:
				if top:
					_check(p.y > -0.01, tag + ": nothing pokes above the top border")
				if bottom:
					_check(p.y < sz.y + 0.01, tag + ": nothing pokes below the bottom border")
				if left:
					_check(p.x > -0.01, tag + ": nothing pokes past the left border")
				if right:
					_check(p.x < sz.x + 0.01, tag + ": nothing pokes past the right border")

func _run() -> void:
	for test_seed in [1, 52813, 99999]:
		_check_border(4, 6, Vector2(1122, 1402), test_seed, "4x6")
		_check_border(10, 25, Vector2(1122, 1402), test_seed, "10x25")
		_check_border(6, 4, Vector2(1448, 1086), test_seed, "6x4")
		_check_border(18, 14, Vector2(1448, 1086), test_seed, "18x14")
	# Rotation: four quarter turns restore everything, and lighting never rotates with the piece.
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game._hide_lobby()
	SaveManager.save_dir = "user://test_saves"
	game._new_session(true)
	await process_frame
	for id in [0, 5, 100]:
		game._place_bank_piece(id, Vector2(-200 + id, 50))
	var piece: PuzzlePieceState = game.manager.get_piece(5)
	var start_position := piece.current_position
	var start_rotation := piece.current_rotation
	var view: PuzzlePieceView = game.table_views[5]
	for turn in range(4):
		game._select_table_piece(5)
		game._rotate_selected()
		var shadow_world: Vector2 = view.shadow.position.rotated(view.rotation)
		_check(shadow_world.distance_to(PuzzlePieceView.SHADOW_OFFSET) < 0.01, "shadow direction stays fixed in the world after turn %d" % turn)
		_check(is_equal_approx(view.rotation_degrees, piece.current_rotation) or is_equal_approx(fposmod(view.rotation_degrees, 360.0), float(piece.current_rotation)), "view matches state rotation")
	_check(piece.current_position.distance_to(start_position) < 0.01 and piece.current_rotation == start_rotation, "four quarter turns restore position and rotation")
	# Hovering a board piece shows the enlarged preview; moving off it hides it.
	game.camera.position = Vector2.ZERO
	game.camera.zoom = Vector2.ONE * 0.5
	await process_frame
	await process_frame
	var centre: Vector2 = game.get_viewport().get_canvas_transform() * (piece.current_position + piece.piece_size * 0.5)
	game._update_table_hover(centre)
	_check(game.preview_panel.visible and game.hover_table_id == 5, "hovering a board piece shows its enlarged preview")
	game._update_table_hover(Vector2(5, 300))
	_check(not game.preview_panel.visible and game.hover_table_id == -1, "moving off the piece hides the preview")
	for entry in SaveManager.list_saves():
		SaveManager.delete_slot(entry.slot)
	print("geometry test done, failures: ", failures)
	quit(1 if failures > 0 else 0)
