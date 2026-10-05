extends SceneTree

# Lightning Zone: when it activates, what it strikes, how a struck group moves, and that it saves and is
# decided by the host alone. Uses an 8 x 6 puzzle without rotation scrambling; the zone is placed by hand.

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("LIGHTNING TEST FAILED: " + message)

# A manager, session, network and controller wired together the way main.gd wires them, with all delays at
# zero so a whole activation plays out synchronously.
class Rig extends RefCounted:
	var manager := PuzzleManager.new()
	var network := NetworkSession.new()
	var session := PuzzleSession.new()
	var controller := LightningController.new()
	var targets_seen := [] # {id, locked} for every strike announced
	var landed := []

func _rig(seed_value: int, zone: LightningZone) -> Rig:
	var rig := Rig.new()
	var source: Texture2D = load("res://assets/emberbound.png")
	var board := Vector2(1122, 1402)
	rig.manager.configure(PuzzleGenerator.generate(source, 8, 6, seed_value, board, false), Vector2(board.x / 8, board.y / 6), 8, 6)
	root.add_child(rig.network)
	root.add_child(rig.session)
	root.add_child(rig.controller)
	rig.network.configure(rig.manager, Callable(rig.session, "puzzle_config"))
	rig.session.setup(rig.manager, rig.network)
	rig.session.columns = 8
	rig.session.rows = 6
	rig.session.lightning_zone = zone
	rig.controller.setup(rig.session, rig.manager, rig.network)
	rig.controller.charge_delay = 0.0
	rig.controller.strike_delay = 0.0
	rig.controller.strike_gap = 0.0
	rig.controller.rng.seed = seed_value
	rig.controller.strike_incoming.connect(func(id: int, _members: Array, _rect: Rect2):
		rig.targets_seen.append({"id": id, "locked": rig.manager.pieces[id].is_locked}))
	rig.controller.strike_landed.connect(func(id: int, moved: Array): rig.landed.append({"id": id, "moved": moved}))
	return rig

# Drops pieces a little off their true spots and lets them snap, like a player would.
func _place(m: PuzzleManager, ids: Array, offset: Vector2) -> void:
	for id in ids:
		m.request_place_from_bank(id, m.pieces[id].correct_position + offset)
	for id in ids:
		m.request_pickup(id)
		m.request_release(id)

func _lock_top_edge(m: PuzzleManager) -> void:
	_place(m, [0, 1, 2, 3, 4, 5, 6, 7], Vector2(14, -9))

func _main_count(m: PuzzleManager) -> int:
	return m.locked_count()

func _run() -> void:
	_test_zone_sizes()
	await _test_activation_rules()
	_test_struck_pieces()
	_test_targeting_and_full_sequence()
	_test_save_and_load()
	_test_authority()
	print("lightning test done, failures: ", failures)
	quit(1 if failures > 0 else 0)

# --- zone generation ---

func _test_zone_sizes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var grids := [Vector2i(4, 6), Vector2i(6, 4), Vector2i(8, 6), Vector2i(8, 12), Vector2i(12, 9), Vector2i(10, 25), Vector2i(18, 14)]
	var strikes_seen := {}
	for grid in grids:
		for i in range(200):
			var zone := LightningZone.random(grid.x, grid.y, rng)
			var total: int = grid.x * grid.y
			_check(zone.column >= 0 and zone.row >= 0 and zone.column + zone.width <= grid.x and zone.row + zone.height <= grid.y, "zone fits the %s grid" % [grid])
			_check(zone.width >= 2 and zone.height >= 2 and zone.cell_count() <= total * 0.4, "zone is a sensible size on the %s grid (%dx%d)" % [grid, zone.width, zone.height])
			_check(zone.strikes >= 1 and zone.strikes <= total - zone.cell_count(), "strike count is possible on the %s grid" % [grid])
			if total >= 100:
				match zone.tier:
					LightningZone.Tier.SMALL: _check(zone.strikes == 3, "a small zone strikes 3 times")
					LightningZone.Tier.MEDIUM: _check(zone.strikes == 5 or zone.strikes == 6, "a medium zone strikes 5 or 6 times")
					LightningZone.Tier.LARGE: _check(zone.strikes >= 8 and zone.strikes <= 10, "a large zone strikes 8 to 10 times")
				strikes_seen[zone.tier] = true
	_check(strikes_seen.size() == 3, "all three zone tiers come up")
	# bigger zones are worth more
	var small_area := 0
	var large_area := 0
	for i in range(100):
		var zone := LightningZone.random(12, 9, rng)
		if zone.tier == LightningZone.Tier.SMALL:
			small_area = maxi(small_area, zone.cell_count())
		elif zone.tier == LightningZone.Tier.LARGE:
			large_area = maxi(large_area, zone.cell_count())
	_check(large_area > small_area, "large zones cover more cells than small ones")

# --- activation ---

func _test_activation_rules() -> void:
	# A 2 x 2 zone in the middle of the board, away from every edge: pieces 27, 28, 35, 36.
	var zone := LightningZone.make(8, 6, 3, 3, 2, 2, 4)
	_check(zone.cell_ids() == [27, 28, 35, 36], "the zone's cells are where expected")
	# All four pieces sitting exactly on their spots, joined to each other but not to the main puzzle.
	var sitting := _rig(1, LightningZone.make(8, 6, 3, 3, 2, 2, 4))
	_place(sitting.manager, [27, 28, 35, 36], Vector2.ZERO)
	_lock_top_edge(sitting.manager)
	_check(sitting.manager.locked_count() == 8 and sitting.manager.cluster_members(27).size() == 4, "the zone pieces form a free group beside a main puzzle that does not reach them")
	_check(not sitting.session.lightning_zone.is_charged(sitting.manager) and not sitting.controller.check_charge(), "pieces merely sitting over the zone do not activate it")
	_check(not sitting.session.lightning_zone.activated and sitting.landed.is_empty(), "nothing struck")
	# Now the real thing: three of the four zone pieces get connected, then the last one.
	var rig := _rig(2, zone)
	var m := rig.manager
	_place(m, [27, 28, 35], Vector2.ZERO)
	_lock_top_edge(m)
	_check(m.locked_count() == 8 and not zone.is_charged(m) and not rig.controller.check_charge(), "a main puzzle that does not reach the zone does not activate it")
	_place(m, [11, 19], Vector2(11, 7)) # reaches the zone's three pieces and takes them in
	_check(m.pieces[27].is_locked and m.pieces[28].is_locked and m.pieces[35].is_locked and not m.pieces[36].is_on_table, "three of the four zone cells are now in the main puzzle")
	_check(not zone.is_charged(m) and not rig.controller.check_charge() and not zone.activated, "a partly connected zone does not activate")
	_check(rig.landed.is_empty(), "no strike yet")
	var main_before := m.locked_count()
	_place(m, [36], Vector2(8, 6)) # the last cell
	_check(m.pieces[36].is_locked and zone.is_charged(m), "every cell of the zone is now in the main puzzle")
	_check(zone.activated, "completing the zone activates it")
	_check(rig.targets_seen.size() == zone.strikes and rig.landed.size() == zone.strikes, "an activated zone strikes exactly its strike count")
	_check(m.locked_count() > main_before, "the strikes added pieces to the main puzzle")
	# only once
	var strikes_before: int = rig.landed.size()
	_check(not rig.controller.check_charge() and not rig.controller.activate(), "an activated zone cannot be activated again")
	m.group_locked.emit(0, [0], ["TOP"])
	_check(rig.landed.size() == strikes_before, "further locks do not strike again")
	var loose := m.lightning_targets()
	if not loose.is_empty():
		_place(m, [loose[0]], Vector2(5, 5))
	_check(rig.landed.size() == strikes_before, "placing more pieces does not strike again")

# --- what one strike does ---

func _test_struck_pieces() -> void:
	var rig := _rig(2, LightningZone.make(8, 6, 0, 0, 2, 2, 3))
	var m := rig.manager
	_lock_top_edge(m)
	# A piece still in the bank, right below the top edge, is fetched.
	_check(not m.pieces[9].is_on_table, "piece 9 starts in the bank")
	var moved := m.strike_piece(9)
	var p9 := m.pieces[9]
	_check(moved == [9] and p9.is_on_table and p9.current_position == p9.correct_position and p9.current_rotation == 0, "a struck bank piece lands exactly in place")
	_check(p9.is_locked and m.cluster_members(9).has(0) and m.clusters.size() == 1, "a struck piece joins the main puzzle")
	# A loose piece lying elsewhere, turned the wrong way.
	m.request_place_from_bank(10, Vector2(2200, 1500))
	m.pieces[10].current_rotation = 270
	moved = m.strike_piece(10)
	var p10 := m.pieces[10]
	_check(moved == [10] and p10.current_position == p10.correct_position and p10.current_rotation == 0 and p10.is_locked, "a loose turned piece is straightened and placed")
	# Something already in the main puzzle is left alone.
	_check(m.strike_piece(3).is_empty() and m.strike_piece(9).is_empty(), "pieces already in the main puzzle are not struck")
	# A group built by the player: 12, 13 and 20 joined, far away and upside down.
	_place(m, [12, 13, 20], Vector2(900, 700))
	_check(m.cluster_members(12).size() == 3 and not m.pieces[12].is_locked, "the loose three-piece group is joined and free")
	m.request_rotate(12)
	m.request_rotate(12)
	var group_id: int = m.pieces[12].cluster_id
	var members_before: Array = m.cluster_members(12).duplicate()
	_check(m.pieces[13].current_rotation == 180, "the group has been turned upside down")
	var main_size_before := m.locked_count()
	moved = m.strike_piece(13) # strike the middle one: the whole group must follow
	moved.sort()
	_check(moved == members_before, "striking one piece of a group moves the whole group")
	for id in members_before:
		var piece: PuzzlePieceState = m.pieces[id]
		_check(piece.current_position == piece.correct_position and piece.current_rotation == 0, "group member %d ends exactly in place and upright" % id)
		_check(piece.is_locked, "group member %d is part of the main puzzle" % id)
	# relative alignment to the struck piece is exactly the true one
	var target := m.pieces[13]
	for id in members_before:
		var piece: PuzzlePieceState = m.pieces[id]
		_check((piece.current_position - target.current_position).is_equal_approx(piece.correct_position - target.correct_position), "member %d sits right relative to the struck piece" % id)
	_check(_locked_groups(m) == 1 and m.cluster_members(12).has(0), "the group's joins survived and it joined the main puzzle as one")
	_check(m.is_joined_side(12, 1) and m.is_joined_side(12, 2), "joins inside the group are intact")
	_check(m.locked_count() == main_size_before + members_before.size(), "exactly the group's pieces were added to the main puzzle")
	_check(group_id >= 0, "the group existed before the strike")

# --- who gets struck ---

func _test_targeting_and_full_sequence() -> void:
	var zone := LightningZone.make(8, 6, 0, 0, 2, 2, 6, LightningZone.Tier.MEDIUM)
	var rig := _rig(3, zone)
	var m := rig.manager
	_lock_top_edge(m)
	# Pieces in the main puzzle are never targets; neither are ones far from it, and neither is a held group.
	var targets := m.lightning_targets()
	var none_locked := true
	for id in targets:
		none_locked = none_locked and not m.pieces[id].is_locked
	_check(not targets.is_empty() and none_locked, "targets are only pieces outside the main puzzle")
	_check(targets.has(8) and targets.has(15) and not targets.has(0) and not targets.has(30), "targets are the places beside the main puzzle")
	m.request_place_from_bank(8, Vector2(1800, 300))
	m.request_pickup(8, 5)
	_check(not m.lightning_targets().has(8), "a group a player is holding is not targeted")
	m.request_release(8, 5)
	_check(m.lightning_targets().has(8), "...until it is let go")
	# A group of two beside the main puzzle makes both its places targets.
	_place(m, [9, 17], Vector2(1500, 600))
	_check(m.cluster_members(9).size() == 2, "the pair is joined")
	_check(m.lightning_targets().has(9) and m.lightning_targets().has(17), "every place in a group beside the main puzzle is a target")
	# Run a whole activation.
	var main_before := m.locked_count()
	zone.activated = false
	_check(rig.controller.activate(), "the zone activates")
	_check(rig.landed.size() == zone.strikes, "every strike lands while targets remain")
	var seen := {}
	for strike in rig.targets_seen:
		_check(not strike.locked, "strike on piece %d was aimed at an unfinished place" % strike.id)
		_check(not seen.has(strike.id), "piece %d is not struck twice" % strike.id)
		seen[strike.id] = true
	var landed_ids := {}
	for entry in rig.landed:
		for id in entry.moved:
			landed_ids[id] = true
			_check(m.pieces[id].is_locked and m.pieces[id].current_position == m.pieces[id].correct_position, "struck piece %d ended in the main puzzle at its true place" % id)
	_check(m.locked_count() == main_before + landed_ids.size(), "only struck pieces were added to the main puzzle")
	_check(_locked_groups(m) == 1, "the main puzzle is a single group")
	# No targets left: strikes stop instead of being wasted.
	var small := _rig(4, LightningZone.make(8, 6, 0, 0, 2, 2, 40))
	_lock_top_edge(small.manager)
	small.controller.activate()
	_check(small.landed.size() <= 48 - 8 and small.manager.locked_count() <= 48, "strikes stop once nothing is left to strike")
	_check(small.manager.completion_announced and small.manager.locked_count() == 48, "enough strikes finish the puzzle")

func _locked_groups(m: PuzzleManager) -> int:
	var count := 0
	for key in m.clusters:
		if m.pieces[m.clusters[key][0]].is_locked:
			count += 1
	return count

# --- saving ---

func _test_save_and_load() -> void:
	SaveManager.save_dir = "user://test_saves_lightning"
	var network := NetworkSession.new()
	root.add_child(network)
	var manager := PuzzleManager.new()
	var session := PuzzleSession.new()
	session.setup(manager, network)
	root.add_child(session)
	network.configure(manager, Callable(session, "puzzle_config"))
	session.random_rotation = false
	session.size_index = 1 # 6 x 8 on the classic picture
	session.start_puzzle(false)
	var original := session.lightning_zone
	_check(original != null and original.columns == session.columns and original.rows == session.rows, "a new puzzle gets a zone for its own grid")
	_check(not original.activated, "a new zone is not activated")
	session.save_slot = "lightning_test"
	session.write_save()
	var reloaded := PuzzleSession.new()
	var m2 := PuzzleManager.new()
	reloaded.setup(m2, network)
	root.add_child(reloaded)
	_check(reloaded.load_session("lightning_test"), "the save loads")
	var zone := reloaded.lightning_zone
	_check(zone != null and zone.to_dict() == original.to_dict(), "the zone comes back exactly: cells, size and strikes")
	# An activated zone stays activated, and cannot fire again even though its cells are locked.
	original.activated = true
	session.write_save()
	var again := PuzzleSession.new()
	var m3 := PuzzleManager.new()
	again.setup(m3, network)
	root.add_child(again)
	_check(again.load_session("lightning_test") and again.lightning_zone.activated, "activation is remembered by the save")
	var controller := LightningController.new()
	root.add_child(controller)
	controller.setup(again, m3, network)
	controller.charge_delay = 0.0
	controller.strike_delay = 0.0
	controller.strike_gap = 0.0
	var landed := []
	controller.strike_landed.connect(func(id: int, _moved: Array): landed.append(id))
	for id in again.lightning_zone.cell_ids():
		m3.request_place_from_bank(id, m3.pieces[id].correct_position)
		m3.pieces[id].is_locked = true
	_check(again.lightning_zone.is_charged(m3), "the loaded zone's cells are in the main puzzle")
	_check(not controller.check_charge() and not controller.activate() and landed.is_empty(), "a loaded, already used zone does not fire again")
	# A save that predates zones has none, and nothing fires.
	var legacy := session.puzzle_config()
	legacy.erase("lightning")
	var legacy_session := PuzzleSession.new()
	legacy_session.setup(PuzzleManager.new(), network)
	root.add_child(legacy_session)
	legacy["pieces"] = []
	for piece in session.manager.pieces:
		legacy["pieces"].append(piece.snapshot())
	legacy_session.restore_puzzle(legacy)
	_check(legacy_session.lightning_zone == null, "a save without a zone loads without one")
	# damaged zone data is rejected
	_check(LightningZone.from_dict({"column": 7, "row": 0, "width": 3, "height": 2, "strikes": 3}, 8, 6) == null, "a zone that does not fit the grid is rejected")
	SaveManager.delete_slot("lightning_test")

# --- authority ---

func _test_authority() -> void:
	var zone := LightningZone.make(8, 6, 0, 0, 2, 2, 4)
	var rig := _rig(5, zone)
	var m := rig.manager
	# A client's own copy of the puzzle snaps and locks pieces like anyone's, so the zone is completed
	# right there on the client.
	rig.network.mode = NetworkSession.Mode.CLIENT
	_lock_top_edge(m)
	_place(m, [8, 9], Vector2(11, 7))
	_check(zone.is_charged(m), "the client's copy of the zone is complete")
	_check(not zone.activated and rig.targets_seen.is_empty() and rig.landed.is_empty(), "completing the zone on a client does not activate it")
	var snapshot := []
	for piece in m.pieces:
		snapshot.append(piece.snapshot())
	_check(not rig.controller.has_authority(), "a client has no authority over lightning")
	_check(rig.controller.pick_target() == -1, "a client never picks a strike target")
	_check(not rig.controller.check_charge() and not rig.controller.activate() and not zone.activated, "a client never activates the zone")
	_check(rig.controller.apply_strike(20).is_empty(), "a client never moves pieces for lightning")
	rig.network.announce_lightning_strike(20, [20])
	rig.network.broadcast_lightning_result(20)
	var after := []
	for piece in m.pieces:
		after.append(piece.snapshot())
	_check(after == snapshot and rig.landed.is_empty() and rig.targets_seen.is_empty(), "nothing on a client changed")
	# Only the host may send lightning messages: the RPCs are authority-only.
	var config: Dictionary = rig.network.get_script().get_rpc_config()
	for name in ["_sync_lightning_strike", "_sync_lightning_activated"]:
		_check(config.has(name) and int(config[name].rpc_mode) == MultiplayerAPI.RPC_MODE_AUTHORITY, "%s can only be sent by the host" % name)
	# What the host announces is shown on a client, without the client choosing anything.
	var seen := []
	rig.controller.strike_incoming.connect(func(id: int, members: Array, _rect: Rect2): seen.append([id, members]))
	rig.network.lightning_strike_received.emit(20, [20])
	_check(seen == [[20, [20]]], "a client shows the strike the host announced")
	var flashed := []
	rig.controller.activated.connect(func(): flashed.append(true))
	rig.network.lightning_activated_received.emit()
	_check(flashed.size() == 1 and zone.activated, "a client shows the activation the host announced")
	rig.network.mode = NetworkSession.Mode.SOLO
