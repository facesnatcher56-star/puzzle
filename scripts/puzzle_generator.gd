class_name PuzzleGenerator
extends RefCounted

static func generate(texture: Texture2D, columns: int, rows: int, seed_value: int, board_size: Vector2, random_rotation: bool = false) -> Array[PuzzlePieceState]:
	var result: Array[PuzzlePieceState] = []
	if texture == null or columns < 2 or rows < 2 or board_size.x <= 0 or board_size.y <= 0:
		push_error("Puzzle generation failed: invalid source image or grid dimensions")
		return result
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var cell := Vector2(board_size.x / columns, board_size.y / rows)
	var seams := {}
	for r in range(rows + 1):
		for c in range(columns):
			var a := Vector2(c * cell.x, r * cell.y)
			var b := a + Vector2(cell.x, 0)
			seams["h_%d_%d" % [r, c]] = _make_seam(a, b, r == 0 or r == rows, rng, cell)
	for r in range(rows):
		for c in range(columns + 1):
			var a := Vector2(c * cell.x, r * cell.y)
			var b := a + Vector2(0, cell.y)
			seams["v_%d_%d" % [r, c]] = _make_seam(a, b, c == 0 or c == columns, rng, cell)
	# Keep orientation randomness independent of the seam sampling.
	var rotation_rng := RandomNumberGenerator.new()
	rotation_rng.seed = seed_value + 7919
	var tex_size := texture.get_size()
	for r in range(rows):
		for c in range(columns):
			var piece := PuzzlePieceState.new()
			piece.piece_id = r * columns + c
			piece.row = r
			piece.column = c
			piece.correct_position = Vector2(c * cell.x, r * cell.y) - board_size * 0.5
			piece.current_position = piece.correct_position
			piece.current_rotation = rotation_rng.randi_range(0, 3) * 90 if random_rotation else 0
			var top: Dictionary = seams["h_%d_%d" % [r, c]]
			var right: Dictionary = seams["v_%d_%d" % [r, c + 1]]
			var bottom: Dictionary = seams["h_%d_%d" % [r + 1, c]]
			var left: Dictionary = seams["v_%d_%d" % [r, c]]
			piece.top_edge = top.sign
			piece.right_edge = right.sign
			piece.bottom_edge = -bottom.sign
			piece.left_edge = -left.sign
			piece.is_edge_piece = r == 0 or c == 0 or r == rows - 1 or c == columns - 1
			piece.is_corner_piece = (r == 0 or r == rows - 1) and (c == 0 or c == columns - 1)
			var perimeter := PackedVector2Array()
			_append_segment(perimeter, top.points, false)
			_append_segment(perimeter, right.points, false)
			_append_segment(perimeter, bottom.points, true)
			_append_segment(perimeter, left.points, true)
			# Remove the duplicated closing vertex; Line2D closes the outline itself.
			perimeter.remove_at(perimeter.size() - 1)
			var origin := Vector2(c * cell.x, r * cell.y)
			piece.edge_contours = [
				_local_edge(top.points, false, origin),
				_local_edge(right.points, false, origin),
				_local_edge(bottom.points, true, origin),
				_local_edge(left.points, true, origin)
			]
			piece.outline = PackedVector2Array()
			piece.uv = PackedVector2Array()
			for p in perimeter:
				piece.outline.append(p - origin)
				piece.uv.append(Vector2(p.x / board_size.x * tex_size.x, p.y / board_size.y * tex_size.y))
			result.append(piece)
	return result

static func _append_segment(dest: PackedVector2Array, source: PackedVector2Array, reverse: bool) -> void:
	for i in range(source.size()):
		if dest.size() > 0 and i == 0:
			continue
		dest.append(source[source.size() - 1 - i] if reverse else source[i])

static func _local_edge(source: PackedVector2Array, reverse: bool, origin: Vector2) -> PackedVector2Array:
	var result := PackedVector2Array()
	for i in range(source.size()):
		result.append(source[source.size() - 1 - i] - origin if reverse else source[i] - origin)
	return result

static func _make_seam(a: Vector2, b: Vector2, flat: bool, rng: RandomNumberGenerator, cell: Vector2) -> Dictionary:
	if flat:
		return {"sign": 0, "points": PackedVector2Array([a, b])}
	var sign_value := 1 if rng.randi_range(0, 1) == 0 else -1
	# Round, broad, narrow, squat and pointed heads. Shared seams are sampled
	# once, so both neighbors retain exactly complementary contours.
	var profiles := [
		Vector3(0.16, 0.24, 0.10), Vector3(0.22, 0.20, 0.08),
		Vector3(0.11, 0.27, 0.12), Vector3(0.20, 0.15, 0.06),
		Vector3(0.14, 0.28, 0.07)
	]
	var style := rng.randi_range(0, profiles.size() - 1)
	var profile: Vector3 = profiles[style]
	var center := rng.randf_range(0.42, 0.58)
	var width := profile.x * rng.randf_range(0.88, 1.08)
	var height := profile.y * rng.randf_range(0.88, 1.08)
	var neck := profile.z * rng.randf_range(0.90, 1.10)
	var lean := rng.randf_range(-0.035, 0.035)
	var crown := 0.015 if style == 4 else width * 0.68
	var tangent := b - a
	var normal := Vector2(tangent.y, -tangent.x).normalized()
	var depth := minf(cell.x, cell.y)
	var pts := PackedVector2Array([a])
	var neck_left := center - width
	var neck_right := center + width
	pts.append(a + tangent * neck_left)
	_curve(pts, a, tangent, normal, sign_value, depth, Vector2(neck_left, 0), Vector2(center - width * 0.75, 0.02), Vector2(center - width * 1.25, neck * 0.75), Vector2(center - width * 0.8, neck), 6)
	_curve(pts, a, tangent, normal, sign_value, depth, Vector2(center - width * 0.8, neck), Vector2(center - width * 1.4 + lean, height * 0.92), Vector2(center - crown + lean, height), Vector2(center + lean, height), 8)
	_curve(pts, a, tangent, normal, sign_value, depth, Vector2(center + lean, height), Vector2(center + crown + lean, height), Vector2(center + width * 1.4 + lean, height * 0.92), Vector2(center + width * 0.8, neck), 8)
	_curve(pts, a, tangent, normal, sign_value, depth, Vector2(center + width * 0.8, neck), Vector2(center + width * 1.25, neck * 0.75), Vector2(center + width * 0.75, 0.02), Vector2(neck_right, 0), 6)
	pts.append(b)
	return {"sign": sign_value, "points": pts}

static func _curve(points: PackedVector2Array, a: Vector2, tangent: Vector2, normal: Vector2, sign_value: int, depth: float, p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, steps: int) -> void:
	for i in range(1, steps + 1):
		var t := float(i) / steps
		var u := 1.0 - t
		var p := u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3
		points.append(a + tangent * p.x + normal * p.y * depth * sign_value)
