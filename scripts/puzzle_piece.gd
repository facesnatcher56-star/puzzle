class_name PuzzlePieceView
extends Node2D

var data: PuzzlePieceState
var texture_source: Texture2D
var cell_size: Vector2
var selected := false
var shadow: Polygon2D
var art: Polygon2D
var border: Line2D
var highlight: Line2D

func setup(piece: PuzzlePieceState, source: Texture2D, size: Vector2) -> void:
	data = piece
	texture_source = source
	cell_size = size
	shadow = Polygon2D.new()
	shadow.polygon = data.outline
	shadow.color = Color(0.02, 0.03, 0.04, 0.45)
	shadow.position = Vector2(3, 5)
	add_child(shadow)
	art = Polygon2D.new()
	art.polygon = data.outline
	art.uv = data.uv
	art.texture = texture_source
	add_child(art)
	border = Line2D.new()
	border.points = _closed_outline()
	border.width = 1.7
	border.default_color = Color(0.12, 0.16, 0.18, 0.82)
	border.antialiased = true
	add_child(border)
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
