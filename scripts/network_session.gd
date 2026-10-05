class_name NetworkSession
extends Node

# Bridges local input and the shared PuzzleManager to an ENet host/client session.
# Every request_* call applies to the local manager immediately (so solo play has
# zero overhead and networked play stays responsive), and additionally notifies the
# host over RPC when running as a client. The host is authoritative: its broadcasts
# reconcile every peer, including the client that originated the change.
#
# Structural actions (pickup/rotate/release/place) are broadcast explicitly right
# after a successful manager call, rather than piggybacking on manager.piece_changed:
# PuzzleManager only emits that signal when a piece's *position* changes, so a plain
# release that doesn't happen to complete a new join emits nothing at all. Without an
# explicit broadcast, other peers would never learn the piece became free again.
# Continuous drag movement is the one case still driven by the signal (via the
# _in_move_broadcast flag), since request_move always emits it for every cluster
# member and that's exactly the per-member granularity an unreliable sync wants.

signal connection_established
signal connection_failed(reason: String)
signal server_disconnected
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal full_state_received(config: Dictionary, snapshots: Array)
# Lightning is decided by the host alone; these tell a client what the host did so it can show the same thing.
signal lightning_activated_received
signal lightning_strike_received(piece_id: int, member_ids: Array)
signal magnet_activated_received
signal magnet_pull_received(piece_id: int, member_ids: Array)
signal scoring_sync_received(state: Dictionary, event: Dictionary)
signal edge_pulse_requested
signal edge_pulse_received(piece_ids: Array)

enum Mode { SOLO, HOST, CLIENT }

const DEFAULT_PORT := 8910
const MAX_CLIENTS := 8

var mode: int = Mode.SOLO
var manager: PuzzleManager
var config_provider: Callable
var _in_move_broadcast := false

func configure(puzzle_manager: PuzzleManager, provider: Callable) -> void:
	manager = puzzle_manager
	config_provider = provider
	manager.piece_changed.connect(_on_manager_piece_changed)
	manager.puzzle_completed.connect(_on_manager_completed)

func is_solo() -> bool:
	return mode == Mode.SOLO

func is_host() -> bool:
	return mode == Mode.HOST

func is_client() -> bool:
	return mode == Mode.CLIENT

func local_player_id() -> int:
	# Solo play uses the manager's unowned player ID. SceneMultiplayer has no peer to query then.
	if is_solo() or multiplayer.multiplayer_peer == null:
		return 0
	return multiplayer.get_unique_id()

func start_host(port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	return OK

func start_client(address: String, port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
		multiplayer.connection_failed.connect(_on_connection_failed)
		multiplayer.server_disconnected.connect(_on_server_disconnected)
	return OK

func stop() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	mode = Mode.SOLO

# Re-sends the full board to every connected peer; used when the host reseeds/resizes
# so existing clients don't silently desync.
func broadcast_full_state() -> void:
	if not is_host():
		return
	var config: Dictionary = config_provider.call()
	var snapshots := _snapshot_all()
	for id in multiplayer.get_peers():
		_full_sync.rpc_id(id, config, snapshots)

func _snapshot_all() -> Array:
	var snapshots := []
	for piece in manager.pieces:
		snapshots.append(piece.snapshot())
	return snapshots

func _broadcast_piece(piece_id: int) -> void:
	var piece := manager.get_piece(piece_id)
	if piece != null:
		_sync_piece.rpc(piece.snapshot())

func _broadcast_cluster(piece_id: int) -> void:
	for member_id in manager.cluster_members(piece_id):
		_broadcast_piece(member_id)

# --- Local input entry points (main.gd calls these instead of manager.request_*) ---

func request_place_from_bank(piece_id: int, position: Vector2) -> bool:
	var applied := manager.request_place_from_bank(piece_id, position, local_player_id())
	if applied and is_host():
		_broadcast_piece(piece_id)
	elif applied and is_client():
		_rpc_request_place_from_bank.rpc_id(1, piece_id, position)
	return applied

func request_pickup(piece_id: int) -> bool:
	var applied := manager.request_pickup(piece_id, local_player_id())
	if applied and is_host():
		_broadcast_cluster(piece_id)
	elif applied and is_client():
		_rpc_request_pickup.rpc_id(1, piece_id)
	return applied

func request_move(piece_id: int, position: Vector2) -> bool:
	_in_move_broadcast = true
	var applied := manager.request_move(piece_id, position)
	_in_move_broadcast = false
	if applied and is_client():
		_rpc_request_move.rpc_id(1, piece_id, position)
	return applied

func request_rotate(piece_id: int) -> bool:
	# Turning a loose piece does not require holding it (double-tap, R and the Rotate button all act on a
	# piece that is merely selected); it is only refused while another player is holding it.
	if not manager.is_free_for(piece_id, local_player_id()):
		return false
	var applied := manager.request_rotate(piece_id)
	if applied and is_host():
		_broadcast_cluster(piece_id)
	elif applied and is_client():
		_rpc_request_rotate.rpc_id(1, piece_id)
	return applied

func request_release(piece_id: int, count_failed_attempt: bool = true) -> bool:
	# manager.request_release()'s return value means "snapped into a neighbor", not
	# "release succeeded" (see PuzzleManager.request_release/snap_piece) -- releasing at
	# a spot with no matching neighbor is the common case and must still be broadcast,
	# or peers never learn ownership was cleared and the piece stays locked.
	var piece := manager.get_piece(piece_id)
	var was_owned := piece != null and piece.is_on_table and piece.owner_peer_id == local_player_id()
	var joined := manager.request_release(piece_id, local_player_id(), count_failed_attempt)
	if was_owned and is_host():
		_broadcast_cluster(piece_id)
	elif was_owned and is_client():
		_rpc_request_release.rpc_id(1, piece_id, count_failed_attempt)
	return joined

func announce_scoring(state: Dictionary, event: Dictionary) -> void:
	if is_host():
		_sync_scoring.rpc(state, event)

func request_edge_pulse() -> void:
	if is_client():
		_rpc_request_edge_pulse.rpc_id(1)

func announce_edge_pulse(piece_ids: Array) -> void:
	if is_host():
		_sync_edge_pulse.rpc(piece_ids)

# --- Lightning (host only; clients just watch) ---

func announce_lightning_activated() -> void:
	if is_host():
		_sync_lightning_activated.rpc()

func announce_lightning_strike(piece_id: int, member_ids: Array) -> void:
	if is_host():
		_sync_lightning_strike.rpc(piece_id, member_ids)

# Sends the final state of the struck group (which by now includes whatever it joined) to every peer.
func broadcast_lightning_result(piece_id: int) -> void:
	broadcast_power_result(piece_id)

func broadcast_power_result(piece_id: int) -> void:
	if is_host():
		_broadcast_cluster(piece_id)

func announce_magnet_activated() -> void:
	if is_host():
		_sync_magnet_activated.rpc()

func announce_magnet_pull(piece_id: int, member_ids: Array) -> void:
	if is_host():
		_sync_magnet_pull.rpc(piece_id, member_ids)

# --- Host-side connection lifecycle ---

func _on_peer_connected(id: int) -> void:
	if not is_host():
		return
	peer_joined.emit(id)
	var config: Dictionary = config_provider.call()
	_full_sync.rpc_id(id, config, _snapshot_all())

func _on_peer_disconnected(id: int) -> void:
	if not is_host():
		return
	manager.release_pieces_owned_by(id)
	peer_left.emit(id)

# --- Client-side connection lifecycle ---

func _on_connected_to_server() -> void:
	connection_established.emit()

func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	mode = Mode.SOLO
	connection_failed.emit("Could not connect to host")

func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	mode = Mode.SOLO
	server_disconnected.emit()

# --- Host: broadcast drag movement as it happens (see file header for why moves
# alone use the signal-driven path) ---

func _on_manager_piece_changed(piece_id: int) -> void:
	if not is_host() or not _in_move_broadcast:
		return
	var piece := manager.get_piece(piece_id)
	if piece != null:
		_sync_move.rpc(piece_id, piece.current_position)

func _on_manager_completed() -> void:
	if is_host():
		_sync_completed.rpc()

# --- RPCs: client -> host requests ---

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_place_from_bank(piece_id: int, position: Vector2) -> void:
	if not is_host():
		return
	if manager.request_place_from_bank(piece_id, position, multiplayer.get_remote_sender_id()):
		_broadcast_piece(piece_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_pickup(piece_id: int) -> void:
	if not is_host():
		return
	if manager.request_pickup(piece_id, multiplayer.get_remote_sender_id()):
		_broadcast_cluster(piece_id)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_request_move(piece_id: int, position: Vector2) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	var piece := manager.get_piece(piece_id)
	if piece == null or piece.owner_peer_id != sender:
		return
	_in_move_broadcast = true
	manager.request_move(piece_id, position)
	_in_move_broadcast = false

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_rotate(piece_id: int) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	var piece := manager.get_piece(piece_id)
	if piece == null:
		return
	# Previously this required the sender to be holding the piece, which a client turning a merely
	# selected piece never is: the host refused, never learned of the turn, and the next pickup
	# broadcast the old rotation back, undoing it. Accept any free (or self-held) piece, and always
	# answer with the authoritative state so a refused turn is corrected on the client too.
	if manager.is_free_for(piece_id, sender):
		manager.request_rotate(piece_id)
	_broadcast_cluster(piece_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_release(piece_id: int, count_failed_attempt: bool = true) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	var piece := manager.get_piece(piece_id)
	var was_owned := piece != null and piece.is_on_table and piece.owner_peer_id == sender
	manager.request_release(piece_id, sender, count_failed_attempt)
	if was_owned:
		_broadcast_cluster(piece_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_edge_pulse() -> void:
	if is_host():
		edge_pulse_requested.emit()

# --- RPCs: host -> peers broadcasts ---

@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_move(piece_id: int, position: Vector2) -> void:
	var piece := manager.get_piece(piece_id)
	if piece == null:
		return
	piece.current_position = position
	manager.piece_changed.emit(piece_id)

@rpc("authority", "call_remote", "reliable")
func _sync_piece(snapshot: Dictionary) -> void:
	var piece := manager.get_piece(int(snapshot.piece_id))
	if piece == null:
		return
	piece.apply_snapshot(snapshot)
	manager.rebuild_clusters()
	manager.piece_changed.emit(piece.piece_id)
	manager.bank_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _sync_completed() -> void:
	manager.completion_announced = true
	manager.puzzle_completed.emit()

@rpc("authority", "call_remote", "reliable")
func _sync_lightning_activated() -> void:
	lightning_activated_received.emit()

@rpc("authority", "call_remote", "reliable")
func _sync_lightning_strike(piece_id: int, member_ids: Array) -> void:
	lightning_strike_received.emit(piece_id, member_ids)

@rpc("authority", "call_remote", "reliable")
func _sync_magnet_activated() -> void:
	magnet_activated_received.emit()

@rpc("authority", "call_remote", "reliable")
func _sync_magnet_pull(piece_id: int, member_ids: Array) -> void:
	magnet_pull_received.emit(piece_id, member_ids)

@rpc("authority", "call_remote", "reliable")
func _sync_scoring(state: Dictionary, event: Dictionary) -> void:
	scoring_sync_received.emit(state, event)

@rpc("authority", "call_remote", "reliable")
func _sync_edge_pulse(piece_ids: Array) -> void:
	edge_pulse_received.emit(piece_ids)

@rpc("authority", "call_remote", "reliable")
func _full_sync(config: Dictionary, snapshots: Array) -> void:
	full_state_received.emit(config, snapshots)
