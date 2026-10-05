extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("RANDOM MODE TEST FAILED: " + message)

func _run() -> void:
	SaveManager.save_dir = "user://test_saves"
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.lobby.hide_menu()
	game.session.new_session(true)
	await process_frame
	_check(PuzzleCatalog.RANDOM_IMAGES.has(game.session.image_id), "random mode picks one of the bundled images")
	_check(game.session.board_size == game.session.source.get_size(), "board matches the picked image")
	_check(game.manager.pieces.size() == 252, "default random puzzle has 252 pieces")
	_check(not game.bank.is_tool_enabled("reference"), "reference tool unavailable in random mode")
	game.input_controller.on_bank_action("reference")
	_check(not game.reference.visible, "reference window cannot open")
	var seen := {}
	for i in range(30):
		var before: String = game.session.image_id
		game.session.start_puzzle(true)
		_check(game.session.image_id != before, "new puzzle switches image")
		seen[game.session.image_id] = true
	_check(seen.size() >= 2, "several different images appear") # this puzzle's own picture is saved, so it is not offered again
	# Saving: every new puzzle gets its own slot, listed newest first, and loads back with its image.
	for entry in SaveManager.list_saves():
		SaveManager.delete_slot(entry.slot)
	game.input_controller.on_bank_action("spread")
	game.session.write_save()
	var saved_id: String = game.session.image_id
	var slot: String = game.session.save_slot
	var listed := SaveManager.list_saves()
	_check(listed.size() >= 1 and listed[0].slot == slot, "new puzzle appears in the save list")
	_check(str(listed[0].data.image_id) == saved_id, "save records the image")
	game.session.new_session(false)
	_check(game.session.image_id == "" and game.session.source.get_size() == Vector2(1122, 1402), "classic mode is unaffected")
	_check(game.session.save_slot != slot, "a new game gets a new slot")
	_check(game.bank.is_tool_enabled("reference"), "reference returns in classic mode")
	_check(SaveManager.list_saves().size() == 2, "both puzzles are listed")
	_check(game.session.load_session(slot), "loading a saved slot succeeds")
	_check(game.session.image_id == saved_id and game.session.save_slot == slot, "load restores the image and keeps autosaving into the same slot")
	_check(not game.session.load_session("missing_slot"), "loading a missing slot fails cleanly")
	SaveManager.delete_slot(slot)
	_check(SaveManager.list_saves().size() == 1, "deleting a slot removes it from the list")
	# Random Puzzle never offers a finished picture or one that is already in a saved game.
	Collection.path = "user://test_collection_random.json"
	Collection.enabled = true
	for entry in SaveManager.list_saves():
		SaveManager.delete_slot(entry.slot)
	for entry in Collection.load_all():
		Collection.remove(entry.id)
	_check(PuzzleSession.fresh_random_images().size() == PuzzleCatalog.RANDOM_IMAGES.size(), "with nothing finished or saved every picture is available")
	Collection.add({"id": "done", "image_id": "bayou", "pieces": 24, "columns": 6, "rows": 4, "time_ms": 1000, "completed_at": 1, "online": false})
	game.session.new_session(false)
	game.session.apply_image("motel")
	game.session.start_puzzle(false)
	game.session.write_save() # a saved game in progress on the motel picture
	var fresh := PuzzleSession.fresh_random_images()
	_check(not fresh.has("bayou") and not fresh.has("motel") and fresh.size() == PuzzleCatalog.RANDOM_IMAGES.size() - 2, "finished (bayou) and in-progress (motel) pictures are not offered (got %s)" % [fresh])
	var picked := {}
	for i in range(60):
		picked[game.session.pick_random_image()] = true
	_check(picked.size() >= 2 and not picked.has("bayou") and not picked.has("motel"), "random picks only come from the fresh pool")
	for i in range(10):
		game.session.start_puzzle(true) # the NEW button in random mode
		_check(game.session.image_id != "bayou" and game.session.image_id != "motel", "NEW never lands on a finished or in-progress picture")
	# Everything used up: the game still offers a puzzle (an unfinished one) rather than failing.
	var finish_index := 2
	for id in PuzzleCatalog.RANDOM_IMAGES.keys():
		if id != "bayou" and id != "motel":
			Collection.add({"id": "done%d" % finish_index, "image_id": id, "pieces": 24, "columns": 6, "rows": 4, "time_ms": 1000, "completed_at": finish_index, "online": false})
			finish_index += 1
	_check(PuzzleSession.fresh_random_images().is_empty(), "no fresh pictures once all are finished or started")
	_check(PuzzleCatalog.RANDOM_IMAGES.has(game.session.pick_random_image()), "a puzzle is still offered when every picture is used")
	for entry in Collection.load_all():
		Collection.remove(entry.id)
	Collection.enabled = false
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	game.lobby.hide_menu()
	game._input(esc)
	_check(game.lobby.visible and game.lobby.in_game_menu, "Esc opens the pause menu")
	game.lobby.show_settings()
	game._input(esc)
	_check(game.lobby.visible and game.lobby.in_game_menu and not game.lobby.sub_open, "Esc in settings returns to the pause menu")
	game._input(esc)
	_check(not game.lobby.visible, "Esc on the pause menu resumes")
	for entry in SaveManager.list_saves():
		SaveManager.delete_slot(entry.slot)
	print("random mode test done, failures: ", failures)
	quit(1 if failures > 0 else 0)
