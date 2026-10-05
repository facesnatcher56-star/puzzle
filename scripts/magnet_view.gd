class_name MagnetView
extends Node2D

# Teal field marking and expanding magnetic pulse; gameplay decisions stay in MagnetController.
const INK := Color(0.43, 0.95, 0.82)

var session: PuzzleSession
var manager: PuzzleManager
var board: PuzzleBoard
var controller: MagnetController
var fx: BoardFx
var sfx: Sfx
var effects_enabled := DisplayServer.get_name() != "headless"
var energy := 0.0
var _clock := 0.0

func setup(p_session: PuzzleSession, p_manager: PuzzleManager, p_board: PuzzleBoard, p_controller: MagnetController, p_fx: BoardFx, p_sfx: Sfx) -> void:
	session = p_session
	manager = p_manager
	board = p_board
	controller = p_controller
	fx = p_fx
	sfx = p_sfx
	session.puzzle_started.connect(func(_pieces): _reset())
	session.puzzle_restored.connect(func(_pieces): _reset())
	controller.activated.connect(_on_activated)
	controller.pull_incoming.connect(_on_pull_incoming)
	controller.pull_landed.connect(_on_pull_landed)

func _reset() -> void:
	energy = 0.0
	queue_redraw()

func _process(delta: float) -> void:
	_clock += delta
	if session.magnet_zone != null and (not session.magnet_zone.activated or energy > 0.0):
		queue_redraw()

func _draw() -> void:
	var zone := session.magnet_zone
	if zone == null or manager.pieces.size() != zone.columns * zone.rows:
		return
	var rect := zone.world_rect(manager)
	var breath := 0.5 + 0.5 * sin(_clock * 1.6)
	var strength := 0.24 if zone.activated and energy < 0.01 else 1.0 + energy
	draw_rect(rect, Color(INK.r, INK.g, INK.b, (0.04 + 0.02 * breath + 0.13 * energy) * strength), true)
	var line := Color(INK.r, INK.g, INK.b, (0.27 + 0.09 * breath + 0.5 * energy) * strength)
	var arm := minf(rect.size.x, rect.size.y) * 0.17
	for entry in [[rect.position, Vector2(1, 1)], [Vector2(rect.end.x, rect.position.y), Vector2(-1, 1)], [rect.end, Vector2(-1, -1)], [Vector2(rect.position.x, rect.end.y), Vector2(1, -1)]]:
		var corner: Vector2 = entry[0]
		var inward: Vector2 = entry[1]
		draw_line(corner, corner + Vector2(inward.x * arm, 0), line, 3.0)
		draw_line(corner, corner + Vector2(0, inward.y * arm), line, 3.0)
	# A simple horseshoe magnet with two pole caps, printed beneath the completed cells.
	var center := rect.get_center()
	var radius := minf(rect.size.x, rect.size.y) * 0.25
	draw_arc(center, radius, 0.1 * PI, 0.9 * PI, 24, line, 7.0, true)
	for x in [-1.0, 1.0]:
		var pole_x: float = center.x + x * radius * 0.95
		draw_line(Vector2(pole_x, center.y - radius * 0.12), Vector2(pole_x, center.y - radius * 0.72), line, 7.0, true)
		draw_line(Vector2(pole_x - 9, center.y - radius * 0.72), Vector2(pole_x + 9, center.y - radius * 0.72), line, 5.0, true)

func _on_activated() -> void:
	var zone := session.magnet_zone
	if zone == null or not effects_enabled or manager.pieces.size() != zone.columns * zone.rows:
		return
	var rect := zone.world_rect(manager)
	sfx.magnet_hum()
	fx.ring(rect.get_center(), maxf(rect.size.x, rect.size.y) * 0.85, Color(0.4, 1.0, 0.86, 0.8), 0.8, 8.0)
	var tween := create_tween()
	tween.tween_property(self, "energy", 1.0, 0.25)
	tween.tween_property(self, "energy", 0.0, 1.1)

func _on_pull_incoming(_piece_id: int, member_ids: Array, _rect: Rect2) -> void:
	board.magnet_glide(member_ids)
	if effects_enabled:
		sfx.magnet_pull()

func _on_pull_landed(piece_id: int, _moved_ids: Array) -> void:
	if not effects_enabled:
		return
	var target := manager.pieces[piece_id]
	fx.ring(target.correct_position + target.piece_size * 0.5, maxf(target.piece_size.x, target.piece_size.y) * 0.7, INK, 0.35, 5.0)
