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
	# Left-dragging empty table pans the camera.
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(5, 300)
	game._handle_mouse_button(click)
	_check(game.mouse_panning, "left click on empty table starts a camera pan")
	click.pressed = false
	game._handle_mouse_button(click)
	_check(not game.mouse_panning, "releasing stops the pan")
	# Joined pieces merge visually: no seam lines on joined sides, art grown to overlap.
	var fresh := PuzzleGenerator.generate(game.source, 8, 6, 5, game.board_size)
	var joined_manager := PuzzleManager.new()
	joined_manager.configure(fresh, Vector2(10, 10), 8, 6)
	for id in [9, 10]:
		var pc: PuzzlePieceState = joined_manager.get_piece(id)
		joined_manager.request_place_from_bank(id, pc.correct_position + Vector2(20, 20))
	for id in [9, 10]:
		joined_manager.request_pickup(id)
		joined_manager.request_release(id)
	var seam_view := PuzzlePieceView.new()
	seam_view.manager = joined_manager
	seam_view.table_mode = true
	seam_view.setup(fresh[9], game.source, fresh[9].piece_size)
	seam_view.refresh_seams()
	_check(joined_manager.is_joined_side(9, 1) and seam_view.joined_mask == 1 << 1, "piece knows its right side is joined")
	_check(PuzzlePieceView._polygon_area(seam_view.art.polygon) > PuzzlePieceView._polygon_area(fresh[9].outline), "joined piece art grows to overlap its neighbour")
	var hidden := 0
	for i in range(seam_view.edges.points.size()):
		if not seam_view.edges._exposed(i):
			hidden += 1
	_check(hidden > 0, "joined side outline is not drawn")
	# Rotated pieces must snap exactly into place: pieces differ in size, so a rotated join computed from
	# top-left positions lands several pixels out of true. Check every joined piece is rigidly aligned.
	for turns in range(4):
		var angle := deg_to_rad(90.0 * turns)
		var rig_pieces := PuzzleGenerator.generate(game.source, 8, 6, 777 + turns, game.board_size, false)
		var rig := PuzzleManager.new()
		rig.configure(rig_pieces, Vector2(game.board_size.x / 8, game.board_size.y / 6), 8, 6)
		var shift := Vector2(-3000, 2000)
		var rng := RandomNumberGenerator.new()
		rng.seed = turns + 1
		for pc in rig_pieces:
			var center: Vector2 = shift + (pc.correct_position + pc.piece_size * 0.5).rotated(angle)
			rig.request_place_from_bank(pc.piece_id, center - pc.piece_size * 0.5 + Vector2(rng.randf_range(-3, 3), rng.randf_range(-3, 3)))
			pc.current_rotation = 90 * turns
		var order := range(rig_pieces.size())
		order.shuffle()
		for id in order:
			rig.request_pickup(id)
			rig.request_release(id)
		_check(rig.clusters.size() == 1, "rotation %d: noisy pieces all snap into one group (got %d)" % [90 * turns, rig.clusters.size()])
		var reference := Vector2.ZERO
		var worst := 0.0
		for pc in rig_pieces:
			var drift: Vector2 = pc.current_position + pc.piece_size * 0.5 - (pc.correct_position + pc.piece_size * 0.5).rotated(angle)
			if pc.piece_id == 0:
				reference = drift
			worst = maxf(worst, drift.distance_to(reference))
		_check(worst < 0.01, "rotation %d: joined pieces are rigidly aligned (worst error %.3f px)" % [90 * turns, worst])
	# The hover popup turns with the piece immediately.
	game._select_table_piece(5)
	game._update_table_hover(centre)
	var popup_before: float = game.preview_view.rotation_degrees
	game._rotate_selected()
	_check(not is_equal_approx(game.preview_view.rotation_degrees, popup_before) and is_equal_approx(game.preview_view.rotation_degrees, float(piece.current_rotation)), "popup rotates immediately with the piece")
	# Every outline must be a clean, fillable polygon (tabs never fold over or cross each other),
	# otherwise the artwork shows holes. Also check the grown outline used for joined pieces.
	for sd in range(1, 31):
		for grid in [Vector2i(8, 6), Vector2i(18, 14)]:
			for pc in PuzzleGenerator.generate(game.source, grid.x, grid.y, sd, game.board_size, false):
				var tag := "seed %d %dx%d piece %d" % [sd, grid.x, grid.y, pc.piece_id]
				_check(PuzzleGenerator._is_simple_loop(pc.outline), tag + ": outline does not cross itself")
				var full := PuzzlePieceView._polygon_area(pc.outline)
				var idx := Geometry2D.triangulate_polygon(pc.outline)
				var filled := 0.0
				for i in range(0, idx.size(), 3):
					filled += PuzzlePieceView._polygon_area(PackedVector2Array([pc.outline[idx[i]], pc.outline[idx[i + 1]], pc.outline[idx[i + 2]]]))
				_check(absf(filled - full) < full * 0.002, tag + ": artwork fills the whole outline")
	# Groups from old saves with drifted pieces are pulled back into exact alignment on load.
	var drift_pieces := PuzzleGenerator.generate(game.source, 8, 6, 31, game.board_size, false)
	var drift_manager := PuzzleManager.new()
	drift_manager.configure(drift_pieces, Vector2(game.board_size.x / 8, game.board_size.y / 6), 8, 6)
	var drift_snaps := []
	for pc in drift_pieces:
		var snap := pc.snapshot()
		snap.on_table = pc.piece_id in [9, 10, 11]
		snap.cluster_id = 9 if snap.on_table else -1
		snap.rotation = 90
		var turned := (pc.correct_position + pc.piece_size * 0.5).rotated(PI * 0.5) - pc.piece_size * 0.5
		snap.position = [turned.x + (6.0 if pc.piece_id == 10 else 0.0), turned.y - (4.0 if pc.piece_id == 11 else 0.0)]
		drift_snaps.append(snap)
	drift_manager.apply_snapshots(drift_snaps)
	var d9 := drift_pieces[9].current_position + drift_pieces[9].piece_size * 0.5 - (drift_pieces[9].correct_position + drift_pieces[9].piece_size * 0.5).rotated(PI * 0.5)
	for id in [10, 11]:
		var pc: PuzzlePieceState = drift_pieces[id]
		var d := pc.current_position + pc.piece_size * 0.5 - (pc.correct_position + pc.piece_size * 0.5).rotated(PI * 0.5)
		_check(d.distance_to(d9) < 0.01, "piece %d is realigned to its group on load" % id)
	# Loose pieces are never hidden: bigger groups sit under smaller ones, and a dropped piece that
	# would fully cover an equal-size piece is nudged aside.
	var hide_game = load("res://scenes/main.tscn").instantiate()
	root.add_child(hide_game)
	hide_game._hide_lobby()
	hide_game._new_session(false)
	hide_game._set_rotation_enabled(false)
	await process_frame
	var hm: PuzzleManager = hide_game.manager
	hm.request_place_from_bank(0, Vector2(100, 100))
	hm.request_place_from_bank(1, Vector2(100, 100) + hm.get_piece(1).correct_position - hm.get_piece(0).correct_position)
	hm.request_pickup(0)
	hm.request_release(0)
	hm.request_place_from_bank(30, Vector2(120, 120))
	hide_game._restack_pieces()
	var order: Array = hide_game.piece_layer.get_children()
	var single_index: int = order.find(hide_game.table_views[30])
	var group_index: int = order.find(hide_game.table_views[0])
	_check(hm.cluster_members(0).size() == 2 and single_index > group_index, "a loose piece is stacked above a larger joined group")
	hm.request_place_from_bank(31, hm.get_piece(30).current_position)
	hm.request_pickup(31)
	hide_game._drop_piece(31)
	var covered_rect: Rect2 = hide_game._cluster_rect(30)
	var dropped_rect: Rect2 = hide_game._cluster_rect(31)
	_check(dropped_rect.intersection(covered_rect).get_area() < covered_rect.get_area() * 0.3, "a piece dropped squarely on an equal-size piece is nudged clear of it")
	# Edge/corner finder highlights only loose pieces of that type.
	var edge_id := 0
	var corner_id := 0
	for pc in hm.pieces:
		if pc.is_corner_piece and corner_id == 0 and pc.piece_id != 0:
			corner_id = pc.piece_id
	hm.request_place_from_bank(corner_id, Vector2(-900, -700))
	hide_game._set_type_highlight("CORNERS")
	_check(hide_game.table_views[corner_id].edges.flagged, "hovering CORNERS lights a loose corner piece")
	_check(not hide_game.table_views[30].edges.flagged, "non-corner pieces are not lit by CORNERS")
	hide_game._set_type_highlight("")
	_check(not hide_game.table_views[corner_id].edges.flagged, "highlight clears when the mouse leaves the button")
	print("geometry test done, failures: ", failures)
	quit(1 if failures > 0 else 0)
