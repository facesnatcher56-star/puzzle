extends SceneTree

# Cluster Surge and the ability bar: which neighbours a Surge can pull, how they are brought onto a group
# wherever it sits (and onto the main puzzle), what it costs, that it can chain into board zones, the ability bar's
# slots, hotkeys and targeting, and the thin HUD layout around them.

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("CLUSTER SURGE TEST FAILED: " + message)

class Rig extends RefCounted:
	var manager := PuzzleManager.new()
	var network := NetworkSession.new()
	var session := PuzzleSession.new()
	var surge := ClusterSurgeController.new()
	var powers := PowerController.new()
	var started := []
	var pulls := []
	var landed := []
	var awards := []

func _rig(seed_value: int = 1, charges: int = 1) -> Rig:
	var rig := Rig.new()
	var source: Texture2D = load("res://assets/emberbound.png")
	var board := Vector2(1122, 1402)
	rig.manager.configure(PuzzleGenerator.generate(source, 8, 6, seed_value, board, false), Vector2(board.x / 8, board.y / 6), 8, 6)
	root.add_child(rig.network)
	root.add_child(rig.session)
	rig.network.configure(rig.manager, Callable(rig.session, "puzzle_config"))
	rig.session.setup(rig.manager, rig.network)
	rig.session.columns = 8
	rig.session.rows = 6
	rig.session.scoring.from_dict({"power_charges": charges})
	root.add_child(rig.surge)
	rig.surge.setup(rig.session, rig.manager, rig.network, rig.session.scoring)
	rig.surge.make_instant()
	rig.surge.rng.seed = seed_value
	root.add_child(rig.powers)
	rig.powers.setup(rig.session, rig.manager, rig.network)
	rig.powers.make_instant()
	rig.surge.surge_started.connect(func(id: int, members: Array): rig.started.append([id, members]))
	rig.surge.pull_incoming.connect(func(anchor: int, id: int, members: Array): rig.pulls.append([anchor, id, members]))
	rig.surge.pull_landed.connect(func(anchor: int, id: int, moved: Array): rig.landed.append([anchor, id, moved]))
	rig.session.scoring.awarded.connect(func(event: Dictionary): rig.awards.append(event))
	return rig

func _place(m: PuzzleManager, ids: Array, offset: Vector2) -> void:
	for id in ids:
		m.request_place_from_bank(id, m.pieces[id].correct_position + offset)
	for id in ids:
		m.request_pickup(id)
		m.request_release(id)

func _top(m: PuzzleManager) -> void:
	_place(m, [0, 1, 2, 3, 4, 5, 6, 7], Vector2(14, -9))

# True if every member of `ids` sits exactly where the group's geometry says, relative to the first one.
func _rigid(m: PuzzleManager, ids: Array) -> bool:
	var base: PuzzlePieceState = m.pieces[ids[0]]
	var angle := deg_to_rad(base.current_rotation)
	for id in ids:
		var piece: PuzzlePieceState = m.pieces[id]
		if piece.current_rotation != base.current_rotation:
			return false
		var wanted := (base.current_position + base.piece_size * 0.5) + ((piece.correct_position + piece.piece_size * 0.5) - (base.correct_position + base.piece_size * 0.5)).rotated(angle)
		if not (piece.current_position + piece.piece_size * 0.5).is_equal_approx(wanted):
			return false
	return true

func _run() -> void:
	_test_targets()
	_test_pulling_onto_a_loose_group()
	_test_pulling_onto_the_main_puzzle()
	_test_controller()
	_test_chain()
	_test_ability_bar()
	await _test_in_the_game()
	print("cluster surge test done, failures: ", failures)
	for child in root.get_children():
		child.free()
	quit(1 if failures > 0 else 0)

# --- who can be pulled ---

func _test_targets() -> void:
	var rig := _rig()
	var m := rig.manager
	_place(m, [9], Vector2(1000, 500)) # a loose piece; 1, 8, 10 and 17 are its neighbours, all in the bank
	var targets := m.surge_targets(9)
	var ids := []
	for t in targets:
		ids.append(t.piece)
	ids.sort()
	_check(ids == [1, 8, 10, 17], "a loose piece's four neighbours are the targets")
	_check(m.surge_targets(30).is_empty(), "a piece that is not on the table has no targets")
	# a neighbour that is itself part of a group counts once, however many pieces touch
	_place(m, [8, 16], Vector2(1500, 900))
	_place(m, [10, 11], Vector2(1500, -500))
	m.request_pickup(10, 5) # held by someone
	ids.clear()
	for t in m.surge_targets(9):
		ids.append(t.piece)
	ids.sort()
	_check(ids == [1, 8, 17], "a held group is not a target")
	m.request_release(10, 5)
	_check(m.surge_targets(9).size() == 4 and m.surge_seams(9).size() == 4, "...until it is released; every target has a seam to preview")
	for seam in m.surge_seams(9):
		_check(seam.size() >= 2, "a seam is a polyline")
	# pieces already in the main puzzle are never targets
	var main := _rig()
	_top(main.manager)
	var below := []
	for t in main.manager.surge_targets(3):
		below.append(t.piece)
	below.sort()
	_check(below == [8, 9, 10, 11, 12, 13, 14, 15], "an anchored group's targets are the unfinished neighbours all along its exposed edge")

# --- a loose group grows where it sits ---

func _test_pulling_onto_a_loose_group() -> void:
	var rig := _rig(2)
	var m := rig.manager
	_place(m, [9, 10], Vector2(700, 500))
	m.request_rotate(9) # turned a quarter turn
	_check(m.pieces[9].current_rotation == 90 and m.cluster_members(9).size() == 2, "the loose pair is joined and turned")
	# a neighbour from the bank
	var moved := m.pull_to_group(17, 9)
	_check(moved == [17] and m.pieces[17].is_on_table and m.pieces[17].cluster_id == m.pieces[9].cluster_id, "a bank piece joins the group")
	_check(m.pieces[17].current_rotation == 90 and _rigid(m, m.cluster_members(9)), "it takes the group's turn and sits exactly beside it")
	# a neighbour that is part of another group, turned the other way: the whole group follows
	_place(m, [1, 2], Vector2(-1200, 700))
	m.request_rotate(1)
	m.request_rotate(1)
	var neighbour_group: Array = m.cluster_members(1).duplicate()
	moved = m.pull_to_group(1, 9)
	moved.sort()
	_check(moved == neighbour_group, "the neighbour's whole group is pulled")
	var group: Array = m.cluster_members(9)
	_check(group.size() == 5 and group.has(1) and group.has(2), "and joins as one")
	_check(_rigid(m, group), "every piece in the grown group sits exactly in place")
	_check(m.is_joined_side(9, 2) and m.is_joined_side(1, 1) and m.is_joined_side(9, 1), "the joins inside the pulled group survived")
	_check(not m.pieces[9].is_locked, "a loose group stays loose")
	_check(m.pull_to_group(1, 9).is_empty() and m.pull_to_group(30, 9).is_empty(), "something already joined, or not a neighbour, is refused")

# --- the main puzzle grows ---

func _test_pulling_onto_the_main_puzzle() -> void:
	var rig := _rig(3)
	var m := rig.manager
	_top(m)
	_place(m, [11, 19], Vector2(900, 600)) # a loose group below piece 3, turned
	m.request_rotate(11)
	var moved := m.pull_to_group(11, 3)
	moved.sort()
	_check(moved == [11, 19], "the loose neighbour group is pulled")
	for id in [11, 19]:
		_check(m.pieces[id].is_locked and m.pieces[id].current_position == m.pieces[id].correct_position and m.pieces[id].current_rotation == 0, "piece %d joined the main puzzle at its true place" % id)

# --- the controller ---

func _test_controller() -> void:
	var rig := _rig(4)
	var m := rig.manager
	_place(m, [9], Vector2(900, 500))
	_check(rig.surge.can_use(9) and rig.session.scoring.power_charges == 1, "a Surge is available with a Power Charge")
	_check(rig.surge.activate(9), "the Surge fires")
	_check(rig.session.scoring.power_charges == 0, "it costs exactly one Power Charge")
	_check(rig.started.size() == 1 and rig.pulls.size() == 3 and rig.landed.size() == 3, "it pulls three neighbours (of four possible)")
	_check(m.cluster_members(9).size() == 4 and _rigid(m, m.cluster_members(9)), "the group grew to four joined pieces, rigidly")
	var sources := rig.awards.filter(func(e): return e.source == PuzzleManager.ConnectionSource.POWER)
	_check(not sources.is_empty(), "the pulled joins are scored as power joins")
	var before := m.cluster_members(9).size()
	_check(not rig.surge.activate(9) and not rig.surge.can_use(9), "with no Power Charge nothing happens")
	_check(m.cluster_members(9).size() == before, "...and nothing moves")
	# Not allowed: not on the table, held by somebody else, nothing to pull
	var rig2 := _rig(5)
	_check(not rig2.surge.activate(9) and rig2.session.scoring.power_charges == 1, "a piece in the bank cannot be the target, and nothing is spent")
	_place(rig2.manager, [9], Vector2(900, 500))
	rig2.manager.request_pickup(9, 7)
	rig2.session.scoring.ledger(7).power_charges = 1 # player 7 has a charge of their own
	_check(not rig2.surge.can_use(9, 3) and rig2.surge.can_use(9, 7), "another player's held group is off limits; its holder (with a charge of their own) may use it")
	rig2.manager.request_release(9, 7)
	# fewer than three neighbours: a corner piece has two, and the surge pulls exactly those
	var rig3 := _rig(6)
	_place(rig3.manager, [0], Vector2(9, 6)) # the corner anchors at once
	_check(rig3.manager.pieces[0].is_locked and rig3.surge.activate(0), "a Surge works on an anchored corner")
	_check(rig3.pulls.size() == 2 and rig3.manager.pieces[1].is_locked and rig3.manager.pieces[8].is_locked, "a corner has two neighbours, and both are pulled")
	# a surge that finishes everything around: no targets, nothing spent
	var rig4 := _rig(7)
	_check(not rig4.surge.activate(0), "a piece that is not on the table cannot start a Surge")
	# the host decides: a client cannot spend
	var rig5 := _rig(8)
	_place(rig5.manager, [9], Vector2(900, 500))
	rig5.network.mode = NetworkSession.Mode.CLIENT
	_check(not rig5.surge.has_authority() and not rig5.surge.activate(9), "a client cannot activate a Surge itself")
	_check(rig5.session.scoring.power_charges == 1 and rig5.pulls.is_empty(), "...and nothing was spent or moved")
	var config: Dictionary = rig5.network.get_script().get_rpc_config()
	for name in ["_sync_surge_started", "_sync_surge_pull"]:
		_check(config.has(name) and int(config[name].rpc_mode) == MultiplayerAPI.RPC_MODE_AUTHORITY, "%s can only be sent by the host" % name)
	_check(config.has("_rpc_request_surge") and int(config["_rpc_request_surge"].rpc_mode) == MultiplayerAPI.RPC_MODE_ANY_PEER, "a client may ask the host")
	rig5.network.surge_started_received.emit(9, [9])
	rig5.network.surge_pull_received.emit(9, 17, [17])
	_check(rig5.started == [[9, [9]]] and rig5.pulls == [[9, 17, [17]]], "a client shows what the host announced")
	rig5.network.mode = NetworkSession.Mode.SOLO

# --- chaining into board zones ---

func _test_chain() -> void:
	# A Surge on the anchored corner pulls its two neighbours; piece 1 completes a Magnet zone, which fires and
	# pulls in the cells around it.
	var rig := _rig(9)
	var zone := PowerZone.make(8, 6, 1, 0, 1, 1, PowerZone.Kind.MAGNET)
	rig.session.power_zones = [zone]
	_place(rig.manager, [0], Vector2(9, 6)) # the corner anchors at once
	_check(rig.manager.pieces[0].is_locked and zone.state == PowerZone.State.IDLE, "the Magnet waits for its cell")
	_check(rig.surge.activate(0), "the Surge fires on the anchored corner")
	_check(rig.manager.pieces[1].is_locked and zone.state == PowerZone.State.DONE, "the piece it pulled completed the Magnet zone, which fired")
	for id in [2, 9]:
		_check(rig.manager.pieces[id].is_locked, "the Magnet carried the chain on to piece %d" % id)

# --- the ability bar ---

func _test_ability_bar() -> void:
	var bar := AbilityBar.new()
	root.add_child(bar)
	var selected := [-1]
	var usable := [true]
	bar.selection = func(): return selected[0]
	bar.can_use = func(_id: String, _piece: int): return usable[0]
	var requests := []
	var previews := []
	var targeting := []
	bar.ability_requested.connect(func(id: String, piece: int): requests.append([id, piece]))
	bar.preview_changed.connect(func(id: String, piece: int): previews.append([id, piece]))
	bar.targeting_changed.connect(func(active: bool): targeting.append(active))
	_check(bar.slots.size() == 4 and bar.rotate_button != null, "four ability slots and a rotate button")
	_check(bar.tooltip_for(0).contains("Cluster Surge") and bar.tooltip_for(0).contains("1 Power Charge") and bar.tooltip_for(2).contains("Locked"), "slots have short tooltips")
	# can't afford it
	bar.trigger_slot(0)
	_check(requests.is_empty() and not bar.is_targeting(), "without a Power Charge pressing 1 does nothing")
	bar.set_power_charges(1)
	# nothing selected: targeting mode, then a click on a group uses it
	bar.trigger_slot(0)
	_check(bar.is_targeting() and targeting == [true], "with nothing selected, 1 starts targeting")
	_check(bar.cancel_targeting() and not bar.is_targeting() and targeting == [true, false] and not bar.cancel_targeting(), "Esc cancels targeting")
	bar.trigger_slot(0)
	_check(bar.complete_targeting(-1) and not bar.is_targeting() and requests.is_empty(), "clicking empty table cancels targeting")
	bar.trigger_slot(0)
	_check(bar.complete_targeting(12) and requests == [["cluster_surge", 12]] and not bar.is_targeting(), "clicking a group uses the power on it")
	requests.clear()
	# a selected group: used at once
	selected[0] = 5
	bar.trigger_slot(0)
	_check(requests == [["cluster_surge", 5]], "with a group selected, 1 uses the power on it at once")
	requests.clear()
	usable[0] = false
	bar.trigger_slot(0)
	_check(requests.is_empty(), "a group with nothing to pull does not use it")
	usable[0] = true
	# locked slots
	for i in [1, 2, 3]:
		bar.trigger_slot(i)
	_check(requests.is_empty() and not bar.is_targeting(), "slots 2-4 are not unlocked yet")
	# hover / hold previews the selection, and only when affordable
	previews.clear()
	bar._slot_hover(bar.slots[0], true)
	bar._slot_hover(bar.slots[0], false)
	_check(previews == [["cluster_surge", 5], ["cluster_surge", -1]], "hovering the slot previews the selected group's seams, leaving clears them")
	bar.set_power_charges(0)
	previews.clear()
	bar._slot_hover(bar.slots[0], true)
	_check(previews == [["cluster_surge", -1]], "no preview when it cannot be afforded")
	# a click on the slot itself
	bar.set_power_charges(1)
	bar._slot_pressed(bar.slots[0])
	_check(requests == [["cluster_surge", 5]], "clicking the slot uses the power")
	var turned := [0]
	bar.rotate_requested.connect(func(): turned[0] += 1)
	bar._slot_pressed(bar.rotate_button)
	_check(turned[0] == 1, "the rotate button asks for a rotation")
	_check(bar.slots[0].size.x >= 56 and bar.slots[0].custom_minimum_size.y >= 56, "slots are big enough to tap")

# --- in the real game screen ---

func _key(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	root.push_input(event, true)
	event = InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = false
	root.push_input(event, true)

func _click(position: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.global_position = position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)

func _test_in_the_game() -> void:
	var game: Node2D = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.lobby.hide_menu()
	game.session.size_index = 1
	game.session.random_rotation = false
	game.session.start_puzzle(false)
	game.session.power_zones.clear() # nothing but the Surge happens on this table
	game.surge.make_instant()
	await process_frame
	await process_frame
	# the screen: a thin strip on top, the ability bar sitting just above the bank
	_check(game.hud.size.x > 0 and GameHud.HEIGHT <= 40.0, "the top strip is thin")
	_check(game.ability_bar.get_global_rect().end.y <= game.bank.position.y + 0.5 and game.ability_bar.get_global_rect().position.y > GameHud.HEIGHT, "the ability bar sits just above the piece bank")
	game.bank.set_height(260.0)
	await process_frame
	_check(game.ability_bar.get_global_rect().end.y <= game.bank.position.y + 0.5, "...and follows the bank when it is resized")
	game.bank.set_height(178.0)
	await process_frame
	var m: PuzzleManager = game.manager
	# select a loose piece with a Power Charge, press 1
	_place(m, [14], Vector2(1000, 400))
	game.board.select(14)
	game.session.scoring.from_dict({"power_charges": 1, "revision": 1})
	var table_before := m.table_count()
	_key(KEY_1)
	_check(game.session.scoring.power_charges == 0 and m.table_count() == table_before + 3, "pressing 1 with a group selected uses Cluster Surge on it (spent a charge, three pieces pulled in)")
	# nothing selected: 1 starts targeting, Esc cancels, 1 again then a click on a group fires
	game.board.select(-1)
	game.session.scoring.from_dict({"power_charges": 1, "revision": 2})
	_key(KEY_1)
	_check(game.ability_bar.is_targeting(), "pressing 1 with nothing selected starts targeting")
	_key(KEY_ESCAPE)
	_check(not game.ability_bar.is_targeting() and not game.lobby.is_open(), "Esc cancels targeting without opening the pause menu")
	_key(KEY_1)
	var target := 14
	var screen: Vector2 = game.get_viewport().get_canvas_transform() * (m.pieces[target].current_position + m.pieces[target].piece_size * 0.5)
	var neighbours_before: int = m.surge_targets(target).size()
	var table_now := m.table_count()
	_click(screen)
	_check(game.session.scoring.power_charges == 0 and not game.ability_bar.is_targeting() and (neighbours_before == 0 or m.table_count() > table_now or m.cluster_members(target).size() > 4), "clicking a group while targeting uses the power on it")
	# a locked (anchored) section can be selected for a Surge
	game.session.start_puzzle(false)
	game.session.power_zones.clear()
	await process_frame
	_place(game.manager, [0], Vector2(9, 6))
	var corner_screen: Vector2 = game.get_viewport().get_canvas_transform() * (game.manager.pieces[0].correct_position + game.manager.pieces[0].piece_size * 0.5)
	_click(corner_screen)
	_check(game.board.selected_id == 0 and game.manager.pieces[0].is_locked, "clicking the anchored section selects it, so a power can be aimed at the main puzzle")
	# a group that joins the main puzzle is not left selected (no highlight to click away), and the locked
	# main puzzle itself is never outlined
	game.session.start_puzzle(false)
	game.session.power_zones.clear()
	await process_frame
	_place(game.manager, [1], Vector2(2, 1)) # a loose piece sitting right where it belongs, next to the empty corner
	game.board.select(1)
	_check(game.board.selected_id == 1 and game.board.views[1].selected, "a loose group is selected and outlined")
	_place(game.manager, [0], Vector2(9, 6)) # the corner anchors and takes piece 1 in
	_check(game.manager.pieces[1].is_locked and game.board.selected_id == -1 and not game.board.views[1].selected, "once it joins the main puzzle the selection clears itself")
	game.board.select(0)
	_check(game.board.selected_id == 0 and not game.board.views[0].selected and not game.board.views[1].selected, "the main puzzle can still be selected as a target, but is never outlined")
	# the HUD: objective until the corners are down, flame and diamonds on the strip
	_check(game.hud.objective_label.visible and game.hud.objective_label.text.contains("1/4"), "the corner objective shows progress")
	# the strip and the bank header are slim
	_check(not game.bank.buttons.has("filter:TRAY 1") or game.bank.buttons["filter:EDGES"].text == "EDGE", "the bank filters are short: EDGE, CORNER")
	_check(game.bank.tools_menu.item_count == 5, "the bank's tools sit behind one menu: Reference, Spread, Move to Tray, Restart, New")
	# the old controls are gone from the top
	for name in ["size_picker", "rotation_button", "top_hint", "leave_button", "title_label", "edge_pulse"]:
		_check(not (name in game), "%s is no longer part of the main screen" % name)
