extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("SCORING TEST FAILED: " + message)

class Rig extends RefCounted:
	var manager := PuzzleManager.new()
	var network := NetworkSession.new()
	var session := PuzzleSession.new()
	var awards := []
	var connections := []

func _rig(seed_value: int = 52813) -> Rig:
	var rig := Rig.new()
	var source: Texture2D = load("res://assets/emberbound.png")
	var board := Vector2(1122, 1402)
	rig.manager.configure(PuzzleGenerator.generate(source, 8, 6, seed_value, board, false), Vector2(board.x / 8, board.y / 6), 8, 6)
	root.add_child(rig.network)
	root.add_child(rig.session)
	rig.session.seed_value = seed_value
	rig.session.columns = 8
	rig.session.rows = 6
	rig.session.setup(rig.manager, rig.network)
	rig.network.configure(rig.manager, Callable(rig.session, "puzzle_config"))
	var awards: Array = rig.awards
	var connections: Array = rig.connections
	rig.session.scoring.awarded.connect(func(event: Dictionary): awards.append(event))
	rig.manager.main_puzzle_connected.connect(func(ids: Array, source: int): connections.append([ids, source]))
	return rig

func _place(m: PuzzleManager, ids: Array, offset: Vector2) -> void:
	for id in ids:
		m.request_place_from_bank(id, m.pieces[id].correct_position + offset)
	for id in ids:
		m.request_pickup(id)
		m.request_release(id)

func _top(m: PuzzleManager) -> void:
	_place(m, [0, 1, 2, 3, 4, 5, 6, 7], Vector2(14, -9))

func _run() -> void:
	await _test_manual_combo_and_failures()
	_test_power_jackpots()
	_test_opening_anchors_and_pulse()
	_test_charge_overflow_and_save()
	_test_audio_and_hud()
	print("scoring test done, failures: ", failures)
	for child in root.get_children():
		child.free()
	quit(1 if failures > 0 else 0)

func _test_manual_combo_and_failures() -> void:
	var rig := _rig()
	_top(rig.manager)
	_check(rig.awards.size() == 1 and int(rig.awards[0].piece_count) == 8 and rig.session.scoring.score == 1550, "first full border produces one 8-piece main-puzzle award")
	rig.session.scoring.reset()
	rig.awards.clear()
	rig.connections.clear()
	var m := rig.manager
	_place(m, [8], Vector2(11, 7))
	_check(rig.awards.size() == 1 and rig.awards[0].piece_ids == [8] and int(rig.awards[0].score_gain) == 100, "a single manual attachment scores 100 once")
	_check(rig.session.scoring.charge == 5 and rig.session.scoring.combo_progress == 1, "single attachment gives full Charge and combo progress")
	_place(m, [9, 10, 11, 17, 18, 19], Vector2(900, 650))
	_check(rig.awards.size() > 1 and m.cluster_members(9).size() == 6 and rig.session.scoring.score > 100, "building a disconnected cluster scores before it reaches the board")
	for event in rig.awards.slice(1):
		_check(event.kind == "LOOSE" and event.charge_gain > 0, "floating joins grant Score and Charge")
	var loose_score := rig.session.scoring.score
	m.request_release(9)
	_check(rig.session.scoring.score == loose_score, "releasing an already joined loose cluster gives no repeat award")
	rig.session.scoring.from_dict({"score": 100, "charge": 5, "combo_progress": 1, "awarded_ids": [8]})
	rig.awards.clear()
	m.request_pickup(9)
	m.request_move(9, m.pieces[9].correct_position + Vector2(10, 6))
	m.request_release(9)
	_check(rig.awards.size() == 1 and rig.connections.size() == 2 and rig.awards[0].piece_count == 6 and rig.awards[0].piece_ids.size() == 6, "six newly attached pieces form one board event")
	_check(rig.awards[0].score_gain == 900 and rig.awards[0].charge_gain == 15 and rig.session.scoring.score == 1000, "6-piece board bonus and full manual Charge are correct")
	_check(rig.session.scoring.combo_progress == 4 and rig.session.scoring.tier() == RunScoring.Tier.WARM, "cluster progress reaches WARM")
	var before := rig.session.scoring.to_dict()
	_check(rig.session.scoring.award_connection([9, 10, 11], PuzzleManager.ConnectionSource.MANUAL).is_empty() and rig.session.scoring.to_dict() == before, "an already awarded piece cannot score twice")
	_place(m, [12], Vector2(11, 7))
	_check(rig.awards.back().score_gain == 125 and rig.awards.back().charge_gain == 6, "WARM applies 1.25 score and 1.1 Charge multipliers")
	_place(m, [13], Vector2(11, 7))
	_check(rig.session.scoring.tier() == RunScoring.Tier.HOT, "progress six reaches HOT")
	_place(m, [14], Vector2(11, 7))
	_check(rig.awards.back().score_gain == 150 and rig.awards.back().charge_gain == 6, "HOT applies 1.5 score and 1.2 Charge multipliers")
	var progress_before_wait := rig.session.scoring.combo_progress
	await create_timer(0.15).timeout
	_check(rig.session.scoring.combo_progress == progress_before_wait, "waiting does not decay combo")
	for id in [15, 16, 24]:
		_place(m, [id], Vector2(11, 7))
	_check(rig.session.scoring.tier() == RunScoring.Tier.ON_FIRE, "progress ten reaches ON FIRE")
	_place(m, [32], Vector2(11, 7))
	_check(rig.awards.back().score_gain == 200 and rig.awards.back().charge_gain == 7, "ON FIRE applies 2x score and 1.35x Charge")
	var count_before := rig.awards.size()
	var progress_before := rig.session.scoring.combo_progress
	m.request_place_from_bank(22, m.pieces[22].correct_position + Vector2(m.cell_size.x * 0.28, 0))
	m.request_release(22, 0, false)
	_check(rig.session.scoring.combo_progress == progress_before, "a non-attempt release does not punish combo")
	m.request_release(22)
	_check(rig.awards.size() == count_before and rig.session.scoring.combo_progress == progress_before - 1, "a clear failed placement near the main puzzle reduces combo once")
	m.request_move(22, Vector2(2400, 1600))
	m.request_release(22)
	_check(rig.session.scoring.combo_progress == progress_before - 1, "ordinary organization away from the target does not lose combo")
	var loose := _rig(122)
	loose.session.scoring.from_dict({"combo_progress": 3})
	loose.manager.request_place_from_bank(0, Vector2(1800, 700))
	loose.manager.request_place_from_bank(1, Vector2(1800, 700) + loose.manager.pieces[1].correct_position - loose.manager.pieces[0].correct_position)
	loose.manager.request_rotate(1)
	loose.manager.request_release(1)
	_check(loose.session.scoring.combo_progress == 2, "a wrong-orientation attempt beside a loose correct neighbor reduces combo")

func _test_power_jackpots() -> void:
	var lightning_rig := _rig(117)
	_top(lightning_rig.manager)
	_place(lightning_rig.manager, [12, 13, 20, 21, 28, 29], Vector2(950, 620))
	lightning_rig.session.scoring.reset()
	lightning_rig.awards.clear()
	var lightning := LightningController.new()
	root.add_child(lightning)
	lightning.setup(lightning_rig.session, lightning_rig.manager, lightning_rig.network)
	lightning_rig.session.lightning_zone = LightningZone.make(8, 6, 0, 0, 2, 2, 1)
	var moved := lightning.apply_strike(13)
	_check(moved.size() == 6 and lightning_rig.awards.size() == 1, "Lightning moves six joined pieces in one scoring event")
	_check(lightning_rig.awards[0].source == PuzzleManager.ConnectionSource.POWER and lightning_rig.awards[0].score_gain == 900 and lightning_rig.awards[0].charge_gain == 8, "Lightning jackpot gets full score and half Charge")
	_check(lightning_rig.session.scoring.combo_progress == 3 and lightning_rig.manager.is_joined_side(12, 1), "Lightning jackpot raises combo and preserves joins")
	var magnet_rig := _rig(118)
	magnet_rig.session.magnet_zone = MagnetZone.make(8, 6, 0, 0, 2, 2)
	var magnet := MagnetController.new()
	root.add_child(magnet)
	magnet.setup(magnet_rig.session, magnet_rig.manager, magnet_rig.network)
	magnet.charge_delay = 0.0
	magnet.pull_delay = 0.0
	magnet.pull_gap = 0.0
	_top(magnet_rig.manager)
	_place(magnet_rig.manager, [10, 18, 19, 26, 27, 28], Vector2(1000, 600))
	magnet_rig.session.scoring.reset()
	magnet_rig.awards.clear()
	_place(magnet_rig.manager, [8, 9], Vector2(11, 7))
	var magnet_jackpots := []
	for event in magnet_rig.awards:
		if event.source == PuzzleManager.ConnectionSource.POWER and event.piece_count == 6:
			magnet_jackpots.append(event)
	_check(magnet_rig.session.magnet_zone.activated and magnet_jackpots.size() == 1, "Magnet pulls a shared-perimeter cluster and awards it once")
	if not magnet_jackpots.is_empty():
		var jackpot: Dictionary = magnet_jackpots[0]
		var tier_before := int(jackpot.combo_before)
		_check(jackpot.score_gain == roundi(900.0 * RunScoring.SCORE_MULTIPLIERS[tier_before]) and jackpot.charge_gain == roundi(15.0 * RunScoring.CHARGE_MULTIPLIERS[tier_before] * 0.5), "Magnet jackpot gets full score and half Charge at the active combo tier")
	_check(magnet_rig.manager.is_joined_side(10, 2), "Magnet jackpot keeps the cluster joins")

func _test_opening_anchors_and_pulse() -> void:
	var rig := _rig(130)
	var m := rig.manager
	var milestone_count := [0]
	rig.session.scoring.anchors_completed.connect(func(): milestone_count[0] += 1)
	for id in [0, 7, 40, 47]:
		_place(m, [id], Vector2(7, 4))
	_check(m.anchored_corner_count() == 4 and milestone_count[0] == 1, "four separate corner anchors trigger one milestone")
	_check(rig.session.scoring.power_charges == 1 and rig.session.scoring.anchors_rewarded, "all corners anchored grants one stored Power Charge")
	var corner_score := rig.session.scoring.score
	m.request_release(47)
	_check(rig.session.scoring.score == corner_score and rig.session.scoring.power_charges == 1, "corner milestone and score never repeat")
	var ids := m.edge_pulse_targets()
	_check(ids.size() == 6 and ids.has(1) and ids.has(6) and ids.has(8), "Edge Pulse prioritizes missing border pieces next to anchors")
	var board := PuzzleBoard.new()
	board.setup(m, rig.session, rig.network)
	root.add_child(board)
	var bank := PieceBank.new()
	root.add_child(bank)
	bank.configure(m.pieces, rig.session.source, rig.session.seed_value)
	var pulse := EdgePulseController.new()
	pulse.setup(m, rig.session.scoring, rig.network, board, bank)
	root.add_child(pulse)
	var table_before := m.table_count()
	_check(pulse.activate() and rig.session.scoring.power_charges == 0 and m.table_count() == table_before, "Edge Pulse spends one charge and never places pieces")
	_check(board.pulse_ids.has(1) and bank.pulse_ids.has(1) and bank.filter_name == "EDGES", "Edge Pulse reveals useful pieces in the bank and on the table")
	_check(not pulse.activate() and rig.session.scoring.power_charges == 0, "Edge Pulse cannot spend when no Power Charge remains")
	pulse.clear()
	_check(board.pulse_ids.is_empty() and bank.pulse_ids.is_empty(), "Edge Pulse highlight clears")
	var saved := rig.session.scoring.to_dict()
	rig.session.scoring.from_dict(saved)
	_check(rig.session.scoring.to_dict() == saved and rig.session.scoring.power_charges == 0, "anchor milestone and spent charges persist")

func _test_charge_overflow_and_save() -> void:
	var rig := _rig(119)
	_top(rig.manager)
	_place(rig.manager, [8, 9, 16, 17], Vector2(970, 570))
	rig.session.scoring.from_dict({"charge": 92})
	rig.manager.request_pickup(8)
	rig.manager.request_move(8, rig.manager.pieces[8].correct_position + Vector2(11, 7))
	rig.manager.request_release(8)
	_check(rig.session.scoring.power_charges == 1 and rig.session.scoring.charge == 7 and rig.awards.back().charges_gained == 1, "overflow creates a stored Power Charge and keeps seven")
	var huge := _rig(120)
	var source: Texture2D = load("res://assets/emberbound.png")
	var board := Vector2(1122, 1402)
	huge.manager.configure(PuzzleGenerator.generate(source, 10, 25, 120, board, false), Vector2(board.x / 10, board.y / 25), 10, 25)
	huge.session.scoring.from_dict({"charge": 90, "combo_progress": 10})
	var all := []
	for piece in huge.manager.pieces:
		piece.is_locked = true
		all.append(piece.piece_id)
	var jackpot := huge.session.scoring.award_connection(all, PuzzleManager.ConnectionSource.MANUAL)
	_check(jackpot.charges_gained >= 2 and huge.session.scoring.charge < 100, "one giant event can create multiple stored charges")
	SaveManager.save_dir = "user://test_saves_scoring"
	rig.session.save_slot = "scoring_test"
	rig.session.write_save()
	var saved_state := rig.session.scoring.to_dict()
	var loaded := PuzzleSession.new()
	var loaded_manager := PuzzleManager.new()
	root.add_child(loaded)
	loaded.setup(loaded_manager, rig.network)
	_check(loaded.load_session("scoring_test") and loaded.scoring.to_dict() == saved_state, "score, Charge, stored charges, combo and awarded IDs survive save/load")
	var score_before := loaded.scoring.score
	_check(loaded.scoring.award_connection([8, 9], PuzzleManager.ConnectionSource.MANUAL).is_empty() and loaded.scoring.score == score_before, "loading cannot re-award earlier connections")
	var legacy := rig.session.puzzle_config()
	legacy.erase("scoring")
	legacy["pieces"] = []
	for piece in rig.manager.pieces:
		legacy.pieces.append(piece.snapshot())
	var old := PuzzleSession.new()
	root.add_child(old)
	old.setup(PuzzleManager.new(), rig.network)
	old.restore_puzzle(legacy)
	_check(old.scoring.score == 0 and old.scoring.charge == 0 and old.scoring.power_charges == 0 and old.scoring.combo_progress == 0, "older saves initialize scoring safely")
	SaveManager.delete_slot("scoring_test")

func _test_audio_and_hud() -> void:
	_check(Sfx.reward_kind(0, 1) == "small" and Sfx.reward_kind(1, 1) == "medium" and Sfx.reward_kind(2, 1) == "large" and Sfx.reward_kind(3, 1) == "large" and Sfx.reward_kind(3, 12) == "huge", "combo and event size choose different existing snap timbres")
	var rig := _rig(121)
	var view := RunScoreView.new()
	view.setup(rig.session.scoring, rig.manager, rig.session)
	root.add_child(view)
	_check(view.score_label.text.contains("0") and view.charge_label.text.contains("0 / 100") and view.stored_label.text.contains("0"), "the compact HUD shows score, Charge and stored charges")
	rig.manager.pieces[0].is_locked = true
	rig.manager.piece_changed.emit(0)
	_check(view.anchors_label.text.contains("1/4"), "anchor progress updates when a client receives a locked corner snapshot")
	rig.session.scoring.from_dict({"score": 1350, "charge": 18, "power_charges": 1, "combo_progress": 6})
	_check(view.score_label.text.contains("1,350") and view.combo_label.text.contains("HOT") and view.charge_label.text.contains("18 / 100") and view.stored_label.text.contains("1"), "the HUD updates from authoritative scoring state")
	view._on_awarded({"piece_ids": [0, 1, 2, 3, 4, 5], "piece_count": 6, "source": PuzzleManager.ConnectionSource.POWER, "score_gain": 1350, "charge_gain": 18, "charges_gained": 2})
	_check(view._toasts.size() == 2 and view._toasts[0].text.contains("6 PIECE JOIN") and view._toasts[0].text.contains("+1,350") and view._toasts[1].text.contains("POWER CHARGED! ×2"), "cluster and multi-charge visual feedback is readable")
	rig.session.size_index = 1
	rig.session.start_puzzle(false)
	_check(rig.session.scoring.score == 0 and rig.session.scoring.charge == 0 and rig.session.scoring.power_charges == 0 and rig.session.scoring.combo_progress == 0 and view.combo_label.text == "NORMAL" and view._toasts.is_empty(), "a new puzzle resets scoring, HUD and short notices")
