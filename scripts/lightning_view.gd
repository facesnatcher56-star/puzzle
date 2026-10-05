class_name LightningView
extends Node2D

# What the Lightning Zone looks like: the marking printed on the board beneath the pieces, the charge-up
# when the zone is completed, and the bolts that hit each struck place. It only reacts to the controller's
# signals; it never decides anything.

const BOLT := [Vector2(0.62, 0.0), Vector2(0.16, 0.56), Vector2(0.46, 0.56), Vector2(0.32, 1.0), Vector2(0.86, 0.38), Vector2(0.55, 0.38)]
const INK := Color(1.0, 0.9, 0.42)
const SPARK := Color(1.0, 0.97, 0.78)

var session: PuzzleSession
var manager: PuzzleManager
var board: PuzzleBoard
var controller: LightningController
var fx: BoardFx
var sfx: Sfx
var effects_enabled := DisplayServer.get_name() != "headless"

var charge := 0.0 # 0..1, brightens the marking while the zone charges up
var _clock := 0.0
var _layer: Node2D # bolts and flashes, above the pieces

class Flash extends Node2D:
	var rect := Rect2()
	var alpha := 0.0
	func _draw() -> void:
		draw_rect(rect, Color(1.0, 0.97, 0.8, alpha), true)

func setup(p_session: PuzzleSession, p_manager: PuzzleManager, p_board: PuzzleBoard, p_controller: LightningController, p_fx: BoardFx, p_sfx: Sfx) -> void:
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
	controller.activated.connect(_on_activated)
	controller.strike_incoming.connect(_on_strike_incoming)

func _reset() -> void:
	charge = 0.0
	for child in _layer.get_children():
		child.queue_free()
	queue_redraw()

func _process(delta: float) -> void:
	_clock += delta
	var zone := session.lightning_zone
	if zone != null and (not zone.activated or charge > 0.0):
		queue_redraw() # the marking breathes slowly until it has been used

# --- the marking on the board ---

func _draw() -> void:
	var zone := session.lightning_zone
	if zone == null or manager.pieces.size() != zone.columns * zone.rows:
		return
	var rect := zone.world_rect(manager)
	var spent := zone.activated and charge < 0.01
	var breath := 0.5 + 0.5 * sin(_clock * 1.8)
	var strength := 0.3 if spent else 1.0 + 0.5 * charge
	var wash := (0.05 + 0.025 * breath + 0.12 * charge) * strength
	draw_rect(rect, Color(INK.r, INK.g, INK.b, wash), true)
	var line := Color(INK.r, INK.g, INK.b, (0.28 + 0.1 * breath + 0.4 * charge) * strength)
	_draw_corners(rect, line)
	# the bolt, printed in the middle, as large as fits
	var size := minf(rect.size.x, rect.size.y) * 0.82
	var origin := rect.get_center() - Vector2(size, size) * 0.5
	var points := PackedVector2Array()
	for p in BOLT:
		points.append(origin + p * size)
	draw_colored_polygon(points, Color(INK.r, INK.g, INK.b, (0.16 + 0.07 * breath + 0.35 * charge) * strength))
	points.append(points[0])
	draw_polyline(points, Color(INK.r, INK.g, INK.b, (0.5 + 0.15 * breath + 0.4 * charge) * strength), 2.5, true)

# Four corner brackets rather than a full outline, so the zone reads as printed on the board, not as a window.
func _draw_corners(rect: Rect2, color: Color) -> void:
	var arm := minf(rect.size.x, rect.size.y) * 0.18
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	var inward := [Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1), Vector2(1, -1)]
	for i in range(4):
		var c: Vector2 = corners[i]
		var d: Vector2 = inward[i]
		draw_line(c, c + Vector2(d.x * arm, 0), color, 3.0)
		draw_line(c, c + Vector2(0, d.y * arm), color, 3.0)

# --- reacting to the controller ---

func _on_activated() -> void:
	var zone := session.lightning_zone
	if zone == null or not effects_enabled or manager.pieces.size() != zone.columns * zone.rows:
		return
	var rect := zone.world_rect(manager)
	sfx.zap()
	# the marking charges up, then the whole zone flashes and bolts crack down on its corners
	var tween := create_tween()
	tween.tween_property(self, "charge", 1.0, 0.45)
	tween.tween_callback(func():
		_flash(rect, 0.55, 0.5)
		fx.ring(rect.get_center(), maxf(rect.size.x, rect.size.y) * 0.9, Color(1.0, 0.95, 0.6, 0.95), 0.7, 9.0)
		fx.sparkles(rect.get_center(), 40, SPARK, 520.0, 1.0, 9.0)
		for corner in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
			_bolt(corner))
	tween.tween_property(self, "charge", 0.0, 1.2)

func _on_strike_incoming(_piece_id: int, member_ids: Array, target_rect: Rect2) -> void:
	board.glide(member_ids)
	if not effects_enabled:
		return
	var delay := controller.strike_delay if not controller.network.is_client() else 0.0
	# On the host the bolt lands just before the piece moves; a client gets the bolt as the announcement arrives.
	var hit := create_tween()
	hit.tween_interval(maxf(0.0, delay - 0.3))
	hit.tween_callback(func(): _strike(target_rect))

func _strike(target_rect: Rect2) -> void:
	var spot := target_rect.get_center()
	sfx.zap()
	_flash(target_rect.grow(6.0), 0.8, 0.45)
	_bolt(spot)
	fx.ring(spot, maxf(target_rect.size.x, target_rect.size.y) * 1.1, Color(1.0, 0.95, 0.6, 0.95), 0.5, 6.0)
	fx.sparkles(spot, 22, SPARK, 360.0, 0.7, 7.0)

func _flash(rect: Rect2, peak: float, duration: float) -> void:
	var flash := Flash.new()
	flash.rect = rect
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
