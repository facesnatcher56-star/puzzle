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
	# Grid lines are jittered a little so pieces aren't all identical rectangles -- each
	# interior column/row boundary shifts independently (well under half a cell, so
	# lines never cross), giving every piece a slightly different width and height.
	var col_x := _jittered_boundaries(columns, board_size.x, seed_value * 2 + 1)
	var row_y := _jittered_boundaries(rows, board_size.y, seed_value * 2 + 2)
	var seams := {}
	for r in range(rows + 1):
		for c in range(columns):
			var a := Vector2(col_x[c], row_y[r])
			var b := Vector2(col_x[c + 1], row_y[r])
			var chamfer_a := _vertex_chamfer(r, c, rows, columns, seed_value, cell)
			var chamfer_b := _vertex_chamfer(r, c + 1, rows, columns, seed_value, cell)
			seams["h_%d_%d" % [r, c]] = _make_seam(a, b, r == 0 or r == rows, rng, cell, chamfer_a, chamfer_b)
	for r in range(rows):
		for c in range(columns + 1):
			var a := Vector2(col_x[c], row_y[r])
			var b := Vector2(col_x[c], row_y[r + 1])
			var chamfer_a := _vertex_chamfer(r, c, rows, columns, seed_value, cell)
			var chamfer_b := _vertex_chamfer(r + 1, c, rows, columns, seed_value, cell)
			seams["v_%d_%d" % [r, c]] = _make_seam(a, b, c == 0 or c == columns, rng, cell, chamfer_a, chamfer_b)
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
			piece.correct_position = Vector2(col_x[c], row_y[r]) - board_size * 0.5
			piece.current_position = piece.correct_position
			piece.piece_size = Vector2(col_x[c + 1] - col_x[c], row_y[r + 1] - row_y[r])
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
			var origin := Vector2(col_x[c], row_y[r])
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

# Interior boundaries shift by up to 8% of the nominal spacing, independently in each
# direction -- comfortably short of the ~50% that would let two lines cross and
# invert a row/column.
static func _jittered_boundaries(count: int, length: float, sub_seed: int) -> PackedFloat64Array:
	var nominal := length / count
	var jitter_rng := RandomNumberGenerator.new()
	jitter_rng.seed = sub_seed
	var result := PackedFloat64Array()
	result.resize(count + 1)
	result[0] = 0.0
	result[count] = length
	for i in range(1, count):
		result[i] = i * nominal + jitter_rng.randf_range(-0.08, 0.08) * nominal
	return result

# A small, deterministic bevel at most interior grid vertices (never the board's own 4
# outer corners, which stay crisp) so pieces aren't uniformly sharp-cornered rectangles
# underneath their tabs. Purely a function of (row, column, seed), so every seam meeting
# at a shared vertex -- built independently, possibly for a different piece entirely --
# derives the exact same trim without any of them knowing about each other.
static func _vertex_chamfer(r: int, c: int, rows: int, columns: int, seed_value: int, cell: Vector2) -> float:
	if (r == 0 or r == rows) and (c == 0 or c == columns):
		return 0.0
	var vertex_rng := RandomNumberGenerator.new()
	vertex_rng.seed = seed_value ^ (r * 92821 + c * 68917 + 104729)
	if vertex_rng.randf() < 0.4:
		return 0.0
	return vertex_rng.randf_range(0.05, 0.16) * minf(cell.x, cell.y)

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

static func _make_seam(a: Vector2, b: Vector2, flat: bool, rng: RandomNumberGenerator, cell: Vector2, chamfer_a: float, chamfer_b: float) -> Dictionary:
	var sign_value := 0
	var pts: PackedVector2Array
	if flat:
		pts = PackedVector2Array([a, b])
	else:
		sign_value = 1 if rng.randi_range(0, 1) == 0 else -1
		var tangent := b - a
		var normal := Vector2(tangent.y, -tangent.x).normalized()
		var depth := minf(cell.x, cell.y)
		# Four genuinely different tab families -- round knob, square block, triangle, and a
		# flat-topped anchor/mushroom lock -- picked at random per seam and mixed freely
		# across the board, instead of one shape family with jittered proportions. Shared
		# seams are still sampled once, so both neighbors retain exactly complementary contours.
		match rng.randi_range(0, 3):
			0:
				pts = _round_knob(a, b, tangent, normal, sign_value, depth, rng)
			1:
				pts = _square_tab(a, b, tangent, normal, sign_value, depth, rng)
			2:
				pts = _triangular_tab(a, b, tangent, normal, sign_value, depth, rng)
			_:
				pts = _anchor_tab(a, b, tangent, normal, sign_value, depth, rng)
	_apply_corner_chamfer(pts, chamfer_a, chamfer_b)
	return {"sign": sign_value, "points": pts}

# Insets the seam's very first/last point along its own straight approach direction.
# Every tab family already places its second/second-to-last point with zero normal
# offset (exactly on the straight a-b baseline), so this direction is always the
# seam's plain grid-aligned tangent no matter which tab family was picked -- that's
# what lets two unrelated seams meeting at the same vertex bevel it identically from
# each side, each only knowing its own two endpoints.
static func _apply_corner_chamfer(pts: PackedVector2Array, chamfer_a: float, chamfer_b: float) -> void:
	if pts.size() < 2:
		return
	if chamfer_a > 0.0:
		var dir_a := (pts[1] - pts[0]).normalized()
		pts[0] = pts[0] + dir_a * minf(chamfer_a, pts[0].distance_to(pts[1]) * 0.9)
	if chamfer_b > 0.0:
		var last := pts.size() - 1
		var dir_b := (pts[last - 1] - pts[last]).normalized()
		pts[last] = pts[last] + dir_b * minf(chamfer_b, pts[last - 1].distance_to(pts[last]) * 0.9)

static func _to_world(a: Vector2, tangent: Vector2, normal: Vector2, sign_value: int, depth: float, local: Vector2) -> Vector2:
	return a + tangent * local.x + normal * local.y * depth * sign_value

# Classic rounded jigsaw knob. Every parameter is sampled independently per side rather
# than jittered off a fixed template, and the crown spans a continuous spectrum from
# pointed to broad instead of one binary choice.
static func _round_knob(a: Vector2, b: Vector2, tangent: Vector2, normal: Vector2, sign_value: int, depth: float, rng: RandomNumberGenerator) -> PackedVector2Array:
	var center := rng.randf_range(0.40, 0.60)
	var width_left := rng.randf_range(0.10, 0.24)
	var width_right := rng.randf_range(0.10, 0.24)
	var height := rng.randf_range(0.14, 0.30)
	var neck_left := rng.randf_range(0.045, 0.135)
	var neck_right := rng.randf_range(0.045, 0.135)
	var lean := rng.randf_range(-0.045, 0.045)
	var crown_fraction := rng.randf_range(0.0, 0.85)
	var crown := maxf(width_left, width_right) * crown_fraction
	var base_left := center - width_left
	var base_right := center + width_right
	var pts := PackedVector2Array([a])
	pts.append(a + tangent * base_left)
	_curve(pts, a, tangent, normal, sign_value, depth, Vector2(base_left, 0), Vector2(center - width_left * 0.75, 0.02), Vector2(center - width_left * 1.25, neck_left * 0.75), Vector2(center - width_left * 0.8, neck_left), 6)
	_curve(pts, a, tangent, normal, sign_value, depth, Vector2(center - width_left * 0.8, neck_left), Vector2(center - width_left * 1.4 + lean, height * 0.92), Vector2(center - crown + lean, height), Vector2(center + lean, height), 8)
	_curve(pts, a, tangent, normal, sign_value, depth, Vector2(center + lean, height), Vector2(center + crown + lean, height), Vector2(center + width_right * 1.4 + lean, height * 0.92), Vector2(center + width_right * 0.8, neck_right), 8)
	_curve(pts, a, tangent, normal, sign_value, depth, Vector2(center + width_right * 0.8, neck_right), Vector2(center + width_right * 1.25, neck_right * 0.75), Vector2(center + width_right * 0.75, 0.02), Vector2(base_right, 0), 6)
	pts.append(b)
	return pts

# Blocky rectangular tab, optionally chamfered at the corners so it isn't a perfectly
# knife-sharp edge at every scale.
static func _square_tab(a: Vector2, b: Vector2, tangent: Vector2, normal: Vector2, sign_value: int, depth: float, rng: RandomNumberGenerator) -> PackedVector2Array:
	var center := rng.randf_range(0.42, 0.58)
	var half_width := rng.randf_range(0.11, 0.20)
	var height := rng.randf_range(0.16, 0.30)
	var chamfer := rng.randf_range(0.0, half_width * 0.5)
	var base_left := center - half_width
	var base_right := center + half_width
	var pts := PackedVector2Array([a])
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_left, 0)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_left, height - chamfer)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_left + chamfer, height)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_right - chamfer, height)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_right, height - chamfer)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_right, 0)))
	pts.append(b)
	return pts

# Sharp triangular tooth.
static func _triangular_tab(a: Vector2, b: Vector2, tangent: Vector2, normal: Vector2, sign_value: int, depth: float, rng: RandomNumberGenerator) -> PackedVector2Array:
	var center := rng.randf_range(0.40, 0.60)
	var half_width := rng.randf_range(0.12, 0.22)
	var height := rng.randf_range(0.18, 0.32)
	var apex_lean := rng.randf_range(-0.06, 0.06)
	var base_left := center - half_width
	var base_right := center + half_width
	var pts := PackedVector2Array([a])
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_left, 0)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(center + apex_lean, height)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_right, 0)))
	pts.append(b)
	return pts

# Narrow neck with a flat, wider head -- the classic wooden-puzzle "lock" tab.
static func _anchor_tab(a: Vector2, b: Vector2, tangent: Vector2, normal: Vector2, sign_value: int, depth: float, rng: RandomNumberGenerator) -> PackedVector2Array:
	var center := rng.randf_range(0.42, 0.58)
	var base_half_width := rng.randf_range(0.09, 0.16)
	var top_half_width := rng.randf_range(0.14, 0.26)
	var neck_height := rng.randf_range(0.08, 0.16)
	var height := rng.randf_range(0.20, 0.32)
	var base_left := center - base_half_width
	var base_right := center + base_half_width
	var top_left := center - top_half_width
	var top_right := center + top_half_width
	var pts := PackedVector2Array([a])
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_left, 0)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_left, neck_height)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(top_left, height)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(top_right, height)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_right, neck_height)))
	pts.append(_to_world(a, tangent, normal, sign_value, depth, Vector2(base_right, 0)))
	pts.append(b)
	return pts

static func _curve(points: PackedVector2Array, a: Vector2, tangent: Vector2, normal: Vector2, sign_value: int, depth: float, p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, steps: int) -> void:
	for i in range(1, steps + 1):
		var t := float(i) / steps
		var u := 1.0 - t
		var p := u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3
		points.append(a + tangent * p.x + normal * p.y * depth * sign_value)
