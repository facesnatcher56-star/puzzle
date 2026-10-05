extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("COLLECTION TEST FAILED: " + message)

func _run() -> void:
	SaveManager.save_dir = "user://test_saves_collection"
	Collection.path = "user://test_collection.json"
	Collection.enabled = true
	for entry in SaveManager.list_saves():
		SaveManager.delete_slot(entry.slot)
	for entry in Collection.load_all():
		Collection.remove(entry.id)
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.lobby.hide_menu()
	game.session.new_session(true)
	game.session.size_index = 0
	game.session.start_puzzle(false)
	game.session.set_rotation_enabled(false)
	var slot: String = game.session.save_slot
	game.session.write_save()
	_check(PuzzleSession.active_saves().size() == 1, "in-progress puzzle appears under saved games")
	# Finish the puzzle for real: every piece at its true place, then released so they all join.
	for pc in game.manager.pieces:
		game.manager.request_place_from_bank(pc.piece_id, pc.correct_position)
	for pc in game.manager.pieces:
		game.manager.request_pickup(pc.piece_id)
		game.manager.request_release(pc.piece_id)
	await process_frame
	var entries := Collection.load_all()
	_check(game.manager.completion_announced and entries.size() == 1, "finishing a puzzle adds one entry to the Collection")
	_check(entries.size() == 1 and entries[0].pieces == 24 and not entries[0].rotation and PuzzleCatalog.RANDOM_IMAGES.has(str(entries[0].image_id)), "entry records pieces, rotation and picture")
	_check(PuzzleSession.active_saves().is_empty() and not FileAccess.file_exists(SaveManager.slot_path(slot)), "the finished puzzle leaves the saved-games list")
	_check(game.session.save_slot == "" and game.session.needs_new_slot, "its save slot is retired so autosave cannot bring it back")
	game.session.write_save()
	_check(SaveManager.list_saves().is_empty(), "nothing is written after completion")
	game.session.start_puzzle(false)
	_check(game.session.save_slot != "", "restarting afterwards starts a fresh save slot")
	# A finished save from an older build is moved into the Collection when the list is built.
	var finished_game_pieces: Array = []
	for pc in game.manager.pieces:
		var snap: Dictionary = pc.snapshot()
		snap.on_table = true
		snap.cluster_id = 0
		finished_game_pieces.append(snap)
	var config: Dictionary = game.session.puzzle_config()
	config["pieces"] = finished_game_pieces
	SaveManager.save(config, SaveManager.slot_path("old_finished"))
	_check(Collection.save_is_complete(SaveManager.load_state(SaveManager.slot_path("old_finished"))), "a fully joined save is recognised as finished")
	PuzzleSession.active_saves()
	var migrated := false
	for e in Collection.load_all():
		if e.id == "old_finished":
			migrated = true
	_check(migrated and not FileAccess.file_exists(SaveManager.slot_path("old_finished")), "a finished save is migrated into the Collection")
	# Stats helpers.
	var fast := {"id": "a", "image_id": "bayou", "pieces": 252, "rotation": true, "time_ms": 600000, "completed_at": 1}
	var slow := {"id": "b", "image_id": "bayou", "pieces": 252, "rotation": true, "time_ms": 900000, "completed_at": 2}
	var other := {"id": "c", "image_id": "motel", "pieces": 48, "rotation": false, "time_ms": 100000, "completed_at": 3}
	var best := Collection.best_times([fast, slow, other])
	_check(best[Collection.bucket(fast)] == 600000 and best[Collection.bucket(other)] == 100000, "best time is tracked per picture, size and rotation")
	var totals := Collection.totals([fast, slow, other])
	_check(totals.count == 3 and totals.pieces == 552 and totals.time_ms == 1600000 and totals.pictures == 2, "totals add up")
	game.lobby.show_collection()
	await process_frame
	_check(game.lobby.stack.get_child_count() > 2, "the Collection screen builds")
	# Sounds render without error and the streams are real.
	var sfx: Sfx = game.sfx
	for kind in ["small", "medium", "large", "huge"]:
		var stream: AudioStreamWAV = sfx._render_snap(kind, 4)
		_check(stream.data.size() > 4000, "%s snap sound renders" % kind)
	_check(sfx._render_complete().data.size() > 100000, "completion fanfare renders")
	for e in SaveManager.list_saves():
		SaveManager.delete_slot(e.slot)
	for e in Collection.load_all():
		Collection.remove(e.id)
	print("collection test done, failures: ", failures)
	quit(1 if failures > 0 else 0)
