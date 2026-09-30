class_name PuzzlePieceView
extends Node2D

var data: PuzzlePieceState
var texture_source: Texture2D
var cell_size: Vector2
var selected := false
const SHADOW_OFFSET := Vector2(2, 3.5)
const SOFT_SHADOW_OFFSET := Vector2(5, 8)
var shadow: Polygon2D
var soft_shadow: Polygon2D
var rim: PieceRim
var art: Polygon2D
var border: Line2D
var highlight: Line2D

func setup(piece: PuzzlePieceState, source: Texture2D, size: Vector2) -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	data = piece
	texture_source = source
	cell_size = size
	# Two stacked shadows: a wide faint one for ambient falloff and a tight dark one for contact.
	soft_shadow = Polygon2D.new()
	soft_shadow.polygon = data.outline
	soft_shadow.color = Color(0.02, 0.03, 0.04, 0.22)
	soft_shadow.position = SOFT_SHADOW_OFFSET
	add_child(soft_shadow)
	shadow = Polygon2D.new()
	shadow.polygon = data.outline
	shadow.color = Color(0.02, 0.03, 0.04, 0.42)
	shadow.position = SHADOW_OFFSET
	add_child(shadow)
	art = Polygon2D.new()
	art.polygon = data.outline
	art.uv = data.uv
	art.texture = texture_source
	add_child(art)
	border = Line2D.new()
	border.points = _closed_outline()
	border.width = 1.4
	border.default_color = Color(0.06, 0.08, 0.1, 0.78)
	border.antialiased = true
	border.joint_mode = Line2D.LINE_JOINT_ROUND
	add_child(border)
	rim = PieceRim.new()
	rim.setup(data.outline)
	add_child(rim)
	highlight = Line2D.new()
	highlight.points = _closed_outline()
	highlight.width = 4.0
	highlight.default_color = Color(1.0, 0.86, 0.46, 0.95)
	highlight.antialiased = true
	highlight.visible = false
	add_child(highlight)

func _closed_outline() -> PackedVector2Array:
	var pts := data.outline.duplicate()
	pts.append(pts[0])
	return pts

func set_selected(value: bool) -> void:
	selected = value
	if highlight:
		highlight.visible = value

func hit_test(world_point: Vector2) -> bool:
	return Geometry2D.is_point_in_polygon(to_local(world_point), data.outline)

# Position every representation around the same cell center, including quarter turns.
func place_centered(center: Vector2, factor: float = 1.0) -> void:
	scale = Vector2.ONE * factor
	rotation_degrees = data.current_rotation
	if rim != null:
		# Light and shadows stay fixed in the world (light from the upper left) however the piece is turned.
		rim.set_light(Vector2(-0.6, -0.8).rotated(-rotation))
		shadow.position = SHADOW_OFFSET.rotated(-rotation)
		soft_shadow.position = SOFT_SHADOW_OFFSET.rotated(-rotation)
	position = center - (cell_size * 0.5).rotated(rotation) * factor


# Bevel lighting: every outline segment is inset a hair and tinted by how squarely it faces
# the light, so edges toward the upper left catch a highlight and the opposite edges sink
# into shade, giving each piece a pressed-cardboard thickness.
class PieceRim extends Node2D:
	var points: PackedVector2Array
	var light := Vector2(-0.6, -0.8)
	var outward_sign := 1.0

	func setup(outline: PackedVector2Array) -> void:
		points = outline
		var area := 0.0
		for i in range(points.size()):
			var a := points[i]
			var b := points[(i + 1) % points.size()]
			area += a.x * b.y - b.x * a.y
		outward_sign = 1.0 if area > 0.0 else -1.0

	func set_light(value: Vector2) -> void:
		if value.distance_squared_to(light) < 0.0001:
			return
		light = value
		queue_redraw()

	func _draw() -> void:
		var segments := PackedVector2Array()
		var colors := PackedColorArray()
		var inset := 1.3
		for i in range(points.size()):
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
			var color := Color(1, 1, 1, shade * 0.5) if shade > 0.0 else Color(0, 0, 0, -shade * 0.42)
			colors.append(color)
		if not segments.is_empty():
			draw_multiline_colors(segments, colors, 2.4)
