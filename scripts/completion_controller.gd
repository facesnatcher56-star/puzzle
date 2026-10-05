class_name CompletionController
extends Node

# Everything that celebrates and records progress: snap feedback that scales with the size of the group
# just formed, the lock-to-board clunk, and the finish -- the finale animation, the "puzzle complete"
# banner and the Collection entry. It also watches a client's updates so players who join a game get the
# same feedback as the host, since only the host runs the snapping code.

var manager: PuzzleManager
var session: PuzzleSession
var board: PuzzleBoard
var network: NetworkSession
var camera: Camera2D
var sfx: Sfx
var fx: BoardFx
var bank: PieceBank
var banner: Control
var banner_label: Label
var set_board_glow: Callable # (value: float) -> void, tweened during the finale
var fx_enabled := DisplayServer.get_name() != "headless"

var _join_happened := false # set when a join happened during the current drop
var _drop_piece_id := -1
var _drop_msec := -100000
var _known_cluster := {} # piece id -> cluster size last seen (client-side join detection)
var _known_locked := {}
var _client_join_timer: Timer
var _client_join_piece := -1
var _client_lock_timer: Timer
var _client_lock_piece := -1

func _ready() -> void:
	_client_join_timer = Timer.new()
	_client_join_timer.one_shot = true
	_client_join_timer.wait_time = 0.12
	_client_join_timer.timeout.connect(_on_client_join_timeout)
	add_child(_client_join_timer)
	_client_lock_timer = Timer.new()
	_client_lock_timer.one_shot = true
	_client_lock_timer.wait_time = 0.15
	_client_lock_timer.timeout.connect(_on_client_lock_timeout)
	add_child(_client_lock_timer)

# --- bookkeeping driven by the session ---

# A new or restored puzzle replaced the old one.
func reset() -> void:
	_known_cluster.clear()
	_known_locked.clear()

# After a restore, remember group sizes so only later growth counts as a join.
func remember_cluster_sizes() -> void:
	_known_cluster.clear()
	for piece in manager.pieces:
		_known_cluster[piece.piece_id] = manager.cluster_members(piece.piece_id).size()

# --- drops: the input controller brackets each release so the sound can tell a snap from a plain drop ---

func begin_drop(piece_id: int) -> void:
	_join_happened = false
	_drop_piece_id = piece_id
	_drop_msec = Time.get_ticks_msec()

func end_drop() -> void:
	if not _join_happened:
		sfx.drop()

# --- manager events ---

func on_pieces_joined(_cluster_id: int, member_ids: Array) -> void:
	_join_happened = true
	if session.restoring:
		return
	# A client can see its own predicted join through both this signal and the
	# piece-change fallback. Keep the fallback for joins made by other players.
	if network.is_client() and _client_join_timer != null and member_ids.has(_client_join_piece):
		_client_join_timer.stop()
	var origin := Vector2.ZERO
	if _drop_piece_id >= 0 and Time.get_ticks_msec() - _drop_msec < 600 and _drop_piece_id < manager.pieces.size():
		origin = _piece_centre(manager.pieces[_drop_piece_id])
	else:
		origin = _centre_of(member_ids)
	_celebrate_join(member_ids, origin)
	# Scoring supplies one authoritative sound for both loose and anchored joins.

func on_scoring_awarded(event: Dictionary) -> void:
	_join_happened = true
	sfx.reward_snap(int(event.combo_after), int(event.piece_count), int(event.source) == PuzzleManager.ConnectionSource.POWER)

func on_scoring_tier_rose(_tier: int) -> void:
	sfx.combo_up()

func on_group_locked(_cluster_id: int, member_ids: Array, _side_names: Array) -> void:
	if session.restoring:
		return
	_celebrate_lock(member_ids)

# Clients never run the snapping code, they only receive piece updates. Notice a group growing or locking
# and play the same feedback once the burst of updates has settled.
func on_piece_changed(piece_id: int) -> void:
	var piece := manager.get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return
	var size := manager.cluster_members(piece_id).size()
	if not session.restoring and network.is_client() and size >= 2 and size > int(_known_cluster.get(piece_id, 1)):
		_client_join_piece = piece_id
		_client_join_timer.start()
	_known_cluster[piece_id] = size
	var now_locked := piece.is_locked
	if now_locked and not bool(_known_locked.get(piece_id, false)) and not session.restoring and network.is_client():
		_client_lock_piece = piece_id
		_client_lock_timer.start()
	_known_locked[piece_id] = now_locked

func _on_client_join_timeout() -> void:
	if _client_join_piece < 0 or not network.is_client():
		return
	var members := manager.cluster_members(_client_join_piece)
	if members.size() < 2:
		return
	_celebrate_join(members, _centre_of(members))

func _on_client_lock_timeout() -> void:
	if _client_lock_piece < 0 or not network.is_client():
		return
	var members := manager.cluster_members(_client_lock_piece)
	if not members.is_empty():
		_celebrate_lock(members)

# --- snap and lock feedback ---

# A tick and a ring for small joins, a wave rippling through the group for medium ones, and a shockwave
# with sparkles and a shake for big ones.
func _celebrate_join(member_ids: Array, origin: Vector2) -> void:
	var size := member_ids.size()
	var total := manager.pieces.size()
	var level := 0
	if size >= 8:
		level = 1
	if size >= 30:
		level = 2
	if size >= maxi(50, total / 2):
		level = 3
	_vibrate([25, 45, 80, 140][level])
	if not fx_enabled:
		return
	var gold := Color(1.0, 0.9, 0.6, 0.9)
	fx.ring(origin, [60.0, 130.0, 230.0, 380.0][level], gold, 0.45 + 0.1 * level, 4.0 + level * 2.0)
	if level >= 2:
		fx.ring(origin, [0.0, 0.0, 130.0, 240.0][level], Color(1, 1, 1, 0.7), 0.6, 3.0)
	for member_id in member_ids:
		if not board.views.has(member_id):
			continue
		var view: PuzzlePieceView = board.views[member_id]
		var delay := 0.0
		if level >= 1:
			delay = clampf(_piece_centre(manager.pieces[member_id]).distance_to(origin) / 2600.0, 0.0, 0.55)
		view.pulse([0.05, 0.06, 0.075, 0.09][level], delay)
		view.modulate = Color(1.18, 1.10, 0.85)
		create_tween().tween_property(view, "modulate", Color.WHITE, 0.3)
	if level >= 1:
		fx.sparkles(origin, [0, 12, 28, 55][level], Color(1.0, 0.92, 0.65, 1.0), [0.0, 220.0, 320.0, 420.0][level])
	if level >= 2:
		_shake_camera([0.0, 0.0, 3.0, 6.0][level], 0.28)

# The group has just been bolted to the board: a clunk, a gold ring from its middle and a short shake.
func _celebrate_lock(member_ids: Array) -> void:
	_vibrate(120)
	if not fx_enabled:
		return
	var centre := _centre_of(member_ids)
	fx.ring(centre, 260.0, Color(1.0, 0.82, 0.4, 0.95), 0.6, 9.0)
	fx.sparkles(centre, 26, Color(1.0, 0.88, 0.5, 1.0), 300.0)
	for member_id in member_ids:
		if board.views.has(member_id):
			var view: PuzzlePieceView = board.views[member_id]
			var distance := _piece_centre(manager.pieces[member_id]).distance_to(centre)
			view.pulse(0.045, clampf(distance / 3200.0, 0.0, 0.4))
			view.modulate = Color(1.3, 1.18, 0.85)
			create_tween().tween_property(view, "modulate", Color.WHITE, 0.45)
	_shake_camera(3.0, 0.2)

func _shake_camera(strength: float, duration: float) -> void:
	var tween := create_tween()
	tween.tween_method(func(t: float): camera.offset = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * strength * (1.0 - t), 0.0, 1.0, duration)
	tween.tween_callback(func(): camera.offset = Vector2.ZERO)

func _vibrate(milliseconds: int) -> void:
	if DisplaySettings.vibration_enabled and OS.has_feature("mobile"):
		Input.vibrate_handheld(milliseconds)

# --- the finish ---

func on_completed() -> void:
	board.select(-1)
	if not bank.collapsed:
		bank.toggle_collapsed()
	var seconds := manager.elapsed_seconds()
	banner_label.text = "Puzzle Complete  •  %s  •  saved to your Collection" % SaveFormat.format_time(seconds * 1000)
	_record_completion()
	sfx.complete()
	_vibrate(250)
	if not fx_enabled:
		banner.visible = true
		return
	_play_finale()
	banner.visible = false
	banner.modulate.a = 0.0
	var reveal := create_tween()
	reveal.tween_interval(2.2)
	reveal.tween_callback(func(): banner.visible = true)
	reveal.tween_property(banner, "modulate:a", 1.0, 0.6)

# Moves the finished puzzle out of the saved-games list and into the Collection with its stats.
func _record_completion() -> void:
	var config := session.puzzle_config()
	Collection.add(Collection.entry_from(config, session.entry_id(), int(config.elapsed_ms), int(Time.get_unix_time_from_system()), network.is_host() or network.is_client()))
	session.retire_save_slot()

# The big finish: the camera pulls back to the whole picture, a wave of pops ripples out from the
# last piece, a golden light sweeps across, fireworks burst over the board and its frame glows.
func _play_finale() -> void:
	var board_size := session.board_size
	var tween := create_tween().set_parallel(true)
	var viewport_size := get_viewport().get_visible_rect().size
	var available := Vector2(viewport_size.x - 64, viewport_size.y - 50 - 85)
	var fit := minf(available.x / board_size.x, available.y / board_size.y)
	tween.tween_property(camera, "zoom", Vector2.ONE * fit, 0.9).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(camera, "position", Vector2(0, (50 - 53) * 0.5 / fit), 0.9).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	var origin := Vector2.ZERO
	if _drop_piece_id >= 0 and _drop_piece_id < manager.pieces.size():
		origin = _piece_centre(manager.pieces[_drop_piece_id])
	var half_width := board_size.x * 0.5
	for piece_id in board.views:
		var view: PuzzlePieceView = board.views[piece_id]
		var centre := _piece_centre(manager.pieces[piece_id])
		var wave_delay := clampf(centre.distance_to(origin) / board_size.length() * 1.3, 0.0, 1.3)
		view.pulse(0.07, wave_delay)
		# golden sweep, left to right, after the wave
		var sweep_delay := 1.1 + (centre.x + half_width) / board_size.x * 0.9
		var flash := create_tween()
		flash.tween_interval(sweep_delay)
		flash.tween_property(view, "modulate", Color(1.55, 1.4, 1.05), 0.16)
		flash.tween_property(view, "modulate", Color.WHITE, 0.5)
	var glow := create_tween()
	glow.tween_interval(0.8)
	glow.tween_method(set_board_glow, 0.0, 1.0, 0.7)
	glow.tween_method(set_board_glow, 1.0, 0.35, 1.5)
	for ring_index in range(3):
		var ring_tween := create_tween()
		ring_tween.tween_interval(0.25 + ring_index * 0.35)
		ring_tween.tween_callback(func(): fx.ring(origin, 500.0 + ring_index * 450.0, Color(1.0, 0.9, 0.6, 0.9), 1.1, 8.0))
	var burst_colors := [Color(1.0, 0.9, 0.55), Color(1.0, 1.0, 1.0), Color(1.0, 0.7, 0.45), Color(0.7, 0.9, 1.0)]
	for i in range(12):
		var burst := create_tween()
		burst.tween_interval(1.0 + i * 0.16)
		var spot := Vector2(randf_range(-0.42, 0.42) * board_size.x, randf_range(-0.4, 0.4) * board_size.y)
		var colour: Color = burst_colors[i % burst_colors.size()]
		burst.tween_callback(func(): fx.sparkles(spot, 38, colour, 520.0, 1.3, 11.0))
	_shake_camera(5.0, 0.35)

# --- helpers ---

func _piece_centre(piece: PuzzlePieceState) -> Vector2:
	return piece.current_position + piece.piece_size * 0.5

func _centre_of(member_ids: Array) -> Vector2:
	var total := Vector2.ZERO
	for member_id in member_ids:
		total += _piece_centre(manager.pieces[member_id])
	return total / maxf(1.0, member_ids.size())
