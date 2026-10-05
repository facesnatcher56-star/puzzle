extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("SMOKE TEST FAILED: " + message)

func _edge(piece: PuzzlePieceState, side: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in piece.edge_contours[side]:
		result.append(piece.correct_position + point)
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
	game.session.size_index = 1
	game.session.random_rotation = false
	game.session.start_puzzle(false)
	await process_frame
	await process_frame
	var manager: PuzzleManager = game.manager
	_check(manager.pieces.size() == 48, "default has 48 pieces")
	_check(game.bank.row.get_child_count() == 48, "bank shows all unplaced pieces")
	var curved := 0
	var edge_count := 0
	for piece in manager.pieces:
		# Threshold covers the sparsest family (triangular, ~5 pts/tab) on an interior
		# piece with 4 tabbed sides; smooth round-knob tabs run ~30 pts/tab instead.
		_check(piece.outline.size() > 8, "piece has a sampled silhouette")
		_check(Geometry2D.triangulate_polygon(piece.outline).size() >= 3, "piece polygon triangulates")
		if piece.is_edge_piece:
			edge_count += 1
		if piece.top_edge != 0 or piece.right_edge != 0 or piece.bottom_edge != 0 or piece.left_edge != 0:
			curved += 1
		if piece.row == 0:
			_check(piece.top_edge == 0, "top border is flat")
		if piece.column == 0:
			_check(piece.left_edge == 0, "left border is flat")
		if piece.row == game.session.rows - 1:
			_check(piece.bottom_edge == 0, "bottom border is flat")
		if piece.column == game.session.columns - 1:
			_check(piece.right_edge == 0, "right border is flat")
		if piece.column < game.session.columns - 1:
			var neighbor: PuzzlePieceState = manager.pieces[piece.piece_id + 1]
			_check(piece.right_edge == -neighbor.left_edge, "horizontal edges complement")
			_check(_matching_edges(_edge(piece, 1), _edge(neighbor, 3)), "horizontal seam geometry matches")
		if piece.row < game.session.rows - 1:
			var neighbor: PuzzlePieceState = manager.pieces[piece.piece_id + game.session.columns]
			_check(piece.bottom_edge == -neighbor.top_edge, "vertical edges complement")
			_check(_matching_edges(_edge(piece, 2), _edge(neighbor, 0)), "vertical seam geometry matches")
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
	game.input_controller.show_preview(0, Vector2(300, 650))
	_check(game.input_controller.preview_panel.visible and game.input_controller.preview_view != null, "magnifier opens")
	game.input_controller.hide_preview()
	_check(not game.input_controller.preview_panel.visible, "magnifier closes")
	var first: PuzzlePieceState = manager.pieces[0]
	var free_anchor := Vector2(2300, -1350)
	_check(manager.request_place_from_bank(0, free_anchor + Vector2(33, -20)), "piece leaves bank")
	_check(game.bank.row.get_child_count() == 47, "bank removes placed piece")
	_check(not manager.request_release(0), "a loose corner away from its anchor does not snap")
	manager.request_move(0, free_anchor)
	_check(first.current_position == free_anchor, "a loose corner can be moved freely")
	var wrong: PuzzlePieceState = manager.pieces[3]
	manager.request_place_from_bank(3, free_anchor + Vector2(game.session.cell.x + 2, 2))
	_check(not manager.request_release(3), "wrong neighbor cannot join when nearby")
	var second: PuzzlePieceState = manager.pieces[1]
	manager.request_place_from_bank(1, free_anchor + Vector2(first.piece_size.x + 4, 3))
	_check(manager.request_release(1), "correct touching neighbor joins anywhere")
	_check(manager.cluster_members(0).size() == 2, "joined pieces share a cluster")
	# A correct neighbor just beyond the old 15% contact radius should now join, while a more distant
	# neighbor still needs to be moved closer. The existing ID, edge and rotation checks remain in force.
	var forgiving := PuzzleManager.new()
	var forgiving_pieces := PuzzleGenerator.generate(game.session.source, 8, 6, 52813, game.session.board_size, false)
	forgiving.configure(forgiving_pieces, game.session.cell, 8, 6)
	var base := Vector2(2400, -800)
	forgiving.request_place_from_bank(0, base)
	var true_delta: Vector2 = forgiving.pieces[1].correct_position - forgiving.pieces[0].correct_position
	forgiving.request_place_from_bank(1, base + true_delta + Vector2(game.session.cell.x * 0.18, 0))
	_check(forgiving.request_release(1), "correct neighbor snaps from 18% of a cell away")
	forgiving.request_place_from_bank(8, base + forgiving.pieces[8].correct_position - forgiving.pieces[0].correct_position + Vector2(0, game.session.cell.y * 0.25))
	_check(not forgiving.request_release(8), "25% of a cell is still too far to snap")
	forgiving.request_move(8, base + forgiving.pieces[8].correct_position - forgiving.pieces[0].correct_position + Vector2(0, minf(game.session.cell.x, game.session.cell.y) * 0.18))
	_check(forgiving.request_release(8), "a correct vertical neighbor also snaps at the increased radius")
	_check(second.current_position.distance_to(free_anchor + Vector2(first.piece_size.x, 0)) < 0.01, "joint aligns exactly")
	_check(first.current_position == free_anchor, "stationary cluster stays in place")
	_check(manager.request_pickup(1), "joined group can be picked up")
	var before_group_move := first.current_position
	manager.request_move(1, second.current_position + Vector2(90, 70))
	_check(first.current_position.distance_to(before_group_move + Vector2(90, 70)) < 0.01, "dragging one member moves its entire group")
	manager.request_release(1)
	var below: PuzzlePieceState = manager.pieces[game.session.columns]
	manager.request_place_from_bank(below.piece_id, first.current_position + Vector2(0, game.session.cell.y + 35))
	_check(not manager.request_release(below.piece_id), "correct neighbor too far away does not join")
	manager.request_move(below.piece_id, first.current_position + Vector2(3, first.piece_size.y + 2))
	_check(manager.request_release(below.piece_id), "correct neighbor joins when nearly touching")
	_check(manager.cluster_members(0).size() == 3, "new joint extends existing group")
	var bridge: PuzzlePieceState = manager.pieces[2]
	manager.request_move(3, second.current_position + Vector2(second.piece_size.x + bridge.piece_size.x + 2, 0))
	manager.request_place_from_bank(2, second.current_position + Vector2(second.piece_size.x + 3, 1))
	_check(manager.request_release(bridge.piece_id), "bridge piece joins neighboring groups")
	_check(manager.cluster_members(0).size() == 5 and wrong.cluster_id == first.cluster_id, "one release merges two groups")
	var relative_before_spread := second.current_position - first.current_position
	var position_before_spread := first.current_position
	game.board.spread()
	_check(first.current_position != position_before_spread, "spread moves a joined group")
	_check((second.current_position - first.current_position).distance_to(relative_before_spread) < 0.01, "spread preserves group shape")
	_check(game.bank.placed_label.text.contains("5 / 48"), "placed count updates")
	var old_zoom: float = game.camera.zoom.x
	var old_ui_position: Vector2 = game.bank.global_position
	game.input_controller.zoom_at(Vector2(500, 300), 1.2)
	_check(game.camera.zoom.x > old_zoom, "camera zooms")
	_check(game.bank.global_position == old_ui_position, "bank stays in screen space")
	game.reference.visible = true
	_check(game.reference.visible, "reference opens")
	game.reference.visible = false
	var rotation_states := PuzzleGenerator.generate(game.session.source, 8, 6, 52814, PuzzleCatalog.BOARD_SIZE)
	var rotated_manager := PuzzleManager.new()
	var rotation_cell := Vector2(PuzzleCatalog.BOARD_SIZE.x / 8, PuzzleCatalog.BOARD_SIZE.y / 6)
	rotated_manager.configure(rotation_states, rotation_cell, 8, 6)
	rotated_manager.request_place_from_bank(0, Vector2(-2600, 1900))
	rotated_manager.request_place_from_bank(1, Vector2(-2600, 1900) + Vector2(rotation_states[0].piece_size.x + 2, 1))
	rotated_manager.request_rotate(1)
	_check(not rotated_manager.request_release(1), "mismatched rotation blocks joining")
	for i in range(3):
		rotated_manager.request_rotate(1)
	_check(rotated_manager.request_release(1), "matching rotation permits joining")
	# Pieces can differ in size now, so a joined pair's *centers* (not their top-left
	# corners, which carry a per-piece size offset) are what simply rotates by 90
	# degrees around the cluster pivot -- that's the invariant request_rotate actually
	# guarantees, and what keeps their shared seam touching regardless of size.
	var center0_before: Vector2 = rotation_states[0].current_position + rotation_states[0].piece_size * 0.5
	var center1_before: Vector2 = rotation_states[1].current_position + rotation_states[1].piece_size * 0.5
	rotated_manager.request_rotate(0)
	_check(rotation_states[0].current_rotation == 90 and rotation_states[1].current_rotation == 90, "joined group rotates together")
	var center0_after: Vector2 = rotation_states[0].current_position + rotation_states[0].piece_size * 0.5
	var center1_after: Vector2 = rotation_states[1].current_position + rotation_states[1].piece_size * 0.5
	var expected_center_delta := (center1_before - center0_before).rotated(PI * 0.5)
	_check((center1_after - center0_after).distance_to(expected_center_delta) < 0.01, "rotated group keeps aligned seam")
	var rotated_below: PuzzlePieceState = rotation_states[8]
	var rotated_below_offset := (rotated_below.correct_position - rotation_states[0].correct_position).rotated(PI * 0.5)
	rotated_manager.request_place_from_bank(8, rotation_states[0].current_position + rotated_below_offset + Vector2(2, 3))
	rotated_manager.request_rotate(8)
	_check(rotated_manager.request_release(8), "matching rotated edge joins group")
	_check(rotated_manager.cluster_members(0).size() == 3, "rotated cluster expands")
	# Ownership locking: required once more than one actor (a networked peer) can act on the board.
	var ownership_states := PuzzleGenerator.generate(game.session.source, 8, 6, 52815, PuzzleCatalog.BOARD_SIZE)
	var ownership_manager := PuzzleManager.new()
	var ownership_cell := Vector2(PuzzleCatalog.BOARD_SIZE.x / 8, PuzzleCatalog.BOARD_SIZE.y / 6)
	ownership_manager.configure(ownership_states, ownership_cell, 8, 6)
	ownership_manager.request_place_from_bank(0, Vector2(-1000, 500), 1)
	_check(ownership_manager.request_pickup(0, 1), "owner can re-pick up their own piece")
	_check(not ownership_manager.request_pickup(0, 2), "a second player cannot grab an already-held piece")
	_check(not ownership_manager.request_release(0, 2), "a non-owner cannot release someone else's piece")
	_check(ownership_states[0].owner_peer_id == 1, "a rejected release leaves ownership unchanged")
	ownership_manager.request_release(0, 1)
	_check(ownership_states[0].owner_peer_id == 0, "the actual owner can release their piece")
	_check(ownership_manager.request_pickup(0, 2), "once released, a different player can pick it up")
	ownership_manager.request_place_from_bank(1, Vector2(-1000, 500) + Vector2(ownership_states[0].piece_size.x + 4, 3), 2)
	ownership_manager.request_release(0, 2)
	ownership_manager.request_release(1, 2)
	_check(ownership_manager.cluster_members(0).size() == 2, "neighbors still join while ownership is enforced")
	var joined_id: int = ownership_states[0].cluster_id
	_check(ownership_manager.request_pickup(joined_id, 1), "player 1 can grab the newly joined cluster")
	_check(not ownership_manager.request_pickup(joined_id, 2), "a joined cluster is held atomically; player 2 cannot grab any member")
	ownership_manager.release_pieces_owned_by(1)
	_check(ownership_states[0].owner_peer_id == 0 and ownership_states[1].owner_peer_id == 0, "release_pieces_owned_by frees every piece held by a disconnecting player")
	game.session.start_puzzle(false)
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
	game.session.start_puzzle(false)
	_check(game.bank.row.get_child_count() == 48, "reset restores bank")
	_check(not game.bank.collapsed, "reset expands bank")
	for size_index in [0, 2, 3]:
		game.session.size_index = size_index
		game.session.start_puzzle(false)
		var expected: int = game.session.columns * game.session.rows
		_check(game.manager.pieces.size() == expected, "%d piece generation" % expected)
		_check(game.bank.row.get_child_count() == expected, "%d bank entries" % expected)
		for piece in game.manager.pieces:
			_check(Geometry2D.triangulate_polygon(piece.outline).size() >= 3, "%d piece %d silhouette triangulates" % [expected, piece.piece_id])
	for test_seed in range(52800, 52808):
		var generated := PuzzleGenerator.generate(game.session.source, 12, 8, test_seed, PuzzleCatalog.BOARD_SIZE)
		for piece in generated:
			_check(Geometry2D.triangulate_polygon(piece.outline).size() >= 3, "seed %d piece %d triangulates" % [test_seed, piece.piece_id])
	var large := PuzzleGenerator.generate(game.session.source, 40, 25, 52900, PuzzleCatalog.BOARD_SIZE)
	_check(large.size() == 1000, "generator supports 1000 stable IDs")
	for piece in large:
		_check(Geometry2D.triangulate_polygon(piece.outline).size() >= 3, "1000 piece geometry %d triangulates" % piece.piece_id)
	root.size = Vector2i(800, 600)
	root.content_scale_size = Vector2i(800, 600)
	await process_frame
	_check(game.bank.header_scroll.size.x < 800, "bank controls fit narrow viewport with horizontal scroll")
	_check(game.reference.panel.size.x <= 800, "reference panel fits narrow viewport")
	if failures == 0:
		print("SMOKE TEST PASSED: free clusters, wrong/close edge checks, group drag/spread/rotation/bridging/completion, ownership locking, 24/48/96 geometry and bank")
	quit(0 if failures == 0 else 1)
