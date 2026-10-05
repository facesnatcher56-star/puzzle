class_name PowerView
extends Node2D

# What the board-power zones look like. With about 60% of the board powered, the markings have to stay quiet:
# each zone is a faint engraved symbol (a bolt for Lightning, a horseshoe for Magnet), a thin border and a
# little hatching, printed on the board beneath the pieces, so an empty board reads like a pinball table made
# of puzzle cells and not a grid of coloured boxes. Charging and activation brighten a zone briefly.
# It only reacts to the controller's signals; it never decides anything.

const BOLT := [Vector2(0.62, 0.0), Vector2(0.16, 0.56), Vector2(0.46, 0.56), Vector2(0.32, 1.0), Vector2(0.86, 0.38), Vector2(0.55, 0.38)]
const LIGHTNING_INK := Color(1.0, 0.9, 0.42)
const MAGNET_INK := Color(0.43, 0.95, 0.82)
const SPARK := Color(1.0, 0.97, 0.78)
const HATCH_SPACING := 30.0

var session: PuzzleSession
var manager: PuzzleManager
var board: PuzzleBoard
var controller: PowerController
var fx: BoardFx
var sfx: Sfx
var effects_enabled := DisplayServer.get_name() != "headless"

var _rects: Array = [] # each zone's footprint in board coordinates
var _glow := {} # zone index -> 0..1, brightens a zone while it charges and fires
var _layer: Node2D # bolts and flashes, above the pieces

class Flash extends Node2D:
	var rect := Rect2()
	var color := Color.WHITE
	var alpha := 0.0
	func _draw() -> void:
		draw_rect(rect, Color(color.r, color.g, color.b, alpha), true)

func setup(p_session: PuzzleSession, p_manager: PuzzleManager, p_board: PuzzleBoard, p_controller: PowerController, p_fx: BoardFx, p_sfx: Sfx) -> void:
	session = p_session
	manager = p_manager
	board = p_board
	controller = p_controller
	fx = p_fx
	sfx = p_sfx
	_layer = Node2D.new()
	_layer.z_index = 60
	add_child(_layer)
	session.puzzle_started.connect(func(_pieces): _reset())
	session.puzzle_restored.connect(func(_pieces): _reset())
	controller.zone_activated.connect(_on_zone_activated)
	controller.zones_changed.connect(queue_redraw)
	controller.strike_incoming.connect(_on_strike_incoming)
	controller.strike_landed.connect(_on_strike_landed)

func _reset() -> void:
	_glow.clear()
	for child in _layer.get_children():
		child.queue_free()
	_rects.clear()
	for zone in session.power_zones:
		_rects.append(zone.world_rect(manager) if manager.pieces.size() == zone.columns * zone.rows else Rect2())
	queue_redraw()

# --- the markings on the board ---

func _draw() -> void:
	for i in range(mini(_rects.size(), session.power_zones.size())):
		_draw_zone(session.power_zones[i], _rects[i], float(_glow.get(i, 0.0)))

func _draw_zone(zone: PowerZone, rect: Rect2, glow: float) -> void:
	if rect.size == Vector2.ZERO:
		return
	var ink := LIGHTNING_INK if zone.kind == PowerZone.Kind.LIGHTNING else MAGNET_INK
	# idle zones are faint, queued ones a little brighter, used ones fade to almost nothing
	var strength := 1.0
	if zone.state == PowerZone.State.QUEUED:
		strength = 1.7
	elif zone.state == PowerZone.State.DONE:
		strength = 0.35
	strength += glow * 2.0
	var inner := rect.grow(-3.0)
	draw_rect(inner, Color(ink.r, ink.g, ink.b, 0.03 * strength), true)
	_draw_hatching(inner, zone.kind, Color(ink.r, ink.g, ink.b, 0.05 * strength))
	draw_rect(inner, Color(ink.r, ink.g, ink.b, 0.16 * strength), false, 1.5)
	var size := minf(minf(rect.size.x, rect.size.y) * 0.6, 300.0)
	if zone.kind == PowerZone.Kind.LIGHTNING:
		_engrave_bolt(rect.get_center(), size, ink, strength)
	else:
		_engrave_magnet(rect.get_center(), size, ink, strength)

# Fine diagonal lines clipped to the rectangle; Lightning leans one way and Magnet the other.
func _draw_hatching(rect: Rect2, kind: int, color: Color) -> void:
	if rect.size.x < HATCH_SPACING * 1.5 and rect.size.y < HATCH_SPACING * 1.5:
		return
	var lean := 1.0 if kind == PowerZone.Kind.LIGHTNING else -1.0
	# lines x + lean * y = s, for s across the rectangle's range
	var low := rect.position.x + (rect.position.y if lean > 0.0 else -rect.end.y)
	var high := rect.end.x + (rect.end.y if lean > 0.0 else -rect.position.y)
	var s := low + HATCH_SPACING
	while s < high:
		# x range where the line stays inside the rectangle's height
		var x0 := maxf(rect.position.x, s - lean * (rect.end.y if lean > 0.0 else rect.position.y))
		var x1 := minf(rect.end.x, s - lean * (rect.position.y if lean > 0.0 else rect.end.y))
		if x1 > x0:
			draw_line(Vector2(x0, (s - x0) * lean), Vector2(x1, (s - x1) * lean), color, 1.0)
		s += HATCH_SPACING

# A symbol pressed into the board: a dark offset below and a light offset above give it depth, then a faint fill.
func _engrave_bolt(center: Vector2, size: float, ink: Color, strength: float) -> void:
	var points := PackedVector2Array()
	var origin := center - Vector2(size, size) * 0.5
	for p in BOLT:
		points.append(origin + p * size)
	var shadow := points.duplicate()
	var light := points.duplicate()
	for i in range(points.size()):
		shadow[i] += Vector2(1.6, 1.6)
		light[i] -= Vector2(1.2, 1.2)
	draw_colored_polygon(points, Color(ink.r, ink.g, ink.b, 0.11 * strength))
	for outline in [[shadow, Color(0.02, 0.04, 0.05, 0.3 * minf(strength, 1.5))], [light, Color(1.0, 1.0, 0.9, 0.2 * minf(strength, 1.5))], [points, Color(ink.r, ink.g, ink.b, 0.42 * strength)]]:
		var line: PackedVector2Array = outline[0].duplicate()
		line.append(line[0])
		draw_polyline(line, outline[1], 1.6, true)

func _engrave_magnet(center: Vector2, size: float, ink: Color, strength: float) -> void:
	var radius := size * 0.3
	var width := maxf(2.5, radius * 0.34)
	var layers := [[Vector2(1.6, 1.6), Color(0.02, 0.04, 0.05, 0.3 * minf(strength, 1.5))], [Vector2(-1.2, -1.2), Color(1.0, 1.0, 0.95, 0.2 * minf(strength, 1.5))], [Vector2.ZERO, Color(ink.r, ink.g, ink.b, 0.4 * strength)]]
	var base_y := center.y + radius * 0.1 - radius * 0.35 # the horseshoe is drawn a little high so the whole symbol sits in the middle
	for layer in layers:
		var offset: Vector2 = layer[0]
		var color: Color = layer[1]
		var bend := Vector2(center.x, base_y) + offset
		draw_arc(bend, radius, 0.0, PI, 24, color, width, true)
		for side in [-1.0, 1.0]:
			var leg_x: float = bend.x + side * radius
			var tip_y: float = bend.y - radius * 1.05
			draw_line(Vector2(leg_x, bend.y), Vector2(leg_x, tip_y), color, width, true)
			# the pole tip: the last stretch of each leg, brighter than the rest
			var tip := Color(minf(color.r + 0.35, 1.0), minf(color.g + 0.35, 1.0), minf(color.b + 0.35, 1.0), color.a * 1.5)
			draw_line(Vector2(leg_x, tip_y + radius * 0.34), Vector2(leg_x, tip_y), tip, width, true)

# --- reacting to the controller ---

func _on_zone_activated(zone_index: int) -> void:
	if not effects_enabled or zone_index >= _rects.size():
		return
	var zone: PowerZone = session.power_zones[zone_index]
	var rect: Rect2 = _rects[zone_index]
	if zone.kind == PowerZone.Kind.LIGHTNING:
		_charge_lightning(zone_index, rect)
	else:
		sfx.magnet_hum()
		fx.ring(rect.get_center(), maxf(rect.size.x, rect.size.y) * 0.85, Color(0.4, 1.0, 0.86, 0.8), 0.8, 8.0)
		_pulse_glow(zone_index, 0.25, 1.1)

func _charge_lightning(zone_index: int, rect: Rect2) -> void:
	sfx.zap()
	_pulse_glow(zone_index, 0.45, 1.2)
	var big := rect.size.x * rect.size.y > 60000.0
	var tween := create_tween()
	tween.tween_interval(0.45)
	tween.tween_callback(func():
		_flash(rect, LIGHTNING_INK.lerp(Color.WHITE, 0.6), 0.5, 0.5)
		fx.ring(rect.get_center(), maxf(rect.size.x, rect.size.y) * 0.9, Color(1.0, 0.95, 0.6, 0.95), 0.7, 9.0)
		fx.sparkles(rect.get_center(), 40, SPARK, 520.0, 1.0, 9.0)
		if big: # a big zone gets a bolt on every corner; a small one just the one
			for corner in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
				_bolt(corner)
		else:
			_bolt(rect.get_center()))

func _pulse_glow(zone_index: int, rise: float, fall: float) -> void:
	var tween := create_tween()
	tween.tween_method(func(value: float):
		_glow[zone_index] = value
		queue_redraw(), 0.0, 1.0, rise)
	tween.tween_method(func(value: float):
		_glow[zone_index] = value
		queue_redraw(), 1.0, 0.0, fall)

func _on_strike_incoming(zone_index: int, _piece_id: int, member_ids: Array, target_rect: Rect2) -> void:
	var lightning: bool = zone_index < session.power_zones.size() and session.power_zones[zone_index].kind == PowerZone.Kind.LIGHTNING
	if lightning:
		board.glide(member_ids)
	else:
		board.magnet_glide(member_ids)
	if not effects_enabled:
		return
	if not lightning:
		sfx.magnet_pull()
		return
	var delay := controller.strike_delay if not controller.network.is_client() else 0.0
	# On the host the bolt lands just before the piece moves; a client gets the bolt as the announcement arrives.
	var hit := create_tween()
	hit.tween_interval(maxf(0.0, delay - 0.3))
	hit.tween_callback(func(): _strike(target_rect))

func _strike(target_rect: Rect2) -> void:
	var spot := target_rect.get_center()
	sfx.zap()
	_flash(target_rect.grow(6.0), Color(1.0, 0.97, 0.8), 0.8, 0.45)
	_bolt(spot)
	fx.ring(spot, maxf(target_rect.size.x, target_rect.size.y) * 1.1, Color(1.0, 0.95, 0.6, 0.95), 0.5, 6.0)
	fx.sparkles(spot, 22, SPARK, 360.0, 0.7, 7.0)

func _on_strike_landed(zone_index: int, piece_id: int, _moved_ids: Array) -> void:
	if not effects_enabled or zone_index < 0 or zone_index >= session.power_zones.size():
		return
	if session.power_zones[zone_index].kind != PowerZone.Kind.MAGNET:
		return
	var target := manager.pieces[piece_id]
	fx.ring(target.correct_position + target.piece_size * 0.5, maxf(target.piece_size.x, target.piece_size.y) * 0.7, MAGNET_INK, 0.35, 5.0)

func _flash(rect: Rect2, color: Color, peak: float, duration: float) -> void:
	var flash := Flash.new()
	flash.rect = rect
	flash.color = color
	_layer.add_child(flash)
	var tween := create_tween()
	tween.tween_method(func(value: float):
		flash.alpha = value
		flash.queue_redraw(), peak, 0.0, duration)
	tween.tween_callback(flash.queue_free)

# A jagged bolt from high above the board down to `target`, drawn twice (a soft wide glow and a bright core).
func _bolt(target: Vector2) -> void:
	var points := PackedVector2Array()
	var top := Vector2(target.x + randf_range(-160.0, 160.0), target.y - 900.0)
	var segments := 11
	for i in range(segments + 1):
		var t := float(i) / segments
		var point := top.lerp(target, t)
		if i > 0 and i < segments:
			point.x += randf_range(-46.0, 46.0)
		points.append(point)
	var glow := Line2D.new()
	glow.points = points
	glow.width = 26.0
	glow.default_color = Color(1.0, 0.9, 0.4, 0.28)
	glow.joint_mode = Line2D.LINE_JOINT_ROUND
	_layer.add_child(glow)
	var core := Line2D.new()
	core.points = points
	core.width = 7.0
	core.default_color = Color(1.0, 0.99, 0.9, 1.0)
	core.joint_mode = Line2D.LINE_JOINT_ROUND
	_layer.add_child(core)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(glow, "modulate:a", 0.0, 0.4)
	tween.tween_property(core, "modulate:a", 0.0, 0.32)
	tween.chain().tween_callback(func():
		glow.queue_free()
		core.queue_free())
