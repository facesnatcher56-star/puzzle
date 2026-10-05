extends SceneTree

# A host and a client in one process over 127.0.0.1 (same technique as tests/networking.gd). The host completes
# the Lightning Zone; the client must be shown the same activation, the same strikes in the same order, and end
# up with exactly the host's pieces -- without ever choosing a target of its own.

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("LIGHTNING NETWORK TEST FAILED: " + message)

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
	var port := 39219
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
	var zone := LightningZone.make(6, 8, 0, 0, 2, 2, 4) # pieces 0, 1, 6, 7
	host_session.lightning_zone = zone
	var host_lightning := LightningController.new()
	host_root.add_child(host_lightning)
	host_lightning.setup(host_session, host_manager, host_network)
	host_lightning.charge_delay = 0.05
	host_lightning.strike_delay = 0.05
	host_lightning.strike_gap = 0.05
	host_lightning.rng.seed = 77
	_check(host_session.columns == 6 and host_session.rows == 8, "the host's puzzle is the 6 x 8 grid")
	# Everything but the zone's last piece (7) is in place before the client joins.
	_place(host_manager, [0, 1, 2, 3, 4, 5], Vector2(14, -9))
	_place(host_manager, [6], Vector2(11, 7))
	# A player-built group elsewhere on the table, which a strike might pick up whole.
	_place(host_manager, [14, 15, 20], Vector2(1300, 500))
	_check(host_manager.cluster_members(14).size() == 3, "the player-built group is joined")
	_check(not zone.activated and host_manager.locked_count() == 7, "the host's zone is one piece short")

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
	var client_lightning := LightningController.new()
	client_root.add_child(client_lightning)
	client_lightning.setup(client_session, client_manager, client_network)
	client_lightning.charge_delay = 0.05
	client_lightning.strike_delay = 0.05
	client_lightning.strike_gap = 0.05
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
	var client_zone := client_session.lightning_zone
	_check(client_zone != null and client_zone.to_dict() == zone.to_dict(), "the client got the host's exact zone")
	var diffs := _differences(client_manager, host_manager)
	_check(diffs.is_empty(), "the client starts with the host's pieces %s" % [diffs])
	client_lightning.rng.seed = 12345 # a different generator: if the client chose anything, it would differ

	var host_strikes := []
	var client_strikes := []
	var host_landed := []
	var client_activations := [0]
	host_lightning.strike_landed.connect(func(id: int, _moved: Array): host_landed.append(id))
	host_lightning.strike_incoming.connect(func(id: int, members: Array, _rect: Rect2): host_strikes.append([id, members]))
	client_lightning.strike_incoming.connect(func(id: int, members: Array, _rect: Rect2): client_strikes.append([id, members]))
	client_lightning.activated.connect(func(): client_activations[0] += 1)

	# The host completes the zone: piece 7 goes down beside the main puzzle (as the host's own player would).
	_check(host_network.request_place_from_bank(7, host_manager.pieces[7].correct_position + Vector2(2, 1)), "the host places the last zone piece")
	_check(host_network.request_pickup(7), "...picks it up")
	host_network.request_release(7)
	_check(zone.activated, "the host's zone activated as soon as it was complete")
	await _wait_until(func(): return host_landed.size() == zone.strikes and client_strikes.size() == zone.strikes, 8.0, "every strike happens on both peers")
	_check(client_activations[0] == 1 and client_zone.activated, "the client was shown the activation, once, and its zone is marked used")
	_check(host_strikes == client_strikes, "the client was shown exactly the host's strikes, in order, with the same groups")
	# Each strike gets a moment to travel; wait for the last piece updates to settle.
	await _wait_until(func(): return _differences(client_manager, host_manager).is_empty(), 6.0, "the client ends with exactly the host's pieces")
	var struck_pieces := 0
	for entry in host_strikes:
		struck_pieces += 1 if client_manager.pieces[entry[0]].is_locked else 0
	_check(struck_pieces == host_strikes.size(), "every struck piece is in the main puzzle on the client too")
	_check(client_lightning.pick_target() == -1 and not client_lightning.activate(), "the client still cannot choose or activate anything")
	# A second look a little later: nothing else happens.
	for i in range(30):
		await process_frame
	_check(host_strikes.size() == zone.strikes and client_strikes.size() == zone.strikes, "no extra strikes arrive")

	if failures == 0:
		print("LIGHTNING NETWORK TEST PASSED: host decides, client sees the same strikes and the same final board")
	quit(0 if failures == 0 else 1)
