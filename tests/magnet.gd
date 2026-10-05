extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("MAGNET TEST FAILED: " + message)

class Rig extends RefCounted:
	var manager := PuzzleManager.new()
	var network := NetworkSession.new()
	var session := PuzzleSession.new()
	var controller := MagnetController.new()
	var incoming := []
	var landed := []
	var activations := [0]

func _rig(zone: MagnetZone) -> Rig:
	var rig := Rig.new()
	var source: Texture2D = load("res://assets/emberbound.png")
	var board := Vector2(1122, 1402)
	rig.manager.configure(PuzzleGenerator.generate(source, 8, 6, 7642, board, false), Vector2(board.x / 8, board.y / 6), 8, 6)
	root.add_child(rig.network)
	root.add_child(rig.session)
	root.add_child(rig.controller)
	rig.network.configure(rig.manager, Callable(rig.session, "puzzle_config"))
	rig.session.setup(rig.manager, rig.network)
	rig.session.columns = 8
	rig.session.rows = 6
	rig.session.magnet_zone = zone
	rig.controller.setup(rig.session, rig.manager, rig.network)
	rig.controller.charge_delay = 0.0
	rig.controller.pull_delay = 0.0
	rig.controller.pull_gap = 0.0
	rig.controller.activated.connect(func(): rig.activations[0] += 1)
	rig.controller.pull_incoming.connect(func(id: int, members: Array, _rect: Rect2): rig.incoming.append([id, members]))
	rig.controller.pull_landed.connect(func(id: int, members: Array): rig.landed.append([id, members]))
	return rig

func _place(m: PuzzleManager, ids: Array, offset: Vector2) -> void:
	for id in ids:
		m.request_place_from_bank(id, m.pieces[id].correct_position + offset)
	for id in ids:
		m.request_pickup(id)
		m.request_release(id)

func _run() -> void:
	_test_generation()
	_test_perimeter_and_pulls()
	_test_save_load()
	_test_client_authority()
	print("magnet test done, failures: ", failures)
	quit(1 if failures > 0 else 0)

func _test_generation() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9324
	for grid in [Vector2i(4, 6), Vector2i(6, 8), Vector2i(8, 12), Vector2i(10, 25), Vector2i(6, 4), Vector2i(8, 6), Vector2i(12, 9), Vector2i(18, 14)]:
		for i in range(30):
			var lightning := LightningZone.random(grid.x, grid.y, rng)
			var magnet := MagnetZone.random(grid.x, grid.y, rng, lightning)
			_check(magnet != null, "a Magnet Zone fits a %s puzzle" % grid)
			if magnet == null:
				continue
			_check(magnet.width * magnet.height >= 2 and magnet.width * magnet.height <= 12, "zone size stays reasonable")
			for id in magnet.cell_ids():
				_check(not lightning.contains_cell(id), "Magnet and Lightning never overlap")

func _test_perimeter_and_pulls() -> void:
	var zone := MagnetZone.make(8, 6, 2, 1, 2, 2)
	var rig := _rig(zone)
	var m := rig.manager
	_check(zone.perimeter_ids() == [9, 12, 17, 20, 2, 26, 3, 27], "the original perimeter has only orthogonal neighbors")
	_check(not zone.perimeter_ids().has(8) and not zone.perimeter_ids().has(13) and not zone.perimeter_ids().has(28), "diagonals and distance-two cells are outside the perimeter")
	_check(not rig.controller.check_charge() and not rig.controller.activate() and not zone.activated, "the empty zone cannot activate")
	_place(m, [0, 1, 2, 3, 4, 5, 6, 7], Vector2(14, -9))
	_place(m, [10, 11, 18], Vector2(12, 8))
	_check(not zone.is_charged(m) and not zone.activated and not rig.controller.check_charge() and not rig.controller.activate(), "one unfinished zone cell prevents activation")
	# Two perimeter cells share one remote cluster; piece 21 comes along although it is outside the ring.
	_place(m, [12, 20, 21], Vector2(900, 700))
	_check(m.cluster_members(12).size() == 3 and not m.pieces[12].is_locked, "the detached cluster has three joined pieces")
	m.request_rotate(12)
	var cluster_before: Array = m.cluster_members(12).duplicate()
	m.request_place_from_bank(26, Vector2(1800, 900))
	m.request_place_from_bank(9, Vector2(1850, 200))
	m.request_pickup(9, 5)
	m.request_place_from_bank(27, Vector2(1900, 300))
	m.request_pickup(27, 6)
	_check(not m.pieces[17].is_on_table, "a perimeter target starts in the bank")
	# Complete the zone before asking the controller to react; this also tests the same locked rule as Lightning.
	_place(m, [19], Vector2(12, 8))
	_check(zone.is_charged(m) and zone.activated, "the final locked zone cell activates Magnet")
	var seen := []
	for entry in rig.incoming:
		seen.append(entry[0])
	_check(seen.size() == 3 and seen.has(12) and seen.has(17) and seen.has(26), "all eligible perimeter groups were captured once")
	_check(not seen.has(9) and not seen.has(27) and not seen.has(2) and not seen.has(3), "held and already-main pieces were ignored")
	_check(rig.activations[0] == 1 and not rig.controller.check_charge() and not rig.controller.activate(), "Magnet activates exactly once")
	_check(rig.landed.size() == 3, "three distinct clusters landed once each")
	for id in cluster_before:
		_check(m.pieces[id].is_locked and m.pieces[id].current_position == m.pieces[id].correct_position and m.pieces[id].current_rotation == 0, "the entire rotated cluster was aligned and locked")
	_check(m.is_joined_side(12, 2) and m.is_joined_side(20, 1), "the cluster's original joins survive")
	_check(m.pieces[26].is_locked and m.pieces[26].current_position == m.pieces[26].correct_position, "the loose neighbor snapped into place")
	_check(m.pieces[17].is_on_table and m.pieces[17].is_locked and m.pieces[17].current_position == m.pieces[17].correct_position, "a bank piece was fetched and placed")
	_check(not m.pieces[28].is_on_table and not m.pieces[29].is_on_table, "newly attached pieces did not extend the range")
	_check(not m.pieces[9].is_locked and not m.pieces[27].is_locked, "held groups remain untouched")
	_check(m.cluster_members(12).has(2), "the attracted group joined the main puzzle")

func _test_save_load() -> void:
	SaveManager.save_dir = "user://test_saves_magnet"
	var network := NetworkSession.new()
	root.add_child(network)
	var manager := PuzzleManager.new()
	var session := PuzzleSession.new()
	root.add_child(session)
	session.setup(manager, network)
	network.configure(manager, Callable(session, "puzzle_config"))
	session.random_rotation = false
	session.size_index = 1
	session.start_puzzle(false)
	var original := session.magnet_zone
	_check(original != null, "new puzzles generate Magnet")
	session.save_slot = "magnet_test"
	session.write_save()
	var restored := PuzzleSession.new()
	root.add_child(restored)
	var restored_manager := PuzzleManager.new()
	restored.setup(restored_manager, network)
	_check(restored.load_session("magnet_test") and restored.magnet_zone.to_dict() == original.to_dict(), "zone location and size survive save/load")
	original.activated = true
	session.write_save()
	var used := PuzzleSession.new()
	root.add_child(used)
	used.setup(PuzzleManager.new(), network)
	_check(used.load_session("magnet_test") and used.magnet_zone.activated, "activated state survives save/load")
	var legacy := session.puzzle_config()
	legacy.erase("magnet")
	legacy["pieces"] = []
	for piece in manager.pieces:
		legacy["pieces"].append(piece.snapshot())
	var old := PuzzleSession.new()
	root.add_child(old)
	old.setup(PuzzleManager.new(), network)
	old.restore_puzzle(legacy)
	_check(old.magnet_zone == null, "a save from before Magnet loads safely")
	_check(MagnetZone.from_dict({"column": 7, "row": 0, "width": 2, "height": 2}, 8, 6) == null, "invalid zone data is rejected")
	SaveManager.delete_slot("magnet_test")

func _test_client_authority() -> void:
	var rig := _rig(MagnetZone.make(8, 6, 2, 1, 2, 2))
	rig.network.mode = NetworkSession.Mode.CLIENT
	var m := rig.manager
	_place(m, [0, 1, 2, 3, 4, 5, 6, 7], Vector2(14, -9))
	_place(m, [10, 11, 18, 19], Vector2(12, 8))
	_check(rig.session.magnet_zone.is_charged(m) and not rig.session.magnet_zone.activated, "client completion does not activate Magnet")
	_check(rig.controller.capture_targets().is_empty() and not rig.controller.check_charge() and not rig.controller.activate(), "client cannot choose targets or activate")
	var before := m.pieces[17].snapshot()
	_check(rig.controller.apply_pull(17).is_empty() and m.pieces[17].snapshot() == before, "client cannot move a Magnet target")
	rig.network.announce_magnet_activated()
	rig.network.announce_magnet_pull(17, [17])
	rig.network.broadcast_power_result(17)
	_check(rig.incoming.is_empty() and not rig.session.magnet_zone.activated, "client cannot announce outcomes")
	var config: Dictionary = rig.network.get_script().get_rpc_config()
	for name in ["_sync_magnet_activated", "_sync_magnet_pull"]:
		_check(config.has(name) and int(config[name].rpc_mode) == MultiplayerAPI.RPC_MODE_AUTHORITY, "%s is host-only" % name)
	rig.network.magnet_activated_received.emit()
	rig.network.magnet_pull_received.emit(17, [17])
	_check(rig.session.magnet_zone.activated and rig.activations[0] == 1 and rig.incoming == [[17, [17]]], "client shows only the host's announced sequence")
	rig.network.mode = NetworkSession.Mode.SOLO
