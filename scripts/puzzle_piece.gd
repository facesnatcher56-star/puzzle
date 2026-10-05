class_name PuzzlePieceView
extends Node2D

const SHADOW_OFFSET := Vector2(2, 3.5)
const SOFT_SHADOW_OFFSET := Vector2(5, 8)
# Joined pieces grow a hair into each other so antialiasing can never leave a visible seam.
const SEAM_OVERLAP := 0.8

var data: PuzzlePieceState
var texture_source: Texture2D
var cell_size: Vector2
var selected := false
# Set by the board for pieces on the table: lets the piece see which neighbours it is joined to,
# and moves its shadows onto a layer beneath every resting piece so one piece's shadow never
# darkens the piece it is joined to.
var manager: PuzzleManager
var table_mode := false
# Everything visible lives under `body`, so a celebration "pop" can scale the piece about its own
# centre without disturbing the position/rotation the board relies on.
var body: Node2D
var pop_tween: Tween
var shadow: Polygon2D
var soft_shadow: Polygon2D
var art: Polygon2D
var edges: PieceEdges
var joined_mask := 0
var locked := false

func setup(piece: PuzzlePieceState, source: Texture2D, size: Vector2) -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	data = piece
	texture_source = source
	cell_size = size
	body = Node2D.new()
	add_child(body)
	# Two stacked shadows: a wide faint one for ambient falloff and a tight dark one for contact.
	soft_shadow = Polygon2D.new()
	soft_shadow.polygon = data.outline
	soft_shadow.color = Color(0.02, 0.03, 0.04, 0.22)
	soft_shadow.position = SOFT_SHADOW_OFFSET
	body.add_child(soft_shadow)
	shadow = Polygon2D.new()
	shadow.polygon = data.outline
	shadow.color = Color(0.02, 0.03, 0.04, 0.42)
	shadow.position = SHADOW_OFFSET
	body.add_child(shadow)
	if table_mode:
		soft_shadow.z_index = -1
		shadow.z_index = -1
	art = Polygon2D.new()
	art.polygon = data.outline
	art.uv = data.uv
	art.texture = texture_source
	body.add_child(art)
	edges = PieceEdges.new()
	edges.setup(data)
	body.add_child(edges)

# Re-reads which sides are joined to a neighbour in the same group; only redraws when that changes.
func refresh_seams() -> void:
	if manager == null:
		return
	var mask := 0
	for side in range(4):
		if manager.is_joined_side(data.piece_id, side):
			mask |= 1 << side
	if mask == joined_mask:
		return
	joined_mask = mask
	edges.set_joined(mask)
	if mask == 0:
		art.polygon = data.outline
		art.uv = data.uv
		return
	var grown := Geometry2D.offset_polygon(data.outline, SEAM_OVERLAP, Geometry2D.JOIN_ROUND)
	if grown.is_empty():
		return
	var best: PackedVector2Array = grown[0]
	for candidate in grown:
		if _polygon_area(candidate) > _polygon_area(best):
			best = candidate
	var texture_uv := PackedVector2Array()
	for point in best:
		texture_uv.append((point + data.uv_origin) * data.uv_scale)
	art.polygon = best
	art.uv = texture_uv

static func _polygon_area(points: PackedVector2Array) -> float:
	var area := 0.0
	for i in range(points.size()):
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		area += a.x * b.y - b.x * a.y
	return absf(area) * 0.5

# Celebration pop: swells the piece a touch and settles back, optionally after a delay.
func pulse(amount: float, delay: float = 0.0) -> void:
	if body == null or not is_inside_tree():
		return
	if pop_tween != null and pop_tween.is_valid():
		pop_tween.kill()
	var centre := cell_size * 0.5
	pop_tween = create_tween()
	if delay > 0.0:
		pop_tween.tween_interval(delay)
	pop_tween.tween_method(func(t: float):
		var factor := 1.0 + amount * sin(PI * t)
		body.scale = Vector2.ONE * factor
		body.position = centre * (1.0 - factor), 0.0, 1.0, 0.3).set_trans(Tween.TRANS_SINE)
	pop_tween.tween_callback(func():
		body.scale = Vector2.ONE
		body.position = Vector2.ZERO)

# Locked pieces are fixed to the board; a faint gold edge on the outside of the locked section marks it.
func set_locked(value: bool) -> void:
	if locked == value:
		return
	locked = value
	if edges:
		edges.set_locked(value)

func set_selected(value: bool) -> void:
	selected = value
	if edges:
		edges.set_selected(value)

# Pulsing finder glow, used to show where loose edge/corner pieces are.
func set_flagged(value: bool) -> void:
	if edges:
		edges.set_flagged(value)
	z_index = 5 if value else 0 # lifted so the glow is never hidden under neighbours

func hit_test(world_point: Vector2) -> bool:
	return Geometry2D.is_point_in_polygon(to_local(world_point), data.outline)

# Position every representation around the same cell center, including quarter turns.
func place_centered(center: Vector2, factor: float = 1.0) -> void:
	scale = Vector2.ONE * factor
	rotation_degrees = data.current_rotation
	position = center - (cell_size * 0.5).rotated(rotation) * factor
	if edges != null:
		# Light and shadows stay fixed in the world (light from the upper left) however the piece is turned.
		edges.set_light(Vector2(-0.6, -0.8).rotated(-rotation))
		shadow.position = SHADOW_OFFSET.rotated(-rotation)
		soft_shadow.position = SOFT_SHADOW_OFFSET.rotated(-rotation)

# Draws the piece's outline: a dark border, a bevel lit from the upper left, and the selection
# glow. Sides joined to a neighbour are skipped entirely so a finished group reads as one piece.
class PieceEdges extends Node2D:
	const BORDER_COLOR := Color(0.06, 0.08, 0.1, 0.78)
	const HIGHLIGHT_COLOR := Color(1.0, 0.86, 0.46, 0.95)
	var points: PackedVector2Array
	var segment_side := PackedInt32Array() # which side (0 top, 1 right, 2 bottom, 3 left) each outline segment lies on
	var joined_mask := 0
	var light := Vector2(-0.6, -0.8)
	var outward_sign := 1.0
	var selected := false
	var flagged := false
	var locked := false
	var pulse := 0.0

	func set_locked(value: bool) -> void:
		locked = value
		queue_redraw()

	func set_flagged(value: bool) -> void:
		if flagged == value:
			return
		flagged = value
		set_process(value)
		queue_redraw()

	func _process(delta: float) -> void:
		pulse += delta * 6.0
		queue_redraw()

	func setup(piece: PuzzlePieceState) -> void:
		points = piece.outline
		var area := 0.0
		for i in range(points.size()):
			var a := points[i]
			var b := points[(i + 1) % points.size()]
			area += a.x * b.y - b.x * a.y
		outward_sign = 1.0 if area > 0.0 else -1.0
		var side_points := []
		for side in range(4):
			var keys := {}
			for point in piece.edge_contours[side]:
				keys[_key(point)] = true
			side_points.append(keys)
		segment_side.resize(points.size())
		for i in range(points.size()):
			var ka := _key(points[i])
			var kb := _key(points[(i + 1) % points.size()])
			segment_side[i] = -1
			for side in range(4):
				if side_points[side].has(ka) and side_points[side].has(kb):
					segment_side[i] = side
					break

	static func _key(point: Vector2) -> Vector2i:
		return Vector2i(roundi(point.x * 50.0), roundi(point.y * 50.0))

	func set_joined(mask: int) -> void:
		joined_mask = mask
		queue_redraw()

	func set_selected(value: bool) -> void:
		selected = value
		queue_redraw()

	func set_light(value: Vector2) -> void:
		if value.distance_squared_to(light) < 0.0001:
			return
		light = value
		queue_redraw()

	func _exposed(segment: int) -> bool:
		var side := segment_side[segment]
		return side < 0 or (joined_mask & (1 << side)) == 0

	# Consecutive exposed segments as polylines, so line joins stay clean.
	func _runs() -> Array:
		var count := points.size()
		var runs := []
		var start := -1
		for i in range(count):
			if not _exposed(i) and _exposed((i + 1) % count):
				start = (i + 1) % count
				break
		if start < 0:
			if joined_mask == 0:
				var loop := points.duplicate()
				loop.append(points[0])
				runs.append(loop)
			return runs
		var current := PackedVector2Array()
		for step in range(count):
			var i := (start + step) % count
			if _exposed(i):
				if current.is_empty():
					current.append(points[i])
				current.append(points[(i + 1) % count])
			elif not current.is_empty():
				runs.append(current)
				current = PackedVector2Array()
		if not current.is_empty():
			runs.append(current)
		return runs

	func _draw() -> void:
		var runs := _runs()
		for run in runs:
			draw_polyline(run, BORDER_COLOR, 1.4, true)
		var segments := PackedVector2Array()
		var colors := PackedColorArray()
		var inset := 1.3
		for i in range(points.size()):
			if not _exposed(i):
				continue
			var a := points[i]
			var b := points[(i + 1) % points.size()]
			var d := b - a
			if d.length_squared() < 0.01:
				continue
			var normal := Vector2(d.y, -d.x).normalized() * outward_sign
			var shade := normal.dot(light)
			if absf(shade) < 0.06:
				continue
			segments.append(a - normal * inset)
			segments.append(b - normal * inset)
			colors.append(Color(1, 1, 1, shade * 0.5) if shade > 0.0 else Color(0, 0, 0, -shade * 0.42))
		if not segments.is_empty():
			draw_multiline_colors(segments, colors, 2.4)
		if locked:
			for run in runs:
				draw_polyline(run, Color(1.0, 0.82, 0.4, 0.5), 2.6, true)
		if selected:
			for run in runs:
				draw_polyline(run, HIGHLIGHT_COLOR, 4.0, true)
		if flagged:
			var glow := Color(0.25, 0.95, 1.0, 0.65 + 0.35 * sin(pulse))
			for run in runs:
				draw_polyline(run, Color(glow.r, glow.g, glow.b, glow.a * 0.35), 11.0, true)
				draw_polyline(run, glow, 5.0, true)
