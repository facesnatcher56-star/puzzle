extends SceneTree

# Board-power zones: how a layout is generated (coverage, sizes, kinds, touching), when a zone charges, what
# Lightning and Magnet do, how zones chain, that it all saves, and that only the host decides.
# Hand-made zones on an 8 x 6 puzzle without rotation scrambling; a correctly placed corner anchors the main puzzle.

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("POWER ZONE TEST FAILED: " + message)

class Rig extends RefCounted:
	var manager := PuzzleManager.new()
	var network := NetworkSession.new()
	var session := PuzzleSession.new()
	var controller := PowerController.new()
	var activated := [] # zone indices, in the order they began
	var incoming := [] # {zone, id, members, locked}
	var landed := [] # {zone, id, moved}

# A manager, session, network and controller wired together the way main.gd wires them, with every delay at
# zero so a whole chain plays out synchronously.
func _rig(zones: Array, seed_value: int = 1) -> Rig:
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
	rig.session.power_zones = zones
	rig.controller.setup(rig.session, rig.manager, rig.network)
	rig.controller.make_instant()
	rig.controller.rng.seed = seed_value
	rig.controller.zone_activated.connect(func(index: int): rig.activated.append(index))
	rig.controller.strike_incoming.connect(func(index: int, id: int, members: Array, _rect: Rect2):
		rig.incoming.append({"zone": index, "id": id, "members": members, "locked": rig.manager.pieces[id].is_locked}))
	rig.controller.strike_landed.connect(func(index: int, id: int, moved: Array): rig.landed.append({"zone": index, "id": id, "moved": moved}))
	return rig

func _zone(kind: int, column: int, row: int, width: int, height: int) -> PowerZone:
	return PowerZone.make(8, 6, column, row, width, height, kind)

# Drops pieces a little off their true spots and lets them snap, like a player would.
func _place(m: PuzzleManager, ids: Array, offset: Vector2) -> void:
	for id in ids:
		m.request_place_from_bank(id, m.pieces[id].correct_position + offset)
	for id in ids:
		m.request_pickup(id)
		m.request_release(id)

func _top(m: PuzzleManager) -> void:
	_place(m, [0, 1, 2, 3, 4, 5, 6, 7], Vector2(14, -9))

func _locked_groups(m: PuzzleManager) -> int:
	var count := 0
	for key in m.clusters:
		if m.pieces[m.clusters[key][0]].is_locked:
			count += 1
	return count

func _run() -> void:
	_test_strike_table()
	_test_layouts()
	_test_zone_rules()
	_test_charging()
	_test_lightning_strikes()
	_test_magnet()
	_test_chain()
	_test_save_and_load()
	_test_authority()
	print("power zone test done, failures: ", failures)
	for child in root.get_children():
		child.free()
	quit(1 if failures > 0 else 0)

# --- Lightning rewards ---

func _test_strike_table() -> void:
	var expected := {1: 1, 2: 2, 3: 2, 4: 3, 6: 3, 7: 5, 11: 5, 12: 7, 19: 7, 20: 9, 29: 9, 30: 10, 40: 10}
	for area in expected:
		_check(PowerZone.strikes_for_area(area) == expected[area], "a %d-cell Lightning zone strikes %d times" % [area, expected[area]])
	var previous := 0
	for area in range(1, 45):
		var strikes := PowerZone.strikes_for_area(area)
		_check(strikes >= previous, "strikes never fall as the zone grows (%d cells)" % area)
		previous = strikes

# --- layouts ---

func _test_layouts() -> void:
	var grids := [Vector2i(4, 6), Vector2i(6, 4), Vector2i(8, 6), Vector2i(8, 12), Vector2i(12, 9), Vector2i(10, 25), Vector2i(18, 14)]
	for grid in grids:
		var total: int = grid.x * grid.y
		var small_count := 0
		var big_count := 0
		var touching_total := 0
		var region_total := 0
		var kinds_seen := {}
		var worst_share := 0.0
		for seed_value in range(1, 31):
			var rng := RandomNumberGenerator.new()
			rng.seed = seed_value
			var zones := PowerLayout.generate(grid.x, grid.y, rng)
			var owner := {}
			var covered := 0
			var cells_by_kind := [0, 0]
			for zone in zones:
				_check(zone.column >= 0 and zone.row >= 0 and zone.column + zone.width <= grid.x and zone.row + zone.height <= grid.y, "every zone fits the %s grid" % [grid])
				_check(zone.state == PowerZone.State.IDLE, "a new zone is idle")
				for id in zone.cell_ids():
					_check(not owner.has(id), "zones never overlap (%s grid, seed %d)" % [grid, seed_value])
					owner[id] = zone
				covered += zone.area()
				cells_by_kind[zone.kind] += zone.area()
				kinds_seen[zone.kind] = true
				small_count += 1 if zone.area() <= 2 else 0
				big_count += 1 if zone.area() >= 9 else 0
			var share := float(covered) / total
			# about 60%; a very small board needs more of its cells to keep every side covered
			var top := 0.66 if total >= 200 else (0.70 if total >= 96 else 0.80)
			_check(share >= 0.52 and share <= top, "about 60%% of the %s grid is powered (seed %d: %.2f)" % [grid, seed_value, share])
			# and spread: no sparse region, no side of the board without powers, no big dead area
			var regions := PowerLayout.region_coverage(zones, grid.x, grid.y)
			var sides := PowerLayout.side_coverage(zones, grid.x, grid.y)
			_check(regions.min() >= 0.38, "no part of the %s board is left sparse (seed %d: worst region %.2f)" % [grid, seed_value, regions.min()])
			_check(sides.min() >= 0.38, "every side of the %s board has powers (seed %d: worst side %.2f)" % [grid, seed_value, sides.min()])
			var empty := PowerLayout.largest_empty_rectangle(zones, grid.x, grid.y)
			_check(empty <= maxi(4, int(total * 0.09)), "no big dead area on the %s board (seed %d: %d empty cells in a rectangle)" % [grid, seed_value, empty])
			region_total += zones.size()
			# zones that touch: neighbouring cells belonging to two different zones
			var touching := {}
			for id in owner:
				for neighbor in [id + 1 if id % grid.x < grid.x - 1 else -1, id + grid.x]:
					if owner.has(neighbor) and owner[neighbor] != owner[id]:
						touching[[owner[id].cell_ids()[0], owner[neighbor].cell_ids()[0]]] = true
			touching_total += touching.size()
			if total >= 48:
				worst_share = maxf(worst_share, float(maxi(cells_by_kind[0], cells_by_kind[1])) / maxf(1.0, cells_by_kind[0] + cells_by_kind[1]))
			if total >= 100:
				var large := zones.filter(func(z): return z.area() >= 12).size()
				_check(large >= 2, "a %s puzzle always has at least two large zones (seed %d: %d)" % [grid, seed_value, large])
			if total >= 200:
				_check(zones.filter(func(z): return z.area() >= 16).size() >= 1, "a %s puzzle always has a 4x4-sized zone (seed %d)" % [grid, seed_value])
				_check(zones.size() >= 18 and zones.size() <= 55, "a %s puzzle has a few dozen regions (seed %d: %d)" % [grid, seed_value, zones.size()])
		_check(small_count > big_count, "small zones outnumber big ones on the %s grid (%d vs %d)" % [grid, small_count, big_count])
		_check(kinds_seen.size() == 2, "both Lightning and Magnet appear on the %s grid" % [grid])
		if total >= 100:
			_check(touching_total / 30.0 >= 6.0, "zones touch each other on the %s grid (%.1f pairs per board)" % [grid, touching_total / 30.0])
		if total >= 48:
			_check(worst_share <= 0.75, "neither kind takes over the %s grid (worst share %.2f)" % [grid, worst_share])
	# the same seed always gives the same board
	var a := RandomNumberGenerator.new()
	var b := RandomNumberGenerator.new()
	a.seed = 99
	b.seed = 99
	_check(PowerZone.list_to_data(PowerLayout.generate(12, 9, a)) == PowerZone.list_to_data(PowerLayout.generate(12, 9, b)), "a seed always makes the same layout")
	# the mix of sizes on a big puzzle: plenty of tiny zones, and some of every larger size class
	var sizes := {}
	for seed_value in range(1, 21):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		for zone in PowerLayout.generate(18, 14, rng):
			var key := mini(zone.area(), 16)
			sizes[key] = int(sizes.get(key, 0)) + 1
	_check(sizes.get(1, 0) > 0 and sizes.get(2, 0) > 0 and sizes.get(4, 0) > 0 and sizes.get(6, 0) > 0 and sizes.get(9, 0) > 0 and sizes.get(12, 0) > 0 and sizes.get(16, 0) > 0, "every size class from 1x1 to 4x4 turns up on a 252-piece board")
	_check(sizes.get(1, 0) > sizes.get(9, 0) and sizes.get(2, 0) + sizes.get(1, 0) > sizes.get(12, 0) * 3, "tiny zones are common, big ones rare")

# --- the zone itself ---

func _test_zone_rules() -> void:
	var zone := _zone(PowerZone.Kind.MAGNET, 2, 1, 2, 2)
	_check(zone.cell_ids() == [10, 11, 18, 19], "cells are where expected")
	var perimeter := zone.perimeter_ids()
	perimeter.sort()
	_check(perimeter == [2, 3, 9, 12, 17, 20, 26, 27], "the perimeter is the cells touching the edge, not the diagonals")
	var corner := _zone(PowerZone.Kind.MAGNET, 0, 0, 1, 1)
	var corner_perimeter := corner.perimeter_ids()
	corner_perimeter.sort()
	_check(corner_perimeter == [1, 8], "a corner zone has two neighbours")
	_check(_zone(PowerZone.Kind.MAGNET, 3, 2, 1, 1).perimeter_ids().size() == 4, "a 1x1 zone has four neighbours")
	_check(_zone(PowerZone.Kind.MAGNET, 1, 1, 3, 3).perimeter_ids().size() == 12, "a bigger zone has a longer edge")
	_check(PowerZone.from_dict({"kind": 0, "column": 7, "row": 0, "width": 2, "height": 1}, 8, 6) == null, "a zone that does not fit the grid is rejected")
	_check(PowerZone.from_dict({"kind": 5, "column": 0, "row": 0, "width": 1, "height": 1}, 8, 6) == null, "an unknown kind is rejected")
	var overlapping := PowerZone.list_from([_zone(0, 0, 0, 2, 2).to_dict(), _zone(1, 1, 1, 2, 2).to_dict(), _zone(1, 2, 0, 1, 1).to_dict()], 8, 6)
	_check(overlapping.size() == 2 and overlapping[1].column == 2, "an overlapping zone in saved data is dropped, a touching one kept")
	_check(PowerZone.list_from("junk", 8, 6).is_empty() and PowerZone.list_from([5, "x", {}], 8, 6).is_empty(), "damaged zone data is ignored")

# --- charging ---

func _test_charging() -> void:
	# A 2x2 zone away from the edge: pieces 27, 28, 35, 36.
	var sitting := _rig([_zone(PowerZone.Kind.LIGHTNING, 3, 3, 2, 2)])
	_place(sitting.manager, [27, 28, 35, 36], Vector2.ZERO)
	_top(sitting.manager)
	_check(sitting.manager.locked_count() == 8 and sitting.manager.cluster_members(27).size() == 4, "the zone pieces form a free group beside a main puzzle that does not reach them")
	_check(not sitting.session.power_zones[0].is_charged(sitting.manager) and sitting.controller.check_charge() == 0, "pieces merely sitting over a zone do not charge it")
	_check(sitting.session.power_zones[0].state == PowerZone.State.IDLE and sitting.landed.is_empty(), "nothing fired")
	var zone := _zone(PowerZone.Kind.LIGHTNING, 3, 3, 2, 2)
	var rig := _rig([zone], 2)
	var m := rig.manager
	_place(m, [27, 28, 35], Vector2.ZERO)
	_top(m)
	_check(rig.controller.check_charge() == 0, "a main puzzle that does not reach the zone does not charge it")
	_place(m, [11, 19], Vector2(11, 7)) # reaches the zone's three pieces and takes them in
	_check(m.pieces[27].is_locked and m.pieces[28].is_locked and m.pieces[35].is_locked and not m.pieces[36].is_on_table, "three of the four zone cells are now in the main puzzle")
	_check(not zone.is_charged(m) and rig.controller.check_charge() == 0 and zone.state == PowerZone.State.IDLE, "a partly connected zone does not charge")
	_check(rig.landed.is_empty(), "no strike yet")
	_place(m, [36], Vector2(8, 6)) # the last cell
	_check(zone.state == PowerZone.State.DONE, "completing the zone fires it")
	_check(rig.landed.size() == 3 and rig.activated == [0], "a four-cell Lightning zone strikes three times, once")
	var strikes_before := rig.landed.size()
	_check(rig.controller.check_charge() == 0 and not rig.controller.activate(zone), "a used zone cannot be charged again")
	m.group_locked.emit(0, [0], ["TOP"])
	_check(rig.landed.size() == strikes_before and rig.activated == [0], "further locks do not fire it again")
	# a single cell corner zone fires as soon as its corner anchors
	var corner := _rig([_zone(PowerZone.Kind.LIGHTNING, 0, 0, 1, 1)], 3)
	_place(corner.manager, [0], Vector2(9, 6))
	_check(corner.session.power_zones[0].state == PowerZone.State.DONE and corner.landed.size() == 1, "a 1x1 Lightning zone strikes once the moment its piece joins the main puzzle")

# --- Lightning ---

func _test_lightning_strikes() -> void:
	# More work, more strikes: each zone area gets its own count (cells locked directly to avoid building the board).
	for area_case in [[1, 1, 1], [2, 1, 2], [2, 2, 3], [3, 2, 3], [3, 3, 5], [4, 3, 7]]:
		var w: int = area_case[0]
		var h: int = area_case[1]
		var zone := _zone(PowerZone.Kind.LIGHTNING, 0, 0, w, h)
		var rig := _rig([zone], 4)
		for id in zone.cell_ids():
			rig.manager.request_place_from_bank(id, rig.manager.pieces[id].correct_position)
			rig.manager.pieces[id].is_locked = true
		_check(rig.controller.check_charge() == 1, "the %dx%d zone charges" % [w, h])
		_check(rig.landed.size() == area_case[2], "a %dx%d Lightning zone strikes %d times (got %d)" % [w, h, area_case[2], rig.landed.size()])
		for strike in rig.incoming:
			_check(not strike.locked, "a strike was aimed at an unfinished place")
	# a strike on a loose piece, one still in the bank, and a group a player built
	var rig := _rig([], 5)
	var m := rig.manager
	_top(m)
	var moved := m.strike_piece(9)
	_check(moved == [9] and m.pieces[9].is_locked and m.pieces[9].current_position == m.pieces[9].correct_position and m.pieces[9].current_rotation == 0, "a struck bank piece lands exactly in place and joins the main puzzle")
	m.request_place_from_bank(10, Vector2(2200, 1500))
	m.pieces[10].current_rotation = 270
	moved = m.strike_piece(10)
	_check(moved == [10] and m.pieces[10].is_locked and m.pieces[10].current_rotation == 0, "a loose turned piece is straightened and placed")
	_check(m.strike_piece(3).is_empty(), "pieces already in the main puzzle are not struck")
	_place(m, [12, 13, 20], Vector2(900, 700))
	m.request_rotate(12)
	m.request_rotate(12)
	var group: Array = m.cluster_members(12).duplicate()
	moved = m.strike_piece(13)
	moved.sort()
	_check(moved == group, "striking one piece of a group moves the whole group")
	var target := m.pieces[13]
	for id in group:
		var piece: PuzzlePieceState = m.pieces[id]
		_check(piece.is_locked and piece.current_position == piece.correct_position and piece.current_rotation == 0, "group member %d ends in place and upright" % id)
		_check((piece.current_position - target.current_position).is_equal_approx(piece.correct_position - target.correct_position), "member %d sits right relative to the struck piece" % id)
	_check(m.is_joined_side(12, 1) and m.is_joined_side(12, 2) and _locked_groups(m) == 1, "the group's joins survived and it joined the main puzzle as one")
	# the jackpot, through the controller: with the loose piece held, the only place to strike is the group
	var jackpot := _rig([_zone(PowerZone.Kind.LIGHTNING, 0, 0, 1, 1)], 6)
	var jm := jackpot.manager
	_place(jm, [1, 9, 17], Vector2(1200, 300)) # joined group directly beside the corner
	_check(jm.cluster_members(1).size() == 3, "the three-piece group is joined")
	jm.request_place_from_bank(8, Vector2(1800, 900))
	jm.request_pickup(8, 5) # a player is holding the other candidate
	_place(jm, [0], Vector2(9, 6))
	_check(jackpot.landed.size() == 1 and jackpot.landed[0].moved.size() == 3, "a 1x1 Lightning can grab a whole three-piece group")
	for id in [1, 9, 17]:
		_check(jm.pieces[id].is_locked and jm.pieces[id].current_position == jm.pieces[id].correct_position, "group member %d was carried into the main puzzle" % id)
	_check(not jm.pieces[8].is_locked, "the held piece was left alone")
	# targets are only places beside the main puzzle, and never a held group
	var t := _rig([], 7)
	_top(t.manager)
	var targets := t.manager.lightning_targets()
	_check(not targets.is_empty() and targets.has(8) and not targets.has(0) and not targets.has(30), "targets are the places beside the main puzzle")

# --- Magnet ---

func _test_magnet() -> void:
	var zone := _zone(PowerZone.Kind.MAGNET, 2, 1, 2, 2)
	var rig := _rig([zone], 8)
	var m := rig.manager
	_top(m)
	_place(m, [10, 11, 18], Vector2(12, 8))
	_check(zone.state == PowerZone.State.IDLE, "one unfinished zone cell prevents the Magnet")
	# two perimeter cells share one remote group; one is held; one starts in the bank
	_place(m, [12, 20, 21], Vector2(900, 700))
	m.request_rotate(12)
	var group: Array = m.cluster_members(12).duplicate()
	m.request_place_from_bank(26, Vector2(1800, 900))
	m.request_place_from_bank(9, Vector2(1850, 200))
	m.request_pickup(9, 5)
	m.request_place_from_bank(27, Vector2(1900, 300))
	m.request_pickup(27, 6)
	_check(not m.pieces[17].is_on_table, "a perimeter target starts in the bank")
	_place(m, [19], Vector2(12, 8))
	_check(zone.state == PowerZone.State.DONE and rig.activated == [0], "the last zone cell fires the Magnet, once")
	var pulled := []
	for entry in rig.incoming:
		pulled.append(entry.id)
	_check(pulled.size() == 3 and pulled.has(12) and pulled.has(17) and pulled.has(26), "each eligible perimeter group is pulled once")
	_check(not pulled.has(9) and not pulled.has(27) and not pulled.has(2) and not pulled.has(3), "held groups and pieces already in the main puzzle are ignored")
	for id in group:
		_check(m.pieces[id].is_locked and m.pieces[id].current_position == m.pieces[id].correct_position and m.pieces[id].current_rotation == 0, "the whole pulled group was aligned and locked")
	_check(m.is_joined_side(12, 2) and m.is_joined_side(20, 1), "the group's joins survive")
	_check(m.pieces[17].is_locked and m.pieces[26].is_locked, "a bank piece and a loose piece were pulled home")
	_check(not m.pieces[28].is_on_table and not m.pieces[29].is_on_table, "what was pulled in does not extend the reach")
	_check(not m.pieces[9].is_locked and not m.pieces[27].is_locked, "held groups remain untouched")
	# a bigger Magnet has a bigger edge, so a bigger payoff
	var small := _rig([_zone(PowerZone.Kind.MAGNET, 3, 2, 1, 1)], 9)
	var large := _rig([_zone(PowerZone.Kind.MAGNET, 2, 2, 3, 3)], 9)
	for pair in [[small, 4], [large, 12]]:
		var r: Rig = pair[0]
		for id in r.session.power_zones[0].cell_ids():
			r.manager.request_place_from_bank(id, r.manager.pieces[id].correct_position)
			r.manager.pieces[id].is_locked = true
		r.controller.check_charge()
		_check(r.landed.size() == pair[1], "a Magnet pulls one piece per edge cell (%d expected, got %d)" % [pair[1], r.landed.size()])

# --- chaining ---

func _test_chain() -> void:
	# A staircase of one-cell zones, each pulling in the neighbour that charges the next:
	# Magnet 0 -> Magnet 8 -> Magnet 9 -> Magnet 17, and Lightning 16 beside them.
	var zones := [
		_zone(PowerZone.Kind.MAGNET, 0, 0, 1, 1),
		_zone(PowerZone.Kind.MAGNET, 0, 1, 1, 1),
		_zone(PowerZone.Kind.MAGNET, 1, 1, 1, 1),
		_zone(PowerZone.Kind.MAGNET, 1, 2, 1, 1),
		_zone(PowerZone.Kind.LIGHTNING, 0, 2, 1, 1),
	]
	var rig := _rig(zones, 10)
	var m := rig.manager
	_place(m, [0], Vector2(9, 6)) # the only thing the player does
	for zone in zones:
		_check(zone.state == PowerZone.State.DONE, "zone at cell %d fired in the chain" % zone.cell_ids()[0])
	var counts := {}
	for index in rig.activated:
		counts[index] = int(counts.get(index, 0)) + 1
	_check(counts.size() == 5 and counts.values().all(func(c): return c == 1), "every zone in the chain fired exactly once")
	_check(rig.activated[0] == 0 and rig.activated[1] == 1, "the chain runs in order, starting with the zone the player completed")
	for id in [1, 8, 9, 10, 16, 17, 18, 25]:
		_check(m.pieces[id].is_locked, "piece %d was drawn into the main puzzle by the chain" % id)
	_check(_locked_groups(m) == 1, "everything the chain placed is one main puzzle")
	# a zone charged mid-chain by a different kind: Lightning then Magnet then Lightning
	var mixed := [
		_zone(PowerZone.Kind.LIGHTNING, 0, 0, 1, 1),
		_zone(PowerZone.Kind.MAGNET, 1, 0, 1, 1),
	]
	var mix := _rig(mixed, 11)
	_place(mix.manager, [0], Vector2(9, 6)) # the Lightning's one strike lands somewhere; only the Magnet's own cell matters
	_check(mixed[0].state == PowerZone.State.DONE, "the Lightning fired")
	if mix.manager.pieces[1].is_locked:
		_check(mixed[1].state == PowerZone.State.DONE, "...and when it happened to fill the Magnet's cell, the Magnet followed")
	else:
		_check(mixed[1].state == PowerZone.State.IDLE, "...and when it did not, the Magnet waits")

# --- saving ---

func _test_save_and_load() -> void:
	SaveManager.save_dir = "user://test_saves_power"
	var network := NetworkSession.new()
	root.add_child(network)
	var manager := PuzzleManager.new()
	var session := PuzzleSession.new()
	session.setup(manager, network)
	root.add_child(session)
	network.configure(manager, Callable(session, "puzzle_config"))
	session.random_rotation = false
	session.size_index = 1
	session.start_puzzle(false)
	var original := PowerZone.list_to_data(session.power_zones)
	_check(session.power_zones.size() >= 5, "a new puzzle gets a layout of zones")
	for zone in session.power_zones:
		_check(zone.columns == session.columns and zone.rows == session.rows, "zones belong to the puzzle's own grid")
	session.save_slot = "power_test"
	session.write_save()
	var reloaded := PuzzleSession.new()
	reloaded.setup(PuzzleManager.new(), network)
	root.add_child(reloaded)
	_check(reloaded.load_session("power_test") and PowerZone.list_to_data(reloaded.power_zones) == original, "every zone comes back exactly: kind, place, size")
	# states survive: one done, one queued
	session.power_zones[0].state = PowerZone.State.DONE
	session.power_zones[1].state = PowerZone.State.QUEUED
	session.write_save()
	var again := PuzzleSession.new()
	again.setup(PuzzleManager.new(), network)
	root.add_child(again)
	_check(again.load_session("power_test") and again.power_zones[0].state == PowerZone.State.DONE and again.power_zones[1].state == PowerZone.State.QUEUED, "used and waiting zones are remembered")
	# A zone that was charged but had not finished its turn finishes it on load -- and a finished one never fires again.
	var fired := _rig([_zone(PowerZone.Kind.LIGHTNING, 0, 0, 1, 1), _zone(PowerZone.Kind.LIGHTNING, 2, 0, 1, 1)], 12)
	_place(fired.manager, [0, 1, 2, 3, 4, 5, 6, 7], Vector2(14, -9))
	_check(fired.landed.size() == 2, "both corner-row zones fired")
	fired.session.power_zones[0].state = PowerZone.State.DONE
	fired.session.power_zones[1].state = PowerZone.State.QUEUED # the game was closed mid-turn
	fired.session.save_slot = "power_test_queue"
	fired.session.random_rotation = false
	fired.session.size_index = 1
	fired.session.write_save()
	var resumed := PuzzleSession.new()
	var rm := PuzzleManager.new()
	var rn := NetworkSession.new()
	root.add_child(rn)
	rn.configure(rm, Callable(resumed, "puzzle_config"))
	resumed.setup(rm, rn)
	root.add_child(resumed)
	var controller := PowerController.new()
	root.add_child(controller)
	controller.setup(resumed, rm, rn)
	controller.make_instant()
	var landed := []
	controller.strike_landed.connect(func(index: int, id: int, _moved: Array): landed.append(index))
	var activated := []
	controller.zone_activated.connect(func(index: int): activated.append(index))
	_check(resumed.load_session("power_test_queue"), "the queue save loads")
	_check(activated == [1] and resumed.power_zones[1].state == PowerZone.State.DONE, "a zone that was waiting its turn finishes it when the game is loaded")
	_check(resumed.power_zones[0].state == PowerZone.State.DONE and not activated.has(0), "a zone that had finished does not fire again")
	var before := landed.size()
	controller.check_charge()
	_check(landed.size() == before, "nothing fires twice")
	# saves from when a puzzle had one Lightning and one Magnet zone keep their markings
	var legacy := session.puzzle_config()
	legacy.erase("zones")
	legacy["lightning"] = {"column": 1, "row": 1, "width": 2, "height": 2, "tier": 0, "strikes": 3, "activated": true}
	legacy["magnet"] = {"column": 4, "row": 2, "width": 2, "height": 2, "activated": false}
	legacy["pieces"] = []
	for piece in session.manager.pieces:
		legacy["pieces"].append(piece.snapshot())
	var old := PuzzleSession.new()
	old.setup(PuzzleManager.new(), network)
	root.add_child(old)
	old.restore_puzzle(legacy)
	_check(old.power_zones.size() == 2 and old.power_zones[0].kind == PowerZone.Kind.LIGHTNING and old.power_zones[0].state == PowerZone.State.DONE and old.power_zones[1].kind == PowerZone.Kind.MAGNET and old.power_zones[1].state == PowerZone.State.IDLE, "a save with one Lightning and one Magnet zone is converted")
	legacy.erase("lightning")
	legacy.erase("magnet")
	old.restore_puzzle(legacy)
	_check(old.power_zones.is_empty(), "a save from before zones loads without any")
	SaveManager.delete_slot("power_test")
	SaveManager.delete_slot("power_test_queue")

# --- authority ---

func _test_authority() -> void:
	var zone := _zone(PowerZone.Kind.LIGHTNING, 0, 0, 2, 2)
	var rig := _rig([zone], 13)
	var m := rig.manager
	# A client's own copy of the puzzle snaps and locks pieces like anyone's, so a zone is completed
	# right there on the client.
	rig.network.mode = NetworkSession.Mode.CLIENT
	_top(m)
	_place(m, [8, 9], Vector2(11, 7))
	_check(zone.is_charged(m), "the client's copy of the zone is complete")
	_check(zone.state == PowerZone.State.IDLE and rig.activated.is_empty() and rig.incoming.is_empty() and rig.landed.is_empty(), "completing a zone on a client does not fire it")
	_check(not rig.controller.has_authority() and rig.controller.pick_target() == -1, "a client never picks a strike target")
	_check(rig.controller.check_charge() == 0 and not rig.controller.activate(zone) and zone.state == PowerZone.State.IDLE, "a client never charges a zone")
	var magnet := _zone(PowerZone.Kind.MAGNET, 0, 0, 2, 2)
	_check(rig.controller.capture_targets(magnet).is_empty(), "a client never chooses Magnet targets")
	var snapshot := []
	for piece in m.pieces:
		snapshot.append(piece.snapshot())
	_check(rig.controller.apply_strike(20).is_empty(), "a client never moves pieces for a power")
	rig.network.announce_zone_strike(0, 20, [20])
	rig.network.announce_zone_activated(0)
	rig.network.broadcast_power_result(20)
	var after := []
	for piece in m.pieces:
		after.append(piece.snapshot())
	_check(after == snapshot, "nothing on a client changed")
	var config: Dictionary = rig.network.get_script().get_rpc_config()
	for name in ["_sync_zone_strike", "_sync_zone_activated"]:
		_check(config.has(name) and int(config[name].rpc_mode) == MultiplayerAPI.RPC_MODE_AUTHORITY, "%s can only be sent by the host" % name)
	# What the host announces is shown on a client, without the client choosing anything.
	rig.network.zone_strike_received.emit(0, 20, [20])
	_check(rig.incoming == [{"zone": 0, "id": 20, "members": [20], "locked": false}], "a client shows the strike the host announced")
	rig.network.zone_activated_received.emit(0)
	_check(rig.activated == [0] and zone.state == PowerZone.State.DONE, "a client shows the activation the host announced and marks the zone used")
	rig.network.zone_activated_received.emit(99)
	rig.network.zone_strike_received.emit(99, 20, [20])
	_check(rig.activated == [0] and rig.incoming.size() == 1, "announcements for a zone that does not exist are ignored")
	rig.network.mode = NetworkSession.Mode.SOLO
