class_name PowerController
extends Node

# Runs every board-power zone. When a zone's cells all belong to the main puzzle it is charged; it joins a queue
# and takes its turn, one zone at a time:
#   LIGHTNING  strikes `zone.strike_count()` unfinished places in turn (more for bigger zones),
#   MAGNET     pulls into place the pieces for every cell touching the zone's edge.
# Either way the piece (or whole joined group) that belongs at a target is brought to its true spot and joined
# to the main puzzle, which can charge further zones -- they queue up behind and the chain carries on.
# The puzzle itself is changed only through PuzzleManager.
#
# Authority: only the solo player or the host decides anything. A client never checks a zone, never picks a
# target and never moves a piece; it is told what happened (see NetworkSession's zone signals) and receives the
# resulting pieces like any other update.
#
# A zone is marked used (QUEUED) the moment it is charged, and saved that way, so reloading can never charge it
# a second time; if the game is closed while it waits its turn, loading finishes the job.
#
# Drawing is not done here: this emits signals and PowerView turns them into effects.

# A zone has begun its effect (also emitted on a client when the host announces it).
signal zone_activated(zone_index: int)
# A zone's state changed (charged, started, finished); the markings should be redrawn.
signal zones_changed
# The place where `piece_id` belongs is about to be hit; `member_ids` are the pieces about to move.
signal strike_incoming(zone_index: int, piece_id: int, member_ids: Array, target_rect: Rect2)
# The struck pieces have been put in place (zone_index is -1 for a strike made directly, without a zone).
signal strike_landed(zone_index: int, piece_id: int, moved_ids: Array)

var session: PuzzleSession
var manager: PuzzleManager
var network: NetworkSession

var charge_delay := 0.7 # Lightning: from being charged to the first strike
var strike_delay := 0.45 # Lightning: from a strike being announced to its piece moving
var strike_gap := 0.5 # Lightning: after a piece has moved, before the next strike
var magnet_charge_delay := 0.3
var pull_delay := 0.28 # Magnet: from a pull being announced to its piece moving
var pull_gap := 0.12
var rng := RandomNumberGenerator.new()

var _owners := {} # zone -> the player whose action charged it: its strikes and pulls build that player's Charge
var _queue: Array = [] # charged zones waiting their turn
var _running := false # a queue is being worked through
var _generation := 0 # bumped whenever the puzzle changes so a sequence in progress stops

func _ready() -> void:
	rng.randomize()

func setup(p_session: PuzzleSession, p_manager: PuzzleManager, p_network: NetworkSession) -> void:
	session = p_session
	manager = p_manager
	network = p_network
	manager.group_locked.connect(_on_group_locked)
	session.puzzle_resetting.connect(_on_puzzle_resetting)
	session.puzzle_restored.connect(func(_pieces): resume_pending())
	network.zone_activated_received.connect(_on_remote_activated)
	network.zone_strike_received.connect(_on_remote_strike)

# Removes every delay, so a whole chain plays out at once (tests).
func make_instant() -> void:
	charge_delay = 0.0
	strike_delay = 0.0
	strike_gap = 0.0
	magnet_charge_delay = 0.0
	pull_delay = 0.0
	pull_gap = 0.0

func zones() -> Array:
	return session.power_zones

# Only the solo player or the host may decide anything about the zones.
func has_authority() -> bool:
	return not network.is_client()

func _on_puzzle_resetting() -> void:
	_generation += 1
	_owners.clear()
	_queue.clear()
	_running = false

# --- charging ---

func _on_group_locked(_cluster_id: int, _member_ids: Array, _side_names: Array) -> void:
	if not session.restoring:
		check_charge()

# Queues every zone that has just been completed. Returns how many it queued.
func check_charge() -> int:
	if not has_authority():
		return 0
	var queued := 0
	for zone in zones():
		if zone.state == PowerZone.State.IDLE and zone.is_charged(manager):
			_enqueue(zone)
			queued += 1
	if queued > 0:
		_drain()
	return queued

# Queues one zone whether or not it is charged (the caller decides). False if it was already used.
func activate(zone: PowerZone) -> bool:
	if zone == null or zone.state != PowerZone.State.IDLE or not has_authority():
		return false
	_enqueue(zone)
	_drain()
	return true

# After loading a save: zones that were charged but had not finished get their turn now.
func resume_pending() -> void:
	if not has_authority():
		return
	for zone in zones():
		if zone.state == PowerZone.State.QUEUED and not _queue.has(zone):
			_queue.append(zone)
	if not _queue.is_empty():
		_drain()

func _enqueue(zone: PowerZone) -> void:
	_owners[zone] = manager.acting_player # whoever's action (or chain) charged it
	zone.state = PowerZone.State.QUEUED
	_queue.append(zone)
	session.mark_dirty()
	zones_changed.emit()

# --- taking turns ---

func _drain() -> void:
	if _running:
		return # the running loop will reach the new zone
	_running = true
	var generation := _generation
	while not _queue.is_empty() and generation == _generation:
		var zone: PowerZone = _queue.pop_front()
		await _play(zone, generation)
	if generation == _generation:
		_running = false

func _play(zone: PowerZone, generation: int) -> void:
	var index := zones().find(zone)
	if index < 0:
		return
	network.announce_zone_activated(index)
	zone_activated.emit(index)
	if zone.kind == PowerZone.Kind.LIGHTNING:
		await _run_lightning(zone, index, generation)
	else:
		await _run_magnet(zone, index, generation)
	if generation != _generation:
		return
	zone.state = PowerZone.State.DONE
	session.mark_dirty()
	zones_changed.emit()

func _run_lightning(zone: PowerZone, index: int, generation: int) -> void:
	await _wait(charge_delay)
	for i in range(zone.strike_count()):
		if generation != _generation or manager.completion_announced:
			return
		var target := pick_target()
		if target < 0:
			return
		var members := _group_of(target)
		strike_incoming.emit(index, target, members, piece_rect(target))
		network.announce_zone_strike(index, target, members)
		await _wait(strike_delay)
		if generation != _generation:
			return
		apply_strike(target, index)
		await _wait(strike_gap)

func _run_magnet(zone: PowerZone, index: int, generation: int) -> void:
	var targets := capture_targets(zone) # captured before anything moves, so what is pulled in does not extend the reach
	await _wait(magnet_charge_delay)
	for id in targets:
		if generation != _generation or manager.completion_announced:
			return
		var piece := manager.get_piece(id)
		if piece == null or piece.is_locked or manager.is_power_group_held(id):
			continue # already in the main puzzle by now, or a player picked it up during the short animation
		var members := _group_of(id)
		strike_incoming.emit(index, id, members, piece_rect(id))
		network.announce_zone_strike(index, id, members)
		await _wait(pull_delay)
		if generation != _generation:
			return
		apply_strike(id, index)
		await _wait(pull_gap)

# Time passes more quickly the longer the queue, so a long chain stays lively instead of dragging on.
func _wait(seconds: float) -> void:
	var scaled := seconds * clampf(1.0 / (1.0 + 0.1 * _queue.size()), 0.4, 1.0)
	if scaled > 0.0:
		await get_tree().create_timer(scaled).timeout

# --- choosing and applying ---

# A random place that still needs filling: where some piece outside the main puzzle belongs (see
# PuzzleManager.lightning_targets). Returns that piece's id, or -1 if there is nothing to strike or this
# is a client, which never chooses.
func pick_target() -> int:
	if not has_authority():
		return -1
	var targets := manager.lightning_targets()
	if targets.is_empty():
		return -1
	return targets[rng.randi_range(0, targets.size() - 1)]

# The groups a Magnet will pull: one piece per group touching the zone's edge, skipping pieces already in the
# main puzzle and groups a player is holding.
func capture_targets(zone: PowerZone) -> Array:
	if not has_authority():
		return []
	var targets := []
	var seen := {}
	for id in zone.perimeter_ids():
		var piece := manager.get_piece(id)
		if piece == null or piece.is_locked or manager.is_power_group_held(id):
			continue
		var key := manager.power_group_key(id)
		if not seen.has(key):
			seen[key] = true
			targets.append(id)
	return targets

# Puts the target's whole group in place and tells every peer. Returns the ids of the pieces moved.
func apply_strike(piece_id: int, zone_index: int = -1) -> Array:
	if not has_authority():
		return []
	var piece := manager.get_piece(piece_id)
	if piece == null or piece.is_locked or manager.is_power_group_held(piece_id):
		return []
	var previous_actor := manager.acting_player
	if zone_index >= 0 and zone_index < zones().size():
		manager.acting_player = int(_owners.get(zones()[zone_index], previous_actor))
	var moved := manager.strike_piece(piece_id)
	manager.acting_player = previous_actor
	if moved.is_empty():
		return moved
	network.broadcast_power_result(piece_id)
	strike_landed.emit(zone_index, piece_id, moved)
	return moved

# --- a client being told what the host did ---

func _on_remote_activated(zone_index: int) -> void:
	if not network.is_client() or zone_index < 0 or zone_index >= zones().size():
		return
	zones()[zone_index].state = PowerZone.State.DONE
	zones_changed.emit()
	zone_activated.emit(zone_index)

func _on_remote_strike(zone_index: int, piece_id: int, member_ids: Array) -> void:
	if network.is_client() and manager.get_piece(piece_id) != null and zone_index >= 0 and zone_index < zones().size():
		strike_incoming.emit(zone_index, piece_id, member_ids, piece_rect(piece_id))

# --- helpers ---

func _group_of(piece_id: int) -> Array:
	var piece := manager.get_piece(piece_id)
	var members := manager.cluster_members(piece_id) if piece.is_on_table else []
	return members.duplicate() if not members.is_empty() else [piece_id]

# Where the piece belongs on the board, in board coordinates.
func piece_rect(piece_id: int) -> Rect2:
	var piece := manager.get_piece(piece_id)
	return Rect2(piece.correct_position, piece.piece_size)
