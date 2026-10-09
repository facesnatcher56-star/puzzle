extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("BOARD SNAP TEST FAILED: " + message)

func _manager(seed_value: int) -> PuzzleManager:
	var m := PuzzleManager.new()
	var source: Texture2D = load("res://assets/emberbound.png")
	var board := Vector2(1122, 1402)
	m.configure(PuzzleGenerator.generate(source, 8, 6, seed_value, board, false), Vector2(board.x / 8, board.y / 6), 8, 6)
	return m

# Puts a piece on the table `offset` away from its true spot, upright, and lets go of it.
func _drop(m: PuzzleManager, id: int, offset: Vector2, rotation_degrees := 0) -> void:
	m.request_place_from_bank(id, m.pieces[id].correct_position + offset)
	while m.pieces[id].current_rotation != rotation_degrees:
		m.request_rotate(id)
	m.pieces[id].current_position = m.pieces[id].correct_position + offset
	m.request_pickup(id)
	m.request_release(id)

func _run() -> void:
	var m := _manager(1)
	var cell := minf(m.cell_size.x, m.cell_size.y)
	_check(is_equal_approx(PuzzleManager.BOARD_SNAP_TOLERANCE, PuzzleManager.SNAP_TOLERANCE * 2.0), "the board's snap distance is twice a piece-to-piece one")
	# the main puzzle grows outward from a corner; pieces beside it lock from further out than a piece-to-piece join
	_drop(m, 0, Vector2.ZERO)
	_check(m.pieces[0].is_locked, "the corner locks")
	_drop(m, 1, Vector2(cell * 0.33, 0))
	_check(m.pieces[1].is_locked and m.pieces[1].current_position == m.pieces[1].correct_position, "a piece dropped 33% of a cell from its spot beside the main puzzle locks in place")
	_drop(m, 2, Vector2(cell * 0.40, cell * 0.25))
	_check(not m.pieces[2].is_locked, "...but not one that is further out than twice the normal distance")
	_drop(m, 8, Vector2(cell * 0.1, 0), 90)
	_check(not m.pieces[8].is_locked, "...nor one that is turned the wrong way")
	_drop(m, 10, Vector2(-cell * 0.10, cell * 0.30))
	_check(not m.pieces[10].is_locked, "...nor one whose neighbours are not in the main puzzle yet")
	_drop(m, 16, Vector2.ZERO)
	_check(not m.pieces[16].is_locked, "a piece at its true spot far from the finished part stays loose")
	# a group locks as one
	var n := _manager(2)
	_drop(n, 0, Vector2.ZERO)
	_drop(n, 1, Vector2(900, 400))
	_drop(n, 2, Vector2(900, 400))
	_check(n.cluster_members(1).size() == 2 and not n.pieces[1].is_locked, "two pieces joined away from the board stay loose")
	n.request_pickup(1)
	n.request_move(1, n.pieces[1].correct_position + Vector2(cell * 0.3, 0))
	n.request_release(1)
	_check(n.pieces[1].is_locked and n.pieces[2].is_locked, "a group let go near its true spot beside the main puzzle locks as one")
	# dropping on top of locked pieces is not a wrong guess
	var o := _manager(3)
	_drop(o, 0, Vector2.ZERO)
	var misses := []
	o.first_try_ended.connect(func(_id: int, missed: bool): misses.append(missed))
	o.request_place_from_bank(30, o.pieces[0].correct_position + Vector2(cell * 0.2, cell * 0.2)) # right on top of the locked piece
	o.request_pickup(30)
	o.request_release(30)
	_check(not o.pieces[30].is_locked and misses == [false], "a piece let go on top of a locked piece does not count as a miss: %s" % [misses])
	# ...while a near miss against a piece that is still loose does
	var q := _manager(4)
	_drop(q, 3, Vector2(900, 300))
	var q_misses := []
	q.first_try_ended.connect(func(_id: int, missed: bool): q_misses.append(missed))
	q.request_place_from_bank(30, q.pieces[3].current_position + Vector2(q.cell_size.x * 0.9, 0))
	q.request_pickup(30)
	q.request_release(30)
	_check(q_misses == [true], "a near miss against a loose piece still counts: %s" % [q_misses])
	print("board snap test done, failures: ", failures)
	quit(1 if failures > 0 else 0)
