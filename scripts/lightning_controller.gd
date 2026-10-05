class_name LightningController
extends Node

# Runs the Lightning Zone: notices when it has been charged, activates it exactly once, and then strikes
# `zone.strikes` unfinished places in turn, each time bringing the piece (or whole joined group) that belongs
# there to its true spot. The puzzle itself is changed only through PuzzleManager.
#
# Authority: only the solo player or the host decides anything. A client never checks the zone, never
# picks a target and never moves a piece; it is told what happened (see NetworkSession's lightning
# signals) and receives the resulting pieces like any other update.
#
# Drawing is not done here: this emits signals and LightningView turns them into effects.

# The zone was charged and has been switched on (also emitted on a client when the host announces it).
signal activated
# Lightning is about to hit the place where `piece_id` belongs; `member_ids` are the pieces about to move.
signal strike_incoming(piece_id: int, member_ids: Array, target_rect: Rect2)
# The struck pieces have been put in place.
signal strike_landed(piece_id: int, moved_ids: Array)

var session: PuzzleSession
var manager: PuzzleManager
var network: NetworkSession

var charge_delay := 1.1 # from the last piece joining to the first strike
var strike_delay := 0.55 # from a strike being announced to its piece moving
var strike_gap := 0.85 # after a piece has moved, before the next strike
var rng := RandomNumberGenerator.new()

var _generation := 0 # bumped whenever the puzzle changes so a sequence in progress stops

func _ready() -> void:
	rng.randomize()

func setup(p_session: PuzzleSession, p_manager: PuzzleManager, p_network: NetworkSession) -> void:
	session = p_session
	manager = p_manager
	network = p_network
	manager.group_locked.connect(_on_group_locked)
	session.puzzle_resetting.connect(func(): _generation += 1)
	network.lightning_activated_received.connect(_on_remote_activated)
	network.lightning_strike_received.connect(_on_remote_strike)

func zone() -> LightningZone:
	return session.lightning_zone

# Only the solo player or the host may decide anything about lightning.
func has_authority() -> bool:
	return not network.is_client()

# --- charging ---

func _on_group_locked(_cluster_id: int, _member_ids: Array, _side_names: Array) -> void:
	if not session.restoring:
		check_charge()

# Activates the zone if it has just been completed. Returns true if it did.
func check_charge() -> bool:
	var current := zone()
	if current == null or current.activated or not has_authority():
		return false
	if not current.is_charged(manager):
		return false
	activate()
	return true

# Switches the zone on. It is marked used at once (and the puzzle marked for saving), so reloading a save made
# at any later moment can never charge it a second time. Strikes then follow one by one.
func activate() -> bool:
	var current := zone()
	if current == null or current.activated or not has_authority():
		return false
	current.activated = true
	session.mark_dirty()
	network.announce_lightning_activated()
	activated.emit()
	_run_strikes(current)
	return true

# --- striking ---

func _run_strikes(current: LightningZone) -> void:
	var generation := _generation
	if charge_delay > 0.0:
		await get_tree().create_timer(charge_delay).timeout
	for i in range(current.strikes):
		if generation != _generation or manager.completion_announced:
			return
		var target := pick_target()
		if target < 0:
			return
		var members := _group_of(target)
		strike_incoming.emit(target, members, piece_rect(target))
		network.announce_lightning_strike(target, members)
		if strike_delay > 0.0:
			await get_tree().create_timer(strike_delay).timeout
			if generation != _generation:
				return
		apply_strike(target)
		if strike_gap > 0.0:
			await get_tree().create_timer(strike_gap).timeout

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

# Puts the struck piece's whole group in place and tells every peer. Returns the ids of the pieces moved.
func apply_strike(piece_id: int) -> Array:
	if not has_authority():
		return []
	var moved := manager.strike_piece(piece_id)
	if moved.is_empty():
		return moved
	network.broadcast_lightning_result(piece_id)
	strike_landed.emit(piece_id, moved)
	return moved

# --- a client being told what the host did ---

func _on_remote_activated() -> void:
	var current := zone()
	if current == null or not network.is_client():
		return
	current.activated = true
	activated.emit()

func _on_remote_strike(piece_id: int, member_ids: Array) -> void:
	if network.is_client() and manager.get_piece(piece_id) != null:
		strike_incoming.emit(piece_id, member_ids, piece_rect(piece_id))

# --- helpers ---

func _group_of(piece_id: int) -> Array:
	var members := manager.cluster_members(piece_id)
	return members.duplicate() if not members.is_empty() else [piece_id]

# Where the piece belongs on the board, in board coordinates.
func piece_rect(piece_id: int) -> Rect2:
	var piece := manager.get_piece(piece_id)
	return Rect2(piece.correct_position, piece.piece_size)
