extends SceneTree

var failures := 0
const TEST_SAVE_PATH := "user://test_autosave.json"
const CORRUPT_SAVE_PATH := "user://test_autosave_corrupt.json"

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("PERSISTENCE TEST FAILED: " + message)

func _run() -> void:
	SaveManager.delete_save(TEST_SAVE_PATH)
	_check(not SaveManager.has_save(TEST_SAVE_PATH), "no save exists before the test writes one")
	_check(SaveManager.load_state(TEST_SAVE_PATH).is_empty(), "loading a missing save returns an empty dictionary")

	var columns := 8
	var rows := 6
	var seed_value := 52820
	var board_size := Vector2(1122, 1402)
	var cell := Vector2(board_size.x / columns, board_size.y / rows)
	var source: Texture2D = load("res://assets/emberbound.png")
	var manager := PuzzleManager.new()
	manager.configure(PuzzleGenerator.generate(source, columns, rows, seed_value, board_size, true), cell, columns, rows)

	manager.request_place_from_bank(0, Vector2(-1000, 500), 1) # left "held" by player 1 at save time
	manager.request_place_from_bank(20, Vector2(800, 800))
	manager.request_release(20)
	manager.request_rotate(20)
	manager.move_piece_to_tray(5, 1)

	var piece_snapshots := []
	for piece in manager.pieces:
		var snap := piece.snapshot()
		snap.owner_peer_id = 0
		piece_snapshots.append(snap)
	var data := {
		"seed_value": seed_value, "columns": columns, "rows": rows,
		"rotation_enabled": true, "elapsed_ms": 12345,
		"pieces": piece_snapshots
	}
	var err := SaveManager.save(data, TEST_SAVE_PATH)
	_check(err == OK, "save writes without error")
	_check(SaveManager.has_save(TEST_SAVE_PATH), "has_save reports true after writing")

	var loaded := SaveManager.load_state(TEST_SAVE_PATH)
	_check(not loaded.is_empty(), "a freshly written save loads back")
	_check(int(loaded.seed_value) == seed_value and int(loaded.columns) == columns and int(loaded.rows) == rows, "config round-trips")
	_check(loaded.pieces.size() == columns * rows, "every piece round-trips")
	for entry in loaded.pieces:
		_check(int(entry.owner_peer_id) == 0, "ownership is never persisted, even for a piece held at save time")

	# Simulate "the app restarted": build a completely fresh manager purely from the loaded JSON.
	var restored_states := PuzzleGenerator.generate(source, int(loaded.columns), int(loaded.rows), int(loaded.seed_value), board_size, bool(loaded.rotation_enabled))
	var restored_manager := PuzzleManager.new()
	restored_manager.configure(restored_states, cell, int(loaded.columns), int(loaded.rows))
	restored_manager.apply_snapshots(loaded.pieces)

	_check(restored_states[0].is_on_table and restored_states[0].current_position.distance_to(manager.pieces[0].current_position) < 0.01, "placed piece position round-trips")
	_check(restored_states[0].owner_peer_id == 0, "restored ownership is always cleared, even though the live piece was still held")
	_check(restored_states[20].current_rotation == manager.pieces[20].current_rotation, "rotation round-trips")
	_check(restored_states[5].tray_id == 1 and not restored_states[5].is_on_table, "tray assignment round-trips for a piece still in the bank")
	_check(restored_manager.completion_announced == manager.completion_announced, "completion state round-trips")

	SaveManager.delete_save(TEST_SAVE_PATH)
	_check(not SaveManager.has_save(TEST_SAVE_PATH), "delete_save removes the file")

	var file := FileAccess.open(CORRUPT_SAVE_PATH, FileAccess.WRITE)
	file.store_string("{ not valid json ]")
	file.close()
	_check(SaveManager.load_state(CORRUPT_SAVE_PATH).is_empty(), "corrupted JSON loads as empty rather than throwing")
	SaveManager.delete_save(CORRUPT_SAVE_PATH)

	if failures == 0:
		print("PERSISTENCE TEST PASSED: save/load round-trip, ownership stripped, corrupt file handled")
	quit(0 if failures == 0 else 1)
