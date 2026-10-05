extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("LOCKING TEST FAILED: " + message)

func _fresh(seed_value: int) -> PuzzleManager:
	var source: Texture2D = load("res://assets/emberbound.png")
	var board := Vector2(1122, 1402)
	var m := PuzzleManager.new()
	m.configure(PuzzleGenerator.generate(source, 8, 6, seed_value, board, false), Vector2(board.x / 8, board.y / 6), 8, 6)
	return m

func _place(m: PuzzleManager, ids: Array, offset: Vector2) -> void:
	for id in ids:
		m.request_place_from_bank(id, m.pieces[id].correct_position + offset)
	for id in ids:
		m.request_pickup(id)
		m.request_release(id)

func _run() -> void:
	var top := [0, 1, 2, 3, 4, 5, 6, 7]
	# A whole top edge dropped on its spot locks to the board, exactly.
	var m := _fresh(1)
	var locked_events := []
	m.group_locked.connect(func(_c, ids, sides): locked_events.append(sides))
	_place(m, top, Vector2(14, -9))
	_check(m.clusters.size() == 1 and m.pieces[0].is_locked and m.pieces[7].is_locked, "a complete top edge on its spot is locked")
	_check(m.pieces[3].current_position == m.pieces[3].correct_position, "locking sets pieces exactly on the board")
	_check(locked_events.size() == 1 and locked_events[0] == ["TOP"], "the lock names the edge")
	_check(not m.request_pickup(3) and not m.request_move(3, Vector2.ZERO) and not m.request_rotate(3), "locked pieces cannot be picked up, moved or rotated")
	# Pieces attached afterwards are locked too, and sit exactly on the board.
	_place(m, [8, 9], Vector2(11, 7))
	_check(m.pieces[8].is_locked and m.pieces[9].is_locked and m.clusters.size() == 1, "pieces attached to a locked edge become part of it")
	_check(m.pieces[9].current_position == m.pieces[9].correct_position, "attached pieces sit exactly in place")
	# A loose piece far from the board is not locked.
	m.request_place_from_bank(30, Vector2(2500, 2500))
	m.request_pickup(30)
	m.request_release(30)
	_check(not m.pieces[30].is_locked, "a loose piece elsewhere stays free")
	# Incomplete side: not locked.
	var m2 := _fresh(2)
	_place(m2, [0, 1, 2, 3, 5, 6, 7], Vector2(5, 5))
	_check(m2.locked_count() == 0, "a side with a piece missing does not lock")
	# Full side but away from its spot: free; carried onto its spot: locks.
	var m3 := _fresh(3)
	_place(m3, top, Vector2(600, 800))
	_check(m3.locked_count() == 0, "a complete side away from the board stays free")
	m3.request_pickup(0)
	m3.request_move(0, m3.pieces[0].correct_position + Vector2(12, 12))
	m3.request_release(0)
	_check(m3.locked_count() == 8, "carrying a complete side onto its spot locks it")
	# Wrong orientation: no lock.
	var m4 := _fresh(4)
	_place(m4, top, Vector2(3, 3))
	var m5 := _fresh(5)
	for id in top:
		m5.request_place_from_bank(id, m5.pieces[id].correct_position)
		m5.pieces[id].current_rotation = 90
	for id in top:
		m5.request_pickup(id)
		m5.request_release(id)
	_check(m5.locked_count() == 0, "a rotated side does not lock")
	# Left column also counts.
	var m6 := _fresh(6)
	_place(m6, [0, 8, 16, 24, 32, 40], Vector2(-8, 10))
	_check(m6.locked_count() == 6 and m6.complete_sides(m6.clusters[m6.pieces[0].cluster_id]) == ["LEFT"], "a complete left edge locks")
	# Locks survive saving and loading, and a damaged group is pulled onto the board.
	var snaps := []
	for pc in m.pieces:
		snaps.append(pc.snapshot())
	var reloaded := _fresh(1)
	reloaded.apply_snapshots(snaps)
	_check(reloaded.locked_count() == m.locked_count() and reloaded.pieces[9].is_locked, "locked pieces persist through a save")
	for snap in snaps:
		if int(snap.piece_id) == 9:
			snap.position = [snap.position[0] + 20.0, snap.position[1] - 9.0]
	var repaired := _fresh(1)
	repaired.apply_snapshots(snaps)
	_check(repaired.pieces[9].current_position == repaired.pieces[9].correct_position, "locked pieces are held exactly on the board when loaded")
	print("locking test done, failures: ", failures)
	quit(1 if failures > 0 else 0)
