extends SceneTree

# A host and a client in one process over 127.0.0.1 (same technique as tests/networking.gd). The client asks for a
# Cluster Surge; only the host spends the shared Power Charge, picks the three neighbours and moves them. The client
# must be shown the same pulls in the same order, end with exactly the host's pieces and charge, and be unable to
# do any of it itself.

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("CLUSTER SURGE NETWORK TEST FAILED: " + message)

func _wait_until(predicate: Callable, seconds: float, message: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	_check(false, "%s (timed out after %.0fs)" % [message, seconds])
	return false

func _snapshots(m: PuzzleManager) -> Array:
	var all := []
	for piece in m.pieces:
		var snap := piece.snapshot()
		snap.owner_peer_id = 0
		all.append(snap)
	return all

# Ids of the pieces whose state differs. Positions may differ by float noise (a joined group is realigned on
# load), so they are compared with a tolerance.
func _differences(a: PuzzleManager, b: PuzzleManager) -> Array:
	var result := []
	for i in range(a.pieces.size()):
		var x := a.pieces[i].snapshot()
		var y := b.pieces[i].snapshot()
		var same_position := Vector2(x.position[0], x.position[1]).distance_to(Vector2(y.position[0], y.position[1])) < 0.01
		x.position = y.position
		x.owner_peer_id = 0
		y.owner_peer_id = 0
		if not same_position or x != y:
			result.append(i)
	return result

func _place(m: PuzzleManager, ids: Array, offset: Vector2) -> void:
	for id in ids:
		m.request_place_from_bank(id, m.pieces[id].correct_position + offset)
	for id in ids:
		m.request_pickup(id)
		m.request_release(id)

func _run() -> void:
	var port := 39225
	var host_root := Node.new()
	root.add_child(host_root)
	set_multiplayer(SceneMultiplayer.new(), host_root.get_path())
	var host_manager := PuzzleManager.new()
	var host_network := NetworkSession.new()
	host_network.name = "Session" # the same node name on both peers, or RPC paths do not match
	host_root.add_child(host_network)
	var host_session := PuzzleSession.new()
	host_session.setup(host_manager, host_network)
	host_root.add_child(host_session)
	host_network.configure(host_manager, Callable(host_session, "puzzle_config"))
	host_session.random_rotation = false
	host_session.size_index = 1 # 6 columns x 8 rows on the classic picture
	host_session.start_puzzle(false)
	host_session.power_zones = []
	var host_surge := ClusterSurgeController.new()
	host_root.add_child(host_surge)
	host_surge.setup(host_session, host_manager, host_network, host_session.scoring)
	host_surge.pull_delay = 0.05
	host_surge.pull_gap = 0.05
	host_surge.rng.seed = 5
	# One loose piece in the middle of the table; its four neighbours are in the bank. The host holds one charge.
	_place(host_manager, [14], Vector2(900, 500))
	host_session.scoring.from_dict({"power_charges": 1, "revision": 1})

	var client_root := Node.new()
	root.add_child(client_root)
	set_multiplayer(SceneMultiplayer.new(), client_root.get_path())
	var client_manager := PuzzleManager.new()
	var client_network := NetworkSession.new()
	client_network.name = "Session"
	client_root.add_child(client_network)
	var client_session := PuzzleSession.new()
	client_session.setup(client_manager, client_network)
	client_root.add_child(client_session)
	client_network.configure(client_manager, func(): return {})
	var client_surge := ClusterSurgeController.new()
	client_root.add_child(client_surge)
	client_surge.setup(client_session, client_manager, client_network, client_session.scoring)
	client_surge.rng.seed = 999 # a different generator: if the client chose anything, it would differ
	var synced := [false]
	client_network.full_state_received.connect(func(config: Dictionary, snapshots: Array):
		client_session.restore_from_host(config, snapshots)
		synced[0] = true)

	_check(host_network.start_host(port) == OK, "host starts listening")
	await process_frame
	_check(client_network.start_client("127.0.0.1", port) == OK, "client starts connecting")
	if not await _wait_until(func(): return synced[0], 6.0, "client receives the host's puzzle"):
		quit(1)
		return
	_check(_differences(client_manager, host_manager).is_empty(), "the client starts with the host's pieces")
	# the shared charge arrives with the first scoring sync; give the host's state to the client
	host_network.announce_scoring(host_session.scoring.to_dict(), {})
	await _wait_until(func(): return client_session.scoring.power_charges == 1, 6.0, "the client sees the shared Power Charge")

	var host_pulls := []
	var client_pulls := []
	var host_landed := []
	host_surge.pull_incoming.connect(func(anchor: int, id: int, members: Array): host_pulls.append([anchor, id, members]))
	client_surge.pull_incoming.connect(func(anchor: int, id: int, members: Array): client_pulls.append([anchor, id, members]))
	host_surge.pull_landed.connect(func(anchor: int, id: int, moved: Array): host_landed.append(id))
	var client_started := []
	client_surge.surge_started.connect(func(id: int, members: Array): client_started.append(id))

	_check(client_surge.can_use(14, client_network.local_player_id()), "the client sees that a Surge is possible")
	_check(client_surge.activate(14, client_network.local_player_id()) == false, "the client cannot activate a Surge itself")
	_check(client_session.scoring.power_charges == 1 and host_session.scoring.power_charges == 1, "...and nothing was spent")
	_check(client_surge.request(14), "the client asks the host for a Surge on the loose piece")
	await _wait_until(func(): return host_landed.size() == 3 and client_pulls.size() == 3, 8.0, "three pulls happen on both peers")
	_check(host_session.scoring.power_charges == 0, "the host spent the shared charge")
	await _wait_until(func(): return client_session.scoring.power_charges == 0 and _differences(client_manager, host_manager).is_empty(), 6.0, "the client ends with the host's pieces and charge")
	_check(client_started == [14], "the client was shown the surge begin on the piece it chose")
	_check(host_pulls == client_pulls, "the client was shown exactly the host's pulls, in order, with the same groups")
	_check(host_manager.cluster_members(14).size() == 4 and client_manager.cluster_members(14).size() == 4, "the group grew by three on both peers")
	# asking again with no charge left does nothing
	client_surge.request(14)
	for i in range(40):
		await process_frame
	_check(host_pulls.size() == 3 and host_session.scoring.power_charges == 0, "a request with no Power Charge left is refused")
	# a request for a group someone else is holding is refused, and costs nothing
	host_session.scoring.from_dict({"power_charges": 1, "revision": 5})
	host_network.announce_scoring(host_session.scoring.to_dict(), {})
	host_manager.request_pickup(14, 77)
	client_surge.request(14)
	for i in range(40):
		await process_frame
	_check(host_pulls.size() == 3 and host_session.scoring.power_charges == 1, "a group held by another player cannot be surged, and nothing is spent")

	if failures == 0:
		print("CLUSTER SURGE NETWORK TEST PASSED: the client asks, the host decides, both see the same pulls")
	quit(0 if failures == 0 else 1)
