extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("MAGNET NETWORK TEST FAILED: " + message)

func _wait_until(predicate: Callable, seconds: float, message: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	_check(false, message + " (timed out)")
	return false

func _differences(a: PuzzleManager, b: PuzzleManager) -> Array:
	var result := []
	for id in range(a.pieces.size()):
		var x := a.pieces[id].snapshot()
		var y := b.pieces[id].snapshot()
		var near := Vector2(x.position[0], x.position[1]).distance_to(Vector2(y.position[0], y.position[1])) < 0.01
		x.position = y.position
		x.owner_peer_id = 0
		y.owner_peer_id = 0
		if not near or x != y:
			result.append(id)
	return result

func _place(m: PuzzleManager, ids: Array, offset: Vector2) -> void:
	for id in ids:
		m.request_place_from_bank(id, m.pieces[id].correct_position + offset)
	for id in ids:
		m.request_pickup(id)
		m.request_release(id)

func _run() -> void:
	var host_root := Node.new()
	root.add_child(host_root)
	set_multiplayer(SceneMultiplayer.new(), host_root.get_path())
	var host_manager := PuzzleManager.new()
	var host_network := NetworkSession.new()
	host_network.name = "Session"
	host_root.add_child(host_network)
	var host_session := PuzzleSession.new()
	host_root.add_child(host_session)
	host_session.setup(host_manager, host_network)
	host_network.configure(host_manager, Callable(host_session, "puzzle_config"))
	host_session.random_rotation = false
	host_session.size_index = 1
	host_session.start_puzzle(false)
	var zone := MagnetZone.make(6, 8, 0, 1, 2, 2)
	host_session.magnet_zone = zone
	var host_magnet := MagnetController.new()
	host_root.add_child(host_magnet)
	host_magnet.setup(host_session, host_manager, host_network)
	host_magnet.charge_delay = 0.05
	host_magnet.pull_delay = 0.05
	host_magnet.pull_gap = 0.05
	_place(host_manager, [0, 1, 2, 3, 4, 5], Vector2(14, -9))
	_place(host_manager, [6, 7, 12], Vector2(11, 7))
	_place(host_manager, [8, 14, 15], Vector2(1300, 500))
	_check(host_manager.cluster_members(8).size() == 3 and not zone.activated, "host has a detached cluster and an unfinished zone")

	var client_root := Node.new()
	root.add_child(client_root)
	set_multiplayer(SceneMultiplayer.new(), client_root.get_path())
	var client_manager := PuzzleManager.new()
	var client_network := NetworkSession.new()
	client_network.name = "Session"
	client_root.add_child(client_network)
	var client_session := PuzzleSession.new()
	client_root.add_child(client_session)
	client_session.setup(client_manager, client_network)
	client_network.configure(client_manager, func(): return {})
	var client_magnet := MagnetController.new()
	client_root.add_child(client_magnet)
	client_magnet.setup(client_session, client_manager, client_network)
	var synced := [false]
	client_network.full_state_received.connect(func(config: Dictionary, snapshots: Array):
		client_session.restore_from_host(config, snapshots)
		synced[0] = true)
	_check(host_network.start_host(39220) == OK, "host starts")
	await process_frame
	_check(client_network.start_client("127.0.0.1", 39220) == OK, "client joins")
	if not await _wait_until(func(): return synced[0], 6.0, "client receives initial state"):
		quit(1)
		return
	_check(client_session.magnet_zone.to_dict() == zone.to_dict() and _differences(host_manager, client_manager).is_empty(), "client received the zone and board")
	var host_pulls := []
	var client_pulls := []
	var landed := []
	var activations := [0]
	host_magnet.pull_incoming.connect(func(id: int, members: Array, _rect: Rect2): host_pulls.append([id, members]))
	client_magnet.pull_incoming.connect(func(id: int, members: Array, _rect: Rect2): client_pulls.append([id, members]))
	host_magnet.pull_landed.connect(func(id: int, _members: Array): landed.append(id))
	client_magnet.activated.connect(func(): activations[0] += 1)
	_check(host_network.request_place_from_bank(13, host_manager.pieces[13].correct_position + Vector2(2, 1)), "host places final zone piece")
	_check(host_network.request_pickup(13), "host picks up final piece")
	host_network.request_release(13)
	_check(zone.activated, "host activated Magnet")
	await _wait_until(func(): return landed.size() == 3 and client_pulls.size() == 3, 6.0, "all perimeter groups pulled")
	_check(host_pulls == client_pulls and host_pulls.size() == 3, "host and client saw identical ordered targets and members")
	_check(activations[0] == 1 and client_session.magnet_zone.activated, "client saw one activation")
	await _wait_until(func(): return _differences(host_manager, client_manager).is_empty(), 6.0, "boards converge")
	_check(client_manager.pieces[8].is_locked and client_manager.pieces[14].is_locked and client_manager.pieces[15].is_locked, "whole cluster arrived on client")
	_check(client_magnet.capture_targets().is_empty() and not client_magnet.activate() and client_magnet.apply_pull(20).is_empty(), "client has no gameplay authority")
	if failures == 0:
		print("MAGNET NETWORK TEST PASSED")
	quit(0 if failures == 0 else 1)
