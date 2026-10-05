extends SceneTree

# A host and a client in one process over 127.0.0.1 (same technique as tests/networking.gd). The host completes a
# Magnet zone whose pull charges a Lightning zone; the client must be shown the same activations, the same pulls and
# strikes in the same order, and end up with exactly the host's pieces -- without ever choosing a target of its own.

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("POWER ZONE NETWORK TEST FAILED: " + message)

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
	var port := 39223
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
	_check(host_session.columns == 6 and host_session.rows == 8, "the host's puzzle is the 6 x 8 grid")
	# Magnet on cell 12 (row 2, column 0): its edge is 6 (already home), 18 and 13. Lightning on cell 13 is charged by that pull.
	var magnet := PowerZone.make(6, 8, 0, 2, 1, 1, PowerZone.Kind.MAGNET)
	var lightning := PowerZone.make(6, 8, 1, 2, 1, 1, PowerZone.Kind.LIGHTNING)
	host_session.power_zones = [magnet, lightning]
	var host_powers := PowerController.new()
	host_root.add_child(host_powers)
	host_powers.setup(host_session, host_manager, host_network)
	host_powers.charge_delay = 0.05
	host_powers.strike_delay = 0.05
	host_powers.strike_gap = 0.05
	host_powers.magnet_charge_delay = 0.05
	host_powers.pull_delay = 0.05
	host_powers.pull_gap = 0.05
	host_powers.rng.seed = 77
	# The top edge and the piece below the corner are home before the client joins; so is a player-built group.
	_place(host_manager, [0, 1, 2, 3, 4, 5], Vector2(14, -9))
	_place(host_manager, [6], Vector2(11, 7))
	_place(host_manager, [14, 15, 20], Vector2(1300, 500))
	_check(host_manager.cluster_members(14).size() == 3 and host_manager.locked_count() == 7, "the host starts with a main puzzle and a free group")
	_check(magnet.state == PowerZone.State.IDLE and lightning.state == PowerZone.State.IDLE, "both zones are waiting")

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
	var client_powers := PowerController.new()
	client_root.add_child(client_powers)
	client_powers.setup(client_session, client_manager, client_network)
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
	_check(PowerZone.list_to_data(client_session.power_zones) == PowerZone.list_to_data(host_session.power_zones), "the client got the host's exact zones")
	var diffs := _differences(client_manager, host_manager)
	_check(diffs.is_empty(), "the client starts with the host's pieces %s" % [diffs])
	client_powers.rng.seed = 12345 # a different generator: if the client chose anything, it would differ

	var host_incoming := []
	var client_incoming := []
	var host_landed := []
	var host_activated := []
	var client_activated := []
	host_powers.strike_landed.connect(func(index: int, id: int, _moved: Array): host_landed.append([index, id]))
	host_powers.zone_activated.connect(func(index: int): host_activated.append(index))
	host_powers.strike_incoming.connect(func(index: int, id: int, members: Array, _rect: Rect2): host_incoming.append([index, id, members]))
	client_powers.strike_incoming.connect(func(index: int, id: int, members: Array, _rect: Rect2): client_incoming.append([index, id, members]))
	client_powers.zone_activated.connect(func(index: int): client_activated.append(index))

	# The host's player puts piece 12 down beside the main puzzle: the Magnet charges, pulls 18 and 13,
	# 13 charges the Lightning, and the Lightning strikes once.
	_check(host_network.request_place_from_bank(12, host_manager.pieces[12].correct_position + Vector2(2, 1)), "the host places the Magnet's piece")
	_check(host_network.request_pickup(12), "...picks it up")
	host_network.request_release(12)
	_check(magnet.state != PowerZone.State.IDLE, "the Magnet was charged as soon as its piece joined")
	await _wait_until(func(): return host_landed.size() == 3 and client_incoming.size() == 3, 8.0, "the pulls and the strike happen on both peers")
	_check(host_activated == [0, 1] and client_activated == [0, 1], "both peers saw the Magnet and then the Lightning (host %s, client %s)" % [host_activated, client_activated])
	_check(host_incoming == client_incoming, "the client was shown exactly the host's pulls and strike, in order, with the same groups")
	_check(host_incoming.size() == 3 and host_incoming[0][0] == 0 and host_incoming[1][0] == 0 and host_incoming[2][0] == 1, "two Magnet pulls, then one Lightning strike")
	await _wait_until(func(): return _differences(client_manager, host_manager).is_empty() and magnet.state == PowerZone.State.DONE and host_session.power_zones[1].state == PowerZone.State.DONE and client_session.power_zones[1].state == PowerZone.State.DONE, 6.0, "the client ends with exactly the host's pieces and zones")
	_check(host_session.power_zones[1].state == PowerZone.State.DONE, "the host finished both zones")
	for entry in host_landed:
		_check(client_manager.pieces[entry[1]].is_locked, "every moved piece is in the main puzzle on the client too")
	_check(client_powers.pick_target() == -1 and client_powers.check_charge() == 0, "the client still cannot choose or charge anything")
	# A second look a little later: nothing else happens.
	for i in range(30):
		await process_frame
	_check(host_incoming.size() == 3 and client_incoming.size() == 3 and host_activated == [0, 1], "nothing more happens")

	if failures == 0:
		print("POWER ZONE NETWORK TEST PASSED: the host decides, the client sees the same chain and the same final board")
	quit(0 if failures == 0 else 1)
