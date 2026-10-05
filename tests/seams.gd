extends SceneTree

# Every puzzle must be physically solvable. For every picture format and piece count, over many seeds:
#   - each seam has exactly one tab and one blank, and the two pieces' contours are the same curve;
#   - the pieces tile the board exactly, no piece's outline crosses itself and no two pieces overlap;
#   - the border is straight;
#   - and a piece dropped near its true spot always joins its neighbour, whatever the seam's shape (a shallow
#     V-shaped tab used to refuse to join well inside the distance square and round tabs joined from), at any
#     quarter turn and in any direction.

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("SEAMS TEST FAILED: " + message)

func _area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in range(poly.size()):
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5

func _outline(p: PuzzlePieceState) -> PackedVector2Array:
	var out := PackedVector2Array()
	for pt in p.outline:
		out.append(pt + p.uv_origin)
	return out

func _simple(poly: PackedVector2Array) -> bool:
	var n := poly.size()
	for i in range(n):
		for j in range(i + 2, n):
			if i == 0 and j == n - 1:
				continue
			if Geometry2D.segment_intersects_segment(poly[i], poly[(i + 1) % n], poly[j], poly[(j + 1) % n]) != null:
				return false
	return true

func _edge(p: PuzzlePieceState, side: int) -> int:
	return [p.top_edge, p.right_edge, p.bottom_edge, p.left_edge][side]

func _neighbour(p: PuzzlePieceState, side: int, cols: int, rows: int) -> int:
	match side:
		0: return p.piece_id - cols if p.row > 0 else -1
		1: return p.piece_id + 1 if p.column < cols - 1 else -1
		2: return p.piece_id + cols if p.row < rows - 1 else -1
	return p.piece_id - 1 if p.column > 0 else -1

func _configs() -> Array:
	var all := []
	for grid in PuzzleCatalog.SIZES:
		all.append({"name": "classic", "board": Vector2(1122, 1402), "grid": grid})
	for grid in PuzzleCatalog.RANDOM_SIZES:
		all.append({"name": "random", "board": Vector2(1448, 1086), "grid": grid})
	for grid in PuzzleCatalog.LARGE_SIZES:
		if not PuzzleCatalog.RANDOM_SIZES.has(grid):
			all.append({"name": "large", "board": Vector2(1448, 1086), "grid": grid})
	return all

func _run() -> void:
	# the seeds of real games (including one that got stuck), plus a spread of others
	var seeds := [423486, 638455, 682364, 539043, 52813, 1, 2, 3, 7, 11, 19, 31, 52, 77, 104729, 211000, 999983]
	for cfg in _configs():
		var cols: int = cfg.grid.x
		var rows: int = cfg.grid.y
		var label := "%s %dx%d" % [cfg.name, cols, rows]
		for seed_value in seeds:
			_geometry(label, cfg.board, cols, rows, seed_value, cols * rows <= 108 or seed_value in [423486, 1, 2])
		# snapping is the slow part, so it gets one seed per size (the stuck game's)
		_snapping(label, cfg.board, cols, rows, 423486)
		print("seams: %s checked" % label) # progress, so a watcher can tell a slow run from a hung one
	print("seams test done, failures: ", failures)
	quit(1 if failures > 0 else 0)

func _geometry(label: String, board: Vector2, cols: int, rows: int, seed_value: int, deep: bool) -> void:
	var tex := ImageTexture.create_from_image(Image.create(int(board.x), int(board.y), false, Image.FORMAT_RGBA8))
	var pieces := PuzzleGenerator.generate(tex, cols, rows, seed_value, board, false)
	if pieces.size() != cols * rows:
		_check(false, "%s seed %d: wrong piece count" % [label, seed_value])
		return
	var total := 0.0
	var tabs := 0
	for p in pieces:
		total += _area(_outline(p))
		for side in range(4):
			var n := _neighbour(p, side, cols, rows)
			if n < 0:
				_check(_edge(p, side) == 0, "%s seed %d: piece %d's outer side %d is flat" % [label, seed_value, p.piece_id, side])
				continue
			var other: PuzzlePieceState = pieces[n]
			if _edge(p, side) == 0 or _edge(p, side) != -_edge(other, (side + 2) % 4):
				_check(false, "%s seed %d: seam %d|%d has a tab and a blank" % [label, seed_value, p.piece_id, n])
				continue
			tabs += 1
			if side == 1 or side == 2:
				var a := PackedVector2Array()
				for pt in p.edge_contours[side]:
					a.append(pt + p.uv_origin)
				var b := PackedVector2Array()
				for pt in other.edge_contours[(side + 2) % 4]:
					b.append(pt + other.uv_origin)
				b.reverse()
				var same := a.size() == b.size()
				for i in range(a.size() if same else 0):
					same = same and a[i].distance_to(b[i]) < 0.5
				_check(same, "%s seed %d: seam %d|%d is the same curve on both pieces" % [label, seed_value, p.piece_id, n])
		if deep:
			_check(_simple(p.outline), "%s seed %d: piece %d's outline crosses itself" % [label, seed_value, p.piece_id])
	_check(absf(total - board.x * board.y) / (board.x * board.y) < 0.002, "%s seed %d: the pieces tile the board exactly" % [label, seed_value])
	if deep:
		for p in pieces:
			for d in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(-1, 1)]:
				var c: int = p.column + d.x
				var r: int = p.row + d.y
				if c < 0 or c >= cols or r >= rows:
					continue
				var area := 0.0
				for poly in Geometry2D.intersect_polygons(_outline(p), _outline(pieces[r * cols + c])):
					area += _area(poly)
				_check(area < 1.0, "%s seed %d: pieces %d and %d overlap" % [label, seed_value, p.piece_id, r * cols + c])

# Drops each piece near its neighbour's true spot -- close to the limit, in eight directions, at every quarter
# turn -- and checks that the two join.
func _snapping(label: String, board: Vector2, cols: int, rows: int, seed_value: int) -> void:
	var tex := ImageTexture.create_from_image(Image.create(int(board.x), int(board.y), false, Image.FORMAT_RGBA8))
	var pieces := PuzzleGenerator.generate(tex, cols, rows, seed_value, board, false)
	var m := PuzzleManager.new()
	m.configure(pieces, Vector2(board.x / cols, board.y / rows), cols, rows)
	var limit := minf(m.cell_size.x, m.cell_size.y) * PuzzleManager.SNAP_TOLERANCE
	var tried := 0
	var failed := []
	var previous := []
	var seam_index := 0
	for p in pieces:
		for side in [1, 2]:
			var nid := _neighbour(p, side, cols, rows)
			if nid < 0:
				continue
			seam_index += 1
			var n: PuzzlePieceState = pieces[nid]
			# every seam upright; a quarter of them at each of the other turns (the check is slow)
			var turns := [0] if seam_index % 4 != 0 else [0, 90, 180, 270]
			for turn in turns:
				for k in range(8):
					for share in [0.55, 0.9]:
						var offset: Vector2 = Vector2.from_angle(k * PI / 4.0) * limit * share
						for id in previous:
							pieces[id].is_on_table = false
							pieces[id].cluster_id = -1
							pieces[id].is_locked = false
							pieces[id].is_snapped = false
							pieces[id].current_rotation = 0
							m.clusters.erase(id)
						previous = [p.piece_id, nid]
						m.request_place_from_bank(p.piece_id, Vector2(300, 300))
						m.request_place_from_bank(nid, Vector2.ZERO)
						p.current_position = Vector2(300, 300)
						p.current_rotation = turn
						n.current_rotation = turn
						var centre: Vector2 = p.current_position + p.piece_size * 0.5 + ((n.correct_position + n.piece_size * 0.5) - (p.correct_position + p.piece_size * 0.5)).rotated(deg_to_rad(turn)) + offset
						n.current_position = centre - n.piece_size * 0.5
						m.request_pickup(nid)
						m.request_release(nid)
						tried += 1
						if n.cluster_id != p.cluster_id:
							failed.append("%d|%d turn %d off (%.0f,%.0f)" % [p.piece_id, nid, turn, offset.x, offset.y])
	_check(failed.is_empty(), "%s: pieces dropped within %.0f px of their spot always join (%d of %d did not: %s)" % [label, limit, failed.size(), tried, failed.slice(0, 4)])
