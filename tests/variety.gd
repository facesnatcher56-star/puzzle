extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.lobby.hide_menu()
	game.session.start_puzzle(false)
	await process_frame
	_check(game.manager.pieces.size() == 250, "Default puzzle has 250 pieces")
	_check(game.session.rotation_enabled, "Rotation starts enabled")
	_check(game.session.source.get_size() == Vector2(1122, 1402), "Original artwork resolution preserved")
	_check(PuzzleCatalog.BOARD_SIZE == game.session.source.get_size(), "Board preserves full image proportions")
	_check(game.session.columns == 10 and game.session.rows == 25, "250-piece grid fits portrait artwork")
	var rotations := {}
	for piece in game.manager.pieces:
		rotations[piece.current_rotation] = true
	_check(rotations.size() == 4, "All four orientations occur")
	var item: PieceBankItem = game.bank.row.get_child(0)
	_check(is_equal_approx(item.view.rotation_degrees, item.view.data.current_rotation), "Bank displays rotation")
	game.input_controller.show_preview(item.piece_id, Vector2(300, 650))
	_check(is_equal_approx(game.input_controller.preview_view.rotation_degrees, item.view.data.current_rotation), "Preview displays rotation")
	game.input_controller.bank_press_id = item.piece_id
	game.input_controller.start_bank_drag(Vector2(500, 300))
	_check(is_equal_approx(game.input_controller.drag_ghost.rotation_degrees, item.view.data.current_rotation), "Drag ghost displays rotation")
	game.input_controller.clear_ghost()
	game.input_controller.place_bank_piece(item.piece_id, Vector2(500, 300))
	var view: PuzzlePieceView = game.board.views[item.piece_id]
	_check(is_equal_approx(view.rotation_degrees, view.data.current_rotation), "Table placement retains rotation")
	_check(view.hit_test(view.data.current_position + view.data.piece_size * 0.5), "Rotated piece remains selectable")
	var before_rotation: int = view.data.current_rotation
	game.input_controller.rotate_selected()
	_check(view.data.current_rotation == (before_rotation + 90) % 360 and is_equal_approx(view.rotation_degrees, view.data.current_rotation), "Rotate control updates state and view")
	for test_seed in range(52800, 52820):
		var pieces := PuzzleGenerator.generate(game.session.source, 25, 10, test_seed, PuzzleCatalog.BOARD_SIZE, true)
		var repeat := PuzzleGenerator.generate(game.session.source, 25, 10, test_seed, PuzzleCatalog.BOARD_SIZE, true)
		for piece in pieces:
			_check(Geometry2D.triangulate_polygon(piece.outline).size() == (piece.outline.size() - 2) * 3, "Complete triangulation for seed %d piece %d" % [test_seed, piece.piece_id])
			_check(piece.outline == repeat[piece.piece_id].outline and piece.current_rotation == repeat[piece.piece_id].current_rotation, "Seed is repeatable")
			for side in [1, 2]:
				if (side == 1 and piece.column == 24) or (side == 2 and piece.row == 9):
					continue
				var neighbor := pieces[piece.piece_id + (1 if side == 1 else 25)]
				var edge: PackedVector2Array = piece.edge_contours[side]
				var other: PackedVector2Array = neighbor.edge_contours[(side + 2) % 4]
				_check(edge.size() == other.size(), "Matching seam lengths")
				for i in range(edge.size()):
					_check((piece.correct_position + edge[i]).distance_to(neighbor.correct_position + other[other.size() - i - 1]) < 0.001, "Matching seam coordinates")
	# Solve all 250 pieces after correcting their random starting rotations.
	game.session.start_puzzle(false)
	for piece in game.manager.pieces:
		game.manager.request_place_from_bank(piece.piece_id, piece.correct_position)
		while piece.current_rotation != 0:
			game.manager.request_rotate(piece.piece_id)
		game.manager.request_release(piece.piece_id)
	_check(game.manager.completed_count() == 250 and game.complete_banner.visible, "250-piece puzzle completes after rotation and joining")
	game.session.set_rotation_enabled(false)
	for piece in game.manager.pieces:
		_check(piece.current_rotation == 0, "Disabling rotation starts upright puzzle")
	if failures == 0:
		print("VARIETY TEST PASSED: 250 pieces, rotations across all views, 20 seeds, complementary seams, full completion")
	quit(0 if failures == 0 else 1)
