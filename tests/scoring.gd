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
	await _test_first_try_streak()
	_test_players_are_separate()
	_test_power_jackpots()
	_test_opening_anchors_and_pulse()
	_test_charge_overflow_and_save()
	_test_audio_and_hud()
	print("scoring test done, failures: ", failures)
	for child in root.get_children():
		child.free()
	quit(1 if failures > 0 else 0)

func _test_first_try_streak() -> void:
	var rig := _rig()
	var m := rig.manager
	var scoring := rig.session.scoring
	# no multiplier before any streak
	_check(RunScoring.streak_multiplier(0) == 1.0 and is_equal_approx(RunScoring.streak_multiplier(1), 1.12) and is_equal_approx(RunScoring.streak_multiplier(10), pow(1.12, 10)), "the multiplier is exponential in the streak")
	_check(is_equal_approx(RunScoring.streak_multiplier(5) / RunScoring.streak_multiplier(4), RunScoring.streak_multiplier(9) / RunScoring.streak_multiplier(8)) and RunScoring.streak_multiplier(80) == RunScoring.STREAK_CAP, "...growing by the same factor each step, up to a cap")
	_check(RunScoring.tier_for(2) == RunScoring.Tier.NORMAL and RunScoring.tier_for(3) == RunScoring.Tier.WARM and RunScoring.tier_for(6) == RunScoring.Tier.HOT and RunScoring.tier_for(10) == RunScoring.Tier.ON_FIRE, "streak length sets the flame tier")
	# a solo piece anchored on its corner, dropped where it belongs, is a first-try placement
	_place(m, [0], Vector2(9, 6))
	_check(scoring.streak == 1 and rig.awards.size() == 1 and rig.awards[0].first_try and rig.awards[0].score_gain == roundi(100.0 * RunScoring.streak_multiplier(1)), "a first-try placement starts the streak and is paid at the new multiplier")
	_place(m, [1], Vector2(11, 7))
	_check(scoring.streak == 2 and rig.awards.back().score_gain == roundi(100.0 * RunScoring.streak_multiplier(2)) and rig.awards.back().first_try, "the next first-try placement is worth more")
	_place(m, [2], Vector2(11, 7))
	_check(scoring.streak == 3 and scoring.tier() == RunScoring.Tier.WARM and rig.awards.back().streak == 3, "three in a row reaches WARM")
	# rotating a piece and dropping it in the open, as often as you like, keeps the streak and the chance
	var score_before := scoring.score
	m.request_place_from_bank(9, Vector2(2300, 1700))
	for drop in range(4):
		m.request_pickup(9)
		m.request_rotate(9)
		m.request_move(9, Vector2(1800 + drop * 160, 1500 - drop * 120))
		m.request_release(9)
	_check(scoring.streak == 3 and not m.pieces[9].attempted and scoring.score == score_before, "rotating and dropping a piece away from the others costs nothing")
	await create_timer(0.15).timeout
	_check(scoring.streak == 3, "waiting does not end the streak")
	m.request_pickup(9)
	while m.pieces[9].current_rotation != 0:
		m.request_rotate(9)
	m.request_move(9, m.pieces[9].correct_position + Vector2(10, 6))
	m.request_release(9)
	_check(m.pieces[9].is_locked and scoring.streak == 4 and rig.awards.back().first_try, "...and it still counts as a first-try placement when it goes in")
	# dropped beside another piece without joining: the streak ends, but nothing is taken away
	score_before = scoring.score
	m.request_place_from_bank(3, m.pieces[3].correct_position + Vector2(11, 7))
	m.request_pickup(3)
	m.request_rotate(3) # the wrong way up, right beside the border
	m.request_release(3)
	_check(not m.pieces[3].is_locked and m.pieces[3].attempted, "a piece dropped near another one without joining has had its attempt")
	_check(scoring.streak == 0 and scoring.score == score_before and scoring.best_streak == 4, "the streak ends, the score is untouched, and the best streak is remembered")
	# its later join earns the normal score and does not restart the streak
	m.request_pickup(3)
	while m.pieces[3].current_rotation != 0:
		m.request_rotate(3)
	m.request_move(3, m.pieces[3].correct_position + Vector2(11, 7))
	m.request_release(3)
	_check(m.pieces[3].is_locked and scoring.streak == 0 and not rig.awards.back().first_try and rig.awards.back().score_gain == 100, "a piece that has had an attempt joins for the plain score and no streak")
	# the next fresh piece starts a new streak
	_place(m, [4], Vector2(11, 7))
	_check(scoring.streak == 1 and rig.awards.back().first_try, "a fresh piece starts the streak again")
	# a release that was not a deliberate placement is no attempt at all
	m.request_place_from_bank(12, m.pieces[12].correct_position + Vector2(m.cell_size.x * 0.28, 0))
	m.request_pickup(12)
	m.request_release(12, 0, false)
	_check(not m.pieces[12].attempted and scoring.streak == 1, "letting go without really placing is not an attempt")
	# moving a joined group never touches the streak, even beside other pieces
	_place(m, [20, 21], Vector2(1500, 900))
	var group_streak := scoring.streak
	m.request_pickup(20)
	m.request_move(20, m.pieces[20].correct_position + Vector2(m.cell_size.x * 0.4, 0))
	m.request_release(20)
	_check(scoring.streak == group_streak, "dropping a joined group near others without joining does not end the streak")
	# powers neither extend nor end it, and are still paid at the current multiplier
	scoring.from_dict({"streak": 5, "best_streak": 5, "score": 0})
	var strike_awards := rig.awards.size()
	m.strike_piece(10)
	_check(scoring.streak == 5 and rig.awards.size() > strike_awards and not rig.awards.back().first_try and rig.awards.back().source == PuzzleManager.ConnectionSource.POWER, "a power's join leaves the streak alone")
	_check(rig.awards.back().score_gain == roundi(100.0 * RunScoring.streak_multiplier(5)), "...but is paid at the streak's multiplier")
	# nothing in scoring ever goes down
	var previous := scoring.score
	for id in [30, 31, 32]:
		m.request_place_from_bank(id, Vector2(1600 + id * 5, 1000))
		m.request_pickup(id)
		m.request_release(id)
		_check(scoring.score >= previous, "the score never falls")
		previous = scoring.score
	# attempts are part of the saved state
	var snap: Dictionary = m.pieces[3].snapshot()
	_check(bool(snap.attempted), "a piece's attempt is saved")
	var other := _rig(124)
	other.manager.pieces[3].apply_snapshot(snap)
	_check(other.manager.pieces[3].attempted, "...and restored")

# Each player has their own Charge, Power Charges and streak; only the Score is shared.
func _test_players_are_separate() -> void:
	var rig := _rig(140)
	var m := rig.manager
	var scoring := rig.session.scoring
	var drop := func(id: int, player: int, offset: Vector2) -> void:
		m.request_place_from_bank(id, m.pieces[id].correct_position + offset)
		m.request_pickup(id, player)
		m.request_release(id, player)
	drop.call(0, 5, Vector2(9, 6)) # player 5 anchors the corner first try
	_check(scoring.ledger(5).streak == 1 and scoring.ledger(RunScoring.HOST_KEY).streak == 0 and scoring.streak == 0, "a player's first-try placement builds only their own streak")
	_check(rig.awards.back().player == 5 and rig.awards.back().score_gain == roundi(100.0 * RunScoring.streak_multiplier(1)), "the award names the player and uses their own multiplier")
	_check(scoring.ledger(5).charge == 5 and scoring.ledger(RunScoring.HOST_KEY).charge == 0 and scoring.ledger(6).charge == 0, "...and only their own Charge")
	var score_after_five := scoring.score
	drop.call(1, 6, Vector2(11, 7)) # player 6 places the next piece
	_check(scoring.ledger(6).streak == 1 and scoring.ledger(5).streak == 1, "another player's placement does not extend your streak")
	_check(rig.awards.back().score_gain == roundi(100.0 * RunScoring.streak_multiplier(1)) and scoring.score == score_after_five + rig.awards.back().score_gain, "...but the score is everyone's")
	drop.call(2, 5, Vector2(11, 7))
	_check(scoring.ledger(5).streak == 2 and scoring.ledger(6).streak == 1 and rig.awards.back().score_gain == roundi(100.0 * RunScoring.streak_multiplier(2)), "each player is paid at their own multiplier")
	# player 6 drops a piece beside the border wrong way up: their streak ends, player 5's does not
	m.request_place_from_bank(3, m.pieces[3].correct_position + Vector2(11, 7))
	m.request_pickup(3, 6)
	m.request_rotate(3)
	var before := scoring.score
	m.request_release(3, 6)
	_check(scoring.ledger(6).streak == 0 and scoring.ledger(5).streak == 2 and scoring.score == before, "one player's miss ends only their own streak, and takes nothing from the score")
	# spending is per player
	scoring.ledger(5).power_charges = 1
	_check(not scoring.spend_power_charge(6) and scoring.spend_power_charge(5) and scoring.ledger(5).power_charges == 0, "a Power Charge can only be spent by its owner")
	# only the host's (or a solo player's) buildup is saved; other players start empty after a reload
	scoring.ledger(RunScoring.HOST_KEY).streak = 3
	var saved := scoring.to_dict()
	_check(int(saved.streak) == 3 and not saved.has("ledgers"), "the save holds the host's own buildup and nobody else's")
	scoring.from_dict(saved)
	_check(scoring.ledger(RunScoring.HOST_KEY).streak == 3 and scoring.ledger(5).streak == 0, "after a reload other players start from nothing")
	scoring.from_dict(saved, false)
	_check(scoring.streak == 0 and scoring.score == int(saved.score), "a joining player takes the shared score but not the host's buildup")
	# a power's awards go to the player whose action set it off
	var powers_rig := _rig(141)
	powers_rig.session.power_zones = [PowerZone.make(8, 6, 0, 0, 1, 1, PowerZone.Kind.LIGHTNING)]
	var powers := PowerController.new()
	root.add_child(powers)
	powers.setup(powers_rig.session, powers_rig.manager, powers_rig.network)
	powers.make_instant()
	var pm := powers_rig.manager
	pm.request_place_from_bank(0, pm.pieces[0].correct_position + Vector2(9, 6))
	pm.request_pickup(0, 7)
	pm.request_release(0, 7)
	var power_awards := powers_rig.awards.filter(func(e): return e.source == PuzzleManager.ConnectionSource.POWER)
	_check(not power_awards.is_empty() and power_awards.all(func(e): return e.player == 7), "a board power's awards go to the player who charged it")
	_check(powers_rig.session.scoring.ledger(7).charge > 5 and powers_rig.session.scoring.ledger(RunScoring.HOST_KEY).charge == 0, "...building that player's Charge")
	# a Surge is credited to the player who used it
	var surge_rig := _rig(142)
	var surge := ClusterSurgeController.new()
	root.add_child(surge)
	surge.setup(surge_rig.session, surge_rig.manager, surge_rig.network, surge_rig.session.scoring)
	surge.make_instant()
	var sm := surge_rig.manager
	sm.request_place_from_bank(9, sm.pieces[9].correct_position + Vector2(800, 400))
	surge_rig.session.scoring.ledger(8).power_charges = 1
	_check(not surge.activate(9, 3), "a player with no charge of their own cannot start a Surge")
	_check(surge.activate(9, 8) and surge_rig.session.scoring.ledger(8).power_charges == 0, "the Surge spends the requesting player's own charge")
	var surge_awards := surge_rig.awards.filter(func(e): return e.source == PuzzleManager.ConnectionSource.POWER)
	_check(not surge_awards.is_empty() and surge_awards.all(func(e): return e.player == 8) and surge_rig.session.scoring.ledger(8).charge > 0 and surge_rig.session.scoring.ledger(RunScoring.HOST_KEY).charge == 0, "...and its pulls build that player's Charge")

func _test_power_jackpots() -> void:
	var lightning_rig := _rig(117)
	_top(lightning_rig.manager)
	_place(lightning_rig.manager, [12, 13, 20, 21, 28, 29], Vector2(950, 620))
	lightning_rig.session.scoring.reset()
	lightning_rig.awards.clear()
	var lightning := PowerController.new()
	root.add_child(lightning)
	lightning.setup(lightning_rig.session, lightning_rig.manager, lightning_rig.network)
	lightning.make_instant()
	var moved := lightning.apply_strike(13)
	_check(moved.size() == 6 and lightning_rig.awards.size() == 1, "Lightning moves six joined pieces in one scoring event")
	_check(lightning_rig.awards[0].source == PuzzleManager.ConnectionSource.POWER and lightning_rig.awards[0].score_gain == 900 and lightning_rig.awards[0].charge_gain == 8, "Lightning jackpot gets full score and half Charge")
	_check(lightning_rig.session.scoring.streak == 0 and lightning_rig.manager.is_joined_side(12, 1), "Lightning jackpot leaves the streak alone and preserves joins")
	var magnet_rig := _rig(118)
	var magnet_zone := PowerZone.make(8, 6, 0, 0, 2, 2, PowerZone.Kind.MAGNET)
	magnet_rig.session.power_zones = [magnet_zone]
	var magnet := PowerController.new()
	root.add_child(magnet)
	magnet.setup(magnet_rig.session, magnet_rig.manager, magnet_rig.network)
	magnet.make_instant()
	_top(magnet_rig.manager)
	_place(magnet_rig.manager, [10, 18, 19, 26, 27, 28], Vector2(1000, 600))
	magnet_rig.session.scoring.reset()
	magnet_rig.awards.clear()
	_place(magnet_rig.manager, [8, 9], Vector2(11, 7))
	var magnet_jackpots := []
	for event in magnet_rig.awards:
		if event.source == PuzzleManager.ConnectionSource.POWER and event.piece_count == 6:
			magnet_jackpots.append(event)
	_check(magnet_zone.state == PowerZone.State.DONE and magnet_jackpots.size() == 1, "Magnet pulls a shared-perimeter cluster and awards it once")
	if not magnet_jackpots.is_empty():
		var jackpot: Dictionary = magnet_jackpots[0]
		_check(jackpot.score_gain == roundi(900.0 * float(jackpot.multiplier)) and jackpot.charge_gain == roundi(15.0 * RunScoring.CHARGE_MULTIPLIERS[int(jackpot.combo_after)] * 0.5), "Magnet jackpot gets full score at the streak's multiplier and half Charge at the active tier")
	_check(magnet_rig.manager.is_joined_side(10, 2), "Magnet jackpot keeps the cluster joins")

func _test_opening_anchors_and_pulse() -> void:
	var rig := _rig(130)
	var m := rig.manager
	var milestone_count := [0]
	rig.session.scoring.anchors_completed.connect(func(_player: int): milestone_count[0] += 1)
	for id in [0, 7, 40, 47]:
		_place(m, [id], Vector2(7, 4))
	_check(m.anchored_corner_count() == 4 and milestone_count[0] == 1, "four separate corner anchors trigger one milestone")
	_check(rig.session.scoring.power_charges == 1 and rig.session.scoring.anchors_rewarded, "all corners anchored grants one stored Power Charge")
	var corner_score := rig.session.scoring.score
	m.request_release(47)
	_check(rig.session.scoring.score == corner_score and rig.session.scoring.power_charges == 1, "corner milestone and score never repeat")
	var saved := rig.session.scoring.to_dict()
	rig.session.scoring.from_dict(saved)
	_check(rig.session.scoring.to_dict() == saved and rig.session.scoring.power_charges == 1, "anchor milestone and stored charges persist")

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
	huge.session.scoring.from_dict({"charge": 90, "streak": 10})
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
	_check(loaded.load_session("scoring_test") and loaded.scoring.to_dict() == saved_state, "score, Charge, stored charges, streak and awarded IDs survive save/load")
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
	_check(old.scoring.score == 0 and old.scoring.charge == 0 and old.scoring.power_charges == 0 and old.scoring.streak == 0, "older saves initialize scoring safely")
	SaveManager.delete_slot("scoring_test")

func _test_audio_and_hud() -> void:
	_check(Sfx.reward_kind(0, 1) == "small" and Sfx.reward_kind(1, 1) == "medium" and Sfx.reward_kind(2, 1) == "large" and Sfx.reward_kind(3, 1) == "large" and Sfx.reward_kind(3, 12) == "huge", "combo and event size choose different existing snap timbres")
	var rig := _rig(121)
	var view := GameHud.new()
	view.setup(rig.session.scoring, rig.manager, rig.session)
	root.add_child(view)
	_check(view.score_label.text.contains("0") and view.charge_label.text.contains("0/100") and view.charges.count == 0, "the thin HUD shows score, Charge and stored charges")
	_check(view.objective_label.visible and view.objective_label.text.contains("0/4"), "the corner objective is shown at the start")
	rig.manager.pieces[0].is_locked = true
	rig.manager.piece_changed.emit(0)
	_check(view.objective_label.text.contains("1/4"), "objective progress updates when a client receives a locked corner snapshot")
	rig.session.scoring.from_dict({"score": 1350, "charge": 18, "power_charges": 1, "streak": 6})
	_check(view.score_label.text.contains("1,350") and view.combo_label.text.contains("STREAK 6") and view.combo_label.text.contains(RunScoring.format_multiplier(RunScoring.streak_multiplier(6))) and view.charge_label.text.contains("18/100") and view.charges.count == 1, "the HUD updates from authoritative scoring state")
	view._on_awarded({"piece_ids": [0, 1, 2, 3, 4, 5], "piece_count": 6, "source": PuzzleManager.ConnectionSource.POWER, "score_gain": 1350, "charge_gain": 18, "charges_gained": 2})
	_check(view._toasts.size() == 2 and view._toasts[0].text.contains("6 PIECE JOIN") and view._toasts[0].text.contains("+1,350") and view._toasts[1].text.contains("POWER CHARGED! ×2"), "cluster and multi-charge visual feedback is readable")
	# the objective goes away for good once all four corners are anchored
	for id in rig.manager.corner_ids():
		rig.manager.pieces[id].is_locked = true
	rig.manager.piece_changed.emit(0)
	_check(not view.objective_label.visible, "the objective disappears when all four corners are anchored")
	rig.manager.pieces[0].is_locked = false
	rig.manager.piece_changed.emit(0)
	_check(not view.objective_label.visible, "...and does not come back")
	rig.session.size_index = 1
	rig.session.start_puzzle(false)
	_check(rig.session.scoring.score == 0 and rig.session.scoring.charge == 0 and rig.session.scoring.power_charges == 0 and rig.session.scoring.streak == 0 and view.combo_label.text == "NO STREAK" and view._toasts.is_empty() and view.objective_label.visible, "a new puzzle resets scoring, HUD, short notices and the objective")
