extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("SMOKE TEST FAILED: " + message)

func _edge(piece: PuzzlePieceState, side: int, cell: Vector2) -> PackedVector2Array:
	var corners := [Vector2.ZERO, Vector2(cell.x, 0), cell, Vector2(0, cell.y)]
	var start_corner: Vector2 = corners[side]
	var end_corner: Vector2 = corners[(side + 1) % 4]
	var start_index := -1
	var end_index := -1
	for i in range(piece.outline.size()):
		if piece.outline[i].distance_to(start_corner) < 0.01:
			start_index = i
		if piece.outline[i].distance_to(end_corner) < 0.01:
			end_index = i
	_check(start_index >= 0 and end_index >= 0, "outline contains edge corners")
	var result := PackedVector2Array()
	var index := start_index
	while true:
		result.append(piece.correct_position + piece.outline[index])
		if index == end_index:
			break
		index = (index + 1) % piece.outline.size()
	return result

func _matching_edges(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i].distance_to(b[b.size() - 1 - i]) > 0.01:
			return false
	return true

func _run() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_check(scene != null, "main scene loads")
	var game := scene.instantiate()
	root.add_child(game)
	game.size_picker.select(1)
	game._set_rotation_enabled(false)
	await process_frame
	await process_frame
	var manager: PuzzleManager = game.manager
	_check(manager.pieces.size() == 48, "default has 48 pieces")
	_check(game.bank.row.get_child_count() == 48, "bank shows all unplaced pieces")
	var curved := 0
	var edge_count := 0
	for piece in manager.pieces:
		_check(piece.outline.size() > 20, "piece has a sampled silhouette")
		_check(Geometry2D.triangulate_polygon(piece.outline).size() >= 3, "piece polygon triangulates")
		if piece.is_edge_piece:
			edge_count += 1
		if piece.top_edge != 0 or piece.right_edge != 0 or piece.bottom_edge != 0 or piece.left_edge != 0:
			curved += 1
		if piece.row == 0:
			_check(piece.top_edge == 0, "top border is flat")
		if piece.column == 0:
			_check(piece.left_edge == 0, "left border is flat")
		if piece.row == game.rows - 1:
			_check(piece.bottom_edge == 0, "bottom border is flat")
		if piece.column == game.columns - 1:
			_check(piece.right_edge == 0, "right border is flat")
		if piece.column < game.columns - 1:
			var neighbor: PuzzlePieceState = manager.pieces[piece.piece_id + 1]
			_check(piece.right_edge == -neighbor.left_edge, "horizontal edges complement")
			_check(_matching_edges(_edge(piece, 1, game.cell), _edge(neighbor, 3, game.cell)), "horizontal seam geometry matches")
		if piece.row < game.rows - 1:
			var neighbor: PuzzlePieceState = manager.pieces[piece.piece_id + game.columns]
			_check(piece.bottom_edge == -neighbor.top_edge, "vertical edges complement")
			_check(_matching_edges(_edge(piece, 2, game.cell), _edge(neighbor, 0, game.cell)), "vertical seam geometry matches")
	_check(curved == 48, "every piece has an internal shaped edge")
	game.bank.set_filter("EDGES")
	_check(game.bank.row.get_child_count() == edge_count, "edge filter count")
	game.bank.set_filter("CORNERS")
	_check(game.bank.row.get_child_count() == 4, "corner filter count")
	game.bank.set_filter("ALL")
	_check(manager.move_piece_to_tray(2, 1), "piece can be assigned to tray")
	game.bank.set_filter("TRAY 1")
	_check(game.bank.row.get_child_count() == 1, "tray filter shows assigned piece")
	game.bank.set_filter("ALL")
	game._show_preview(0, Vector2(300, 650))
	_check(game.preview_panel.visible and game.preview_view != null, "magnifier opens")
	game._hide_preview()
	_check(not game.preview_panel.visible, "magnifier closes")
	var first: PuzzlePieceState = manager.pieces[0]
	var free_anchor := Vector2(2300, -1350)
	_check(manager.request_place_from_bank(0, first.correct_position), "piece leaves bank")
	_check(game.bank.row.get_child_count() == 47, "bank removes placed piece")
	_check(not manager.request_release(0), "board position alone never snaps a piece")
	manager.request_move(0, free_anchor)
	_check(first.current_position == free_anchor, "board position is ignored")
	var wrong: PuzzlePieceState = manager.pieces[3]
	manager.request_place_from_bank(3, free_anchor + Vector2(game.cell.x + 2, 2))
	_check(not manager.request_release(3), "wrong neighbor cannot join when nearby")
	var second: PuzzlePieceState = manager.pieces[1]
	manager.request_place_from_bank(1, free_anchor + Vector2(game.cell.x + 4, 3))
	_check(manager.request_release(1), "correct touching neighbor joins anywhere")
	_check(manager.cluster_members(0).size() == 2, "joined pieces share a cluster")
	_check(second.current_position.distance_to(free_anchor + Vector2(game.cell.x, 0)) < 0.01, "joint aligns exactly")
	_check(first.current_position == free_anchor, "stationary cluster stays in place")
	_check(manager.request_pickup(1), "joined group can be picked up")
	var before_group_move := first.current_position
	manager.request_move(1, second.current_position + Vector2(90, 70))
	_check(first.current_position.distance_to(before_group_move + Vector2(90, 70)) < 0.01, "dragging one member moves its entire group")
	manager.request_release(1)
	var below: PuzzlePieceState = manager.pieces[game.columns]
	manager.request_place_from_bank(below.piece_id, first.current_position + Vector2(0, game.cell.y + 35))
	_check(not manager.request_release(below.piece_id), "correct neighbor too far away does not join")
	manager.request_move(below.piece_id, first.current_position + Vector2(3, game.cell.y + 2))
	_check(manager.request_release(below.piece_id), "correct neighbor joins when nearly touching")
	_check(manager.cluster_members(0).size() == 3, "new joint extends existing group")
	manager.request_move(3, first.current_position + Vector2(game.cell.x * 3 + 2, 0))
	var bridge: PuzzlePieceState = manager.pieces[2]
	manager.request_place_from_bank(2, first.current_position + Vector2(game.cell.x * 2 + 3, 1))
	_check(manager.request_release(bridge.piece_id), "bridge piece joins neighboring groups")
	_check(manager.cluster_members(0).size() == 5 and wrong.cluster_id == first.cluster_id, "one release merges two groups")
	var relative_before_spread := second.current_position - first.current_position
	var position_before_spread := first.current_position
	game._spread_table_pieces()
	_check(first.current_position != position_before_spread, "spread moves a joined group")
	_check((second.current_position - first.current_position).distance_to(relative_before_spread) < 0.01, "spread preserves group shape")
	_check(game.bank.placed_label.text.contains("5 / 48"), "placed count updates")
	var old_zoom: float = game.camera.zoom.x
	var old_ui_position: Vector2 = game.bank.global_position
	game._zoom_at(Vector2(500, 300), 1.2)
	_check(game.camera.zoom.x > old_zoom, "camera zooms")
	_check(game.bank.global_position == old_ui_position, "bank stays in screen space")
	game.reference_overlay.visible = true
	_check(game.reference_overlay.visible, "reference opens")
	game.reference_overlay.visible = false
	var rotation_states := PuzzleGenerator.generate(game.source, 8, 6, 52814, game.BOARD_SIZE)
	var rotated_manager := PuzzleManager.new()
	var rotation_cell := Vector2(game.BOARD_SIZE.x / 8, game.BOARD_SIZE.y / 6)
	rotated_manager.configure(rotation_states, rotation_cell, 8, 6)
	rotated_manager.request_place_from_bank(0, Vector2(-2600, 1900))
	rotated_manager.request_place_from_bank(1, Vector2(-2600, 1900) + Vector2(rotation_cell.x + 2, 1))
	rotated_manager.request_rotate(1)
	_check(not rotated_manager.request_release(1), "mismatched rotation blocks joining")
	for i in range(3):
		rotated_manager.request_rotate(1)
	_check(rotated_manager.request_release(1), "matching rotation permits joining")
	rotated_manager.request_rotate(0)
	_check(rotation_states[0].current_rotation == 90 and rotation_states[1].current_rotation == 90, "joined group rotates together")
	var expected_rotated_offset := (rotation_states[1].correct_position - rotation_states[0].correct_position).rotated(PI * 0.5)
	_check((rotation_states[1].current_position - rotation_states[0].current_position).distance_to(expected_rotated_offset) < 0.01, "rotated group keeps aligned seam")
	var rotated_below: PuzzlePieceState = rotation_states[8]
	var rotated_below_offset := (rotated_below.correct_position - rotation_states[0].correct_position).rotated(PI * 0.5)
	rotated_manager.request_place_from_bank(8, rotation_states[0].current_position + rotated_below_offset + Vector2(2, 3))
	rotated_manager.request_rotate(8)
	_check(rotated_manager.request_release(8), "matching rotated edge joins group")
	_check(rotated_manager.cluster_members(0).size() == 3, "rotated cluster expands")
	game._start_puzzle(false)
	var completion_anchor := Vector2(3100, -2250)
	var base_correct: Vector2 = manager.pieces[0].correct_position
	for piece in manager.pieces:
		manager.request_place_from_bank(piece.piece_id, completion_anchor + piece.correct_position - base_correct)
		manager.request_release(piece.piece_id)
	_check(game.complete_banner.visible, "one complete free cluster triggers completion")
	_check(manager.completed_count() == 48 and manager.clusters.size() == 1, "all pieces form one cluster")
	var completed_before: Vector2 = manager.pieces[0].current_position
	_check(manager.request_move(0, completed_before + Vector2(140, 95)), "completed puzzle remains movable")
	_check(manager.pieces[47].current_position.distance_to(completion_anchor + manager.pieces[47].correct_position - base_correct + Vector2(140, 95)) < 0.01, "completed cluster moves intact")
	game._start_puzzle(false)
	_check(game.bank.row.get_child_count() == 48, "reset restores bank")
	_check(not game.bank.collapsed, "reset expands bank")
	for size_index in [0, 2, 3]:
		game.size_picker.select(size_index)
		game._start_puzzle(false)
		var expected: int = game.columns * game.rows
		_check(game.manager.pieces.size() == expected, "%d piece generation" % expected)
		_check(game.bank.row.get_child_count() == expected, "%d bank entries" % expected)
		for piece in game.manager.pieces:
			_check(Geometry2D.triangulate_polygon(piece.outline).size() >= 3, "%d piece %d silhouette triangulates" % [expected, piece.piece_id])
	for test_seed in range(52800, 52808):
		var generated := PuzzleGenerator.generate(game.source, 12, 8, test_seed, game.BOARD_SIZE)
		for piece in generated:
			_check(Geometry2D.triangulate_polygon(piece.outline).size() >= 3, "seed %d piece %d triangulates" % [test_seed, piece.piece_id])
	var large := PuzzleGenerator.generate(game.source, 40, 25, 52900, game.BOARD_SIZE)
	_check(large.size() == 1000, "generator supports 1000 stable IDs")
	for piece in large:
		_check(Geometry2D.triangulate_polygon(piece.outline).size() >= 3, "1000 piece geometry %d triangulates" % piece.piece_id)
	root.size = Vector2i(800, 600)
	root.content_scale_size = Vector2i(800, 600)
	await process_frame
	_check(game.bank.header_scroll.size.x < 800, "bank controls fit narrow viewport with horizontal scroll")
	_check(game.reference_panel.size.x <= 800, "reference panel fits narrow viewport")
	if failures == 0:
		print("SMOKE TEST PASSED: free clusters, wrong/close edge checks, group drag/spread/rotation/bridging/completion, 24/48/96 geometry and bank")
	quit(0 if failures == 0 else 1)
