extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("SCORING NETWORK TEST FAILED: " + message)

func _wait_until(predicate: Callable, seconds: float, message: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	_check(false, message + " (timed out)")
	return false

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
	host_session.size_index = 1 # 6 x 8
	host_session.start_puzzle(false)
	_place(host_manager, [0, 1, 2, 3, 4, 5], Vector2(14, -9))
	_check(host_session.scoring.score == roundi(900.0 * RunScoring.streak_multiplier(host_session.scoring.streak)) and host_session.scoring.streak <= 6, "host scored the initial six-piece border once: %s" % [host_session.scoring.to_dict()])

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
	var synced := [false]
	client_network.full_state_received.connect(func(config: Dictionary, snapshots: Array):
		client_session.restore_from_host(config, snapshots)
		synced[0] = true)
	var host_awards := []
	var client_awards := []
	host_session.scoring.awarded.connect(func(event: Dictionary): host_awards.append(event))
	client_session.scoring.awarded.connect(func(event: Dictionary): client_awards.append(event))
	_check(host_network.start_host(39221) == OK, "host starts")
	await process_frame
	_check(client_network.start_client("127.0.0.1", 39221) == OK, "client joins")
	if not await _wait_until(func(): return synced[0], 6.0, "client receives the run"):
		quit(1)
		return
	_check(client_session.scoring.to_dict() == host_session.scoring.to_dict() and client_awards.is_empty(), "late join gets the exact score state without replaying old awards")
	var before := client_session.scoring.to_dict()
	client_manager.main_puzzle_connected.emit([0], PuzzleManager.ConnectionSource.MANUAL)
	_check(client_session.scoring.award_connection([0], PuzzleManager.ConnectionSource.MANUAL).is_empty() and client_session.scoring.to_dict() == before, "client cannot award score from local puzzle events")
	client_network.announce_scoring({"score": 999999, "revision": 99}, {})
	_check(client_session.scoring.to_dict() == before, "client cannot broadcast scoring results")
	var config: Dictionary = client_network.get_script().get_rpc_config()
	_check(config.has("_sync_scoring") and int(config["_sync_scoring"].rpc_mode) == MultiplayerAPI.RPC_MODE_AUTHORITY, "scoring sync RPC is host-only")
	_check(host_network.request_place_from_bank(6, host_manager.pieces[6].correct_position + Vector2(3, 2)), "host places a manual neighbor")
	host_network.request_release(6)
	await _wait_until(func(): return client_awards.size() == 1, 6.0, "client sees the manual award")
	_check(host_awards.size() == 1 and host_awards[0].score_gain == 125 and client_awards[0] == host_awards[0], "manual award and WARM multiplier are identical: %s" % [host_awards])
	_check(client_session.scoring.to_dict() == host_session.scoring.to_dict(), "manual scoring state is synchronized")
	# The host pulls a player-built disconnected group; the client gets one reward event and the
	# authoritative piece snapshots. The incoming snapshots must never cause a second award.
	_place(host_manager, [7, 8, 13, 14, 19, 20], Vector2(950, 600))
	_check(host_manager.cluster_members(7).size() == 6, "host has a six-piece disconnected cluster")
	var loose_events := host_awards.size() - 1
	_check(loose_events > 0 and host_awards.back().kind == "LOOSE", "host rewards valid disconnected joins")
	var before_jackpot := host_awards.size()
	var moved := host_manager.strike_piece(7)
	host_network.broadcast_power_result(7)
	var power_event: Dictionary = host_awards.back()
	_check(moved.size() == 6 and host_awards.size() == before_jackpot + 1 and power_event.piece_count == 6 and power_event.source == PuzzleManager.ConnectionSource.POWER, "host generated one power jackpot event")
	await _wait_until(func(): return client_awards.size() == host_awards.size() and client_session.scoring.to_dict() == host_session.scoring.to_dict(), 6.0, "client receives loose joins and the jackpot")
	_check(client_awards.back() == power_event and power_event.score_gain == roundi(900.0 * float(power_event.multiplier)) and power_event.charge_gain == roundi(15.0 * RunScoring.CHARGE_MULTIPLIERS[int(power_event.combo_after)] * 0.5), "client sees identical score, half Charge and combo event: %s" % [power_event])
	var received_state := client_session.scoring.to_dict()
	client_network.scoring_sync_received.emit(received_state, power_event)
	for i in range(15):
		await process_frame
	_check(client_awards.size() == host_awards.size() and client_session.scoring.to_dict() == received_state, "replayed sync and piece snapshots cannot duplicate the award")
	var seeded := host_session.scoring.to_dict()
	seeded["power_charges"] = 1
	seeded["revision"] = int(seeded.revision) + 1
	host_session.scoring.from_dict(seeded)
	host_network.announce_scoring(host_session.scoring.to_dict(), {})
	await _wait_until(func(): return client_session.scoring.power_charges == 1, 6.0, "client receives a spendable shared charge")
	if failures == 0:
		print("SCORING NETWORK TEST PASSED")
	quit(0 if failures == 0 else 1)
