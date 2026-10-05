class_name ClusterSurgeController
extends Node

# Cluster Surge, the player's first spendable power. Spend one Power Charge on any group on the table -- loose or
# part of the main puzzle -- and up to three of its correct neighbours (loose pieces, pieces still in the bank,
# or whole groups) are pulled onto it and snapped. Pieces that join the main puzzle this way can charge board
# zones, so a Surge can start or carry on a chain.
#
# Authority: only the solo player or the host decides. A client asks (NetworkSession.request_surge); the host
# checks the request, spends the shared charge, picks the targets and moves the pieces. Clients are shown the same
# thing and receive the resulting pieces like any other update. PuzzleManager does every move and join.
#
# Drawing is not done here: this emits signals and ClusterSurgeView turns them into effects.

const COST := 1
const MAX_PULLS := 3

# The surge began on the group containing `piece_id`.
signal surge_started(piece_id: int, member_ids: Array)
# A neighbour is about to be pulled onto the group; `member_ids` are the pieces about to move.
signal pull_incoming(anchor_id: int, piece_id: int, member_ids: Array)
# The neighbour (and its group) is in place.
signal pull_landed(anchor_id: int, piece_id: int, moved_ids: Array)

var session: PuzzleSession
var manager: PuzzleManager
var network: NetworkSession
var scoring: RunScoring

var pull_delay := 0.3 # from a pull being announced to its pieces moving
var pull_gap := 0.14
var rng := RandomNumberGenerator.new()

var _generation := 0

func _ready() -> void:
	rng.randomize()

func setup(p_session: PuzzleSession, p_manager: PuzzleManager, p_network: NetworkSession, p_scoring: RunScoring) -> void:
	session = p_session
	manager = p_manager
	network = p_network
	scoring = p_scoring
	session.puzzle_resetting.connect(func(): _generation += 1)
	network.surge_requested.connect(_on_remote_request)
	network.surge_started_received.connect(_on_remote_started)
	network.surge_pull_received.connect(_on_remote_pull)

func make_instant() -> void:
	pull_delay = 0.0
	pull_gap = 0.0

func has_authority() -> bool:
	return not network.is_client()

# Can a Surge be spent on this piece's group right now? (The local check the ability bar uses; the host
# repeats it when it acts.)
func can_use(piece_id: int, requester: int = 0) -> bool:
	var piece := manager.get_piece(piece_id)
	if piece == null or not piece.is_on_table or scoring.ledger(RunScoring.key_for(requester)).power_charges < COST:
		return false
	for member_id in manager.cluster_members(piece_id):
		var owner: int = manager.pieces[member_id].owner_peer_id
		if owner != 0 and owner != requester:
			return false
	return not manager.surge_targets(piece_id).is_empty()

# The ability bar's entry point. Solo and host act at once; a client asks the host.
func request(piece_id: int) -> bool:
	if network.is_client():
		network.request_surge(piece_id)
		return true
	return activate(piece_id, network.local_player_id())

# Spends a charge and starts the surge. False if it is not allowed (nothing is spent then).
func activate(piece_id: int, requester: int = 0) -> bool:
	if not has_authority() or not can_use(piece_id, requester):
		return false
	if not scoring.spend_power_charge(requester):
		return false
	var members := manager.cluster_members(piece_id).duplicate()
	surge_started.emit(piece_id, members)
	network.announce_surge_started(piece_id, members)
	_run(piece_id, _pick_targets(piece_id), requester)
	return true

func _on_remote_request(piece_id: int, peer_id: int) -> void:
	activate(piece_id, peer_id)

# Up to three neighbouring groups, chosen at random from those that could be pulled.
func _pick_targets(piece_id: int) -> Array:
	var options := manager.surge_targets(piece_id)
	for i in range(options.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var swap = options[i]
		options[i] = options[j]
		options[j] = swap
	var targets := []
	for option in options.slice(0, MAX_PULLS):
		targets.append(option.piece)
	return targets

func _run(anchor_id: int, targets: Array, requester: int) -> void:
	var generation := _generation
	for target_id in targets:
		if generation != _generation:
			return
		var target := manager.get_piece(target_id)
		if target == null or target.is_locked or manager.is_power_group_held(target_id):
			continue # it joined the main puzzle meanwhile, or a player picked it up
		if target.is_on_table and target.cluster_id == manager.get_piece(anchor_id).cluster_id:
			continue # an earlier pull already joined it
		var members := manager.cluster_members(target_id).duplicate() if target.is_on_table else [target_id]
		pull_incoming.emit(anchor_id, target_id, members)
		network.announce_surge_pull(anchor_id, target_id, members)
		if pull_delay > 0.0:
			await get_tree().create_timer(pull_delay).timeout
			if generation != _generation:
				return
		var previous_actor := manager.acting_player
		manager.acting_player = requester # the pulled joins build the requesting player's Charge and streak
		var moved := manager.pull_to_group(target_id, anchor_id)
		manager.acting_player = previous_actor
		if not moved.is_empty():
			network.broadcast_power_result(anchor_id)
			pull_landed.emit(anchor_id, target_id, moved)
		if pull_gap > 0.0:
			await get_tree().create_timer(pull_gap).timeout

# --- a client being shown what the host did ---

func _on_remote_started(piece_id: int, member_ids: Array) -> void:
	if network.is_client():
		surge_started.emit(piece_id, member_ids)

func _on_remote_pull(anchor_id: int, piece_id: int, member_ids: Array) -> void:
	if network.is_client() and manager.get_piece(piece_id) != null:
		pull_incoming.emit(anchor_id, piece_id, member_ids)
