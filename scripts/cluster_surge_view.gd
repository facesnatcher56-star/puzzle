class_name ClusterSurgeView
extends Node2D

# What Cluster Surge looks like: while the player hovers or holds the ability's slot, the seams around the
# selected group where something could be pulled in glow faintly (without saying which three will be chosen);
# when it fires, the group pulses and a bright thread draws each neighbour in. It reacts to signals only.

const INK := Color(1.0, 0.88, 0.5)
const THREAD := Color(0.55, 0.94, 0.84)

var manager: PuzzleManager
var board: PuzzleBoard
var controller: ClusterSurgeController
var fx: BoardFx
var sfx: Sfx
var effects_enabled := DisplayServer.get_name() != "headless"

var preview_piece := -1
var _seams: Array = []
var _clock := 0.0
var _layer: Node2D

func setup(p_manager: PuzzleManager, p_board: PuzzleBoard, p_controller: ClusterSurgeController, p_fx: BoardFx, p_sfx: Sfx) -> void:
	manager = p_manager
	board = p_board
	controller = p_controller
	fx = p_fx
	sfx = p_sfx
	z_index = 45
	_layer = Node2D.new()
	add_child(_layer)
	manager.piece_changed.connect(func(_id): _refresh_preview_soon())
	controller.surge_started.connect(_on_started)
	controller.pull_incoming.connect(_on_pull_incoming)
	controller.pull_landed.connect(_on_pull_landed)

# --- the seam preview ---

# Shows (piece_id >= 0) or clears (-1) the faint glow around that group's pullable seams.
func set_preview(piece_id: int) -> void:
	preview_piece = piece_id
	_refresh_preview()

func _refresh_preview_soon() -> void:
	if preview_piece >= 0:
		call_deferred("_refresh_preview")

func _refresh_preview() -> void:
	_seams = manager.surge_seams(preview_piece) if preview_piece >= 0 else []
	set_process(not _seams.is_empty())
	queue_redraw()

func _process(delta: float) -> void:
	_clock += delta
	queue_redraw()

func _draw() -> void:
	if _seams.is_empty():
		return
	var breath := 0.5 + 0.5 * sin(_clock * 4.0)
	for seam in _seams:
		draw_polyline(seam, Color(THREAD.r, THREAD.g, THREAD.b, 0.14 + 0.1 * breath), 16.0, true)
		draw_polyline(seam, Color(0.82, 1.0, 0.96, 0.55 + 0.25 * breath), 4.0, true)

# --- firing ---

func _on_started(piece_id: int, member_ids: Array) -> void:
	preview_piece = -1
	_seams = []
	set_process(false)
	queue_redraw()
	if not effects_enabled:
		return
	sfx.surge()
	var centre := _centre_of(member_ids)
	fx.ring(centre, 150.0 + 18.0 * sqrt(member_ids.size()), Color(INK.r, INK.g, INK.b, 0.9), 0.55, 7.0)
	for id in member_ids:
		if board.views.has(id):
			board.views[id].pulse(0.1)

func _on_pull_incoming(anchor_id: int, _piece_id: int, member_ids: Array) -> void:
	board.magnet_glide(member_ids)
	if not effects_enabled:
		return
	sfx.magnet_pull()
	var from := _centre_of(member_ids)
	var to := _centre_of([anchor_id])
	var thread := Line2D.new()
	thread.points = PackedVector2Array([from, to])
	thread.width = 5.0
	thread.default_color = Color(THREAD.r, THREAD.g, THREAD.b, 0.85)
	_layer.add_child(thread)
	var tween := create_tween()
	tween.tween_property(thread, "modulate:a", 0.0, controller.pull_delay + 0.25)
	tween.tween_callback(thread.queue_free)

func _on_pull_landed(_anchor_id: int, piece_id: int, moved_ids: Array) -> void:
	if not effects_enabled:
		return
	var spot := _centre_of(moved_ids)
	fx.ring(spot, 70.0, THREAD, 0.4, 5.0)
	fx.sparkles(spot, 14, Color(1.0, 0.97, 0.8), 260.0, 0.6, 6.0)

func _centre_of(ids: Array) -> Vector2:
	var total := Vector2.ZERO
	for id in ids:
		var piece: PuzzlePieceState = manager.pieces[id]
		total += piece.current_position + piece.piece_size * 0.5
	return total / maxf(1.0, ids.size())
