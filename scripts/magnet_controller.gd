class_name MagnetController
extends Node

# Host-owned activation and fixed perimeter target sequence. PuzzleManager performs every move and join.
signal activated
signal pull_incoming(piece_id: int, member_ids: Array, target_rect: Rect2)
signal pull_landed(piece_id: int, moved_ids: Array)

var session: PuzzleSession
var manager: PuzzleManager
var network: NetworkSession
var charge_delay := 0.35
var pull_delay := 0.35
var pull_gap := 0.18
var _generation := 0

func setup(p_session: PuzzleSession, p_manager: PuzzleManager, p_network: NetworkSession) -> void:
	session = p_session
	manager = p_manager
	network = p_network
	manager.group_locked.connect(_on_group_locked)
	session.puzzle_resetting.connect(func(): _generation += 1)
	network.magnet_activated_received.connect(_on_remote_activated)
	network.magnet_pull_received.connect(_on_remote_pull)

func zone() -> MagnetZone:
	return session.magnet_zone

func has_authority() -> bool:
	return not network.is_client()

func _on_group_locked(_cluster_id: int, _member_ids: Array, _side_names: Array) -> void:
	if not session.restoring:
		check_charge()

func check_charge() -> bool:
	var current := zone()
	if current == null or current.activated or not has_authority() or not current.is_charged(manager):
		return false
	return activate()

func capture_targets() -> Array:
	if not has_authority() or zone() == null:
		return []
	var targets := []
	var seen := {}
	for id in zone().perimeter_ids():
		var piece := manager.get_piece(id)
		if piece == null or piece.is_locked or manager.is_power_group_held(id):
			continue
		var key := manager.power_group_key(id)
		if not seen.has(key):
			seen[key] = true
			targets.append(id)
	return targets

func activate() -> bool:
	var current := zone()
	if current == null or current.activated or not has_authority() or not current.is_charged(manager):
		return false
	current.activated = true
	var targets := capture_targets() # captured before any target is moved
	session.mark_dirty()
	network.announce_magnet_activated()
	activated.emit()
	_run_pulls(targets)
	return true

func _run_pulls(targets: Array) -> void:
	var generation := _generation
	if charge_delay > 0.0:
		await get_tree().create_timer(charge_delay).timeout
	for id in targets:
		if generation != _generation:
			return
		var piece := manager.get_piece(id)
		if piece == null or piece.is_locked or manager.is_power_group_held(id):
			continue # a player may have picked it up during the short animation
		var members := manager.cluster_members(id).duplicate() if piece.is_on_table else [id]
		pull_incoming.emit(id, members, piece_rect(id))
		network.announce_magnet_pull(id, members)
		if pull_delay > 0.0:
			await get_tree().create_timer(pull_delay).timeout
			if generation != _generation:
				return
		apply_pull(id)
		if pull_gap > 0.0:
			await get_tree().create_timer(pull_gap).timeout

func apply_pull(piece_id: int) -> Array:
	if not has_authority():
		return []
	var piece := manager.get_piece(piece_id)
	if piece == null or piece.is_locked or manager.is_power_group_held(piece_id):
		return []
	var moved := manager.strike_piece(piece_id)
	if not moved.is_empty():
		network.broadcast_power_result(piece_id)
		pull_landed.emit(piece_id, moved)
	return moved

func _on_remote_activated() -> void:
	var current := zone()
	if current == null or not network.is_client() or current.activated:
		return
	current.activated = true
	activated.emit()

func _on_remote_pull(piece_id: int, member_ids: Array) -> void:
	if network.is_client() and manager.get_piece(piece_id) != null:
		pull_incoming.emit(piece_id, member_ids, piece_rect(piece_id))

func piece_rect(piece_id: int) -> Rect2:
	var piece := manager.get_piece(piece_id)
	return Rect2(piece.correct_position, piece.piece_size)
