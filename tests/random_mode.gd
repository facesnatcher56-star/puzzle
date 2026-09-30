extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("RANDOM MODE TEST FAILED: " + message)

func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game._hide_lobby()
	SaveManager.delete_save(game.RANDOM_SAVE_PATH)
	game._begin_local_session(true)
	await process_frame
	_check(game.RANDOM_IMAGES.has(game.image_id), "random mode picks one of the bundled images")
	_check(game.board_size == game.source.get_size(), "board matches the picked image")
	_check(game.manager.pieces.size() == 252, "default random puzzle has 252 pieces")
	_check(not game.bank.buttons["reference"].visible, "reference button hidden")
	game._on_bank_action("reference")
	_check(not game.reference_overlay.visible, "reference window cannot open")
	var seen := {}
	for i in range(30):
		var before: String = game.image_id
		game._start_puzzle(true)
		_check(game.image_id != before, "new puzzle switches image")
		seen[game.image_id] = true
	_check(seen.size() >= 3, "several different images appear")
	# Save/restore round trip keeps the image.
	game._on_bank_action("spread")
	game._write_save()
	var saved_id: String = game.image_id
	var saved := SaveManager.load_state(game.RANDOM_SAVE_PATH)
	_check(str(saved.image_id) == saved_id, "save records the image")
	game._begin_local_session(false)
	_check(game.image_id == "" and game.source.get_size() == Vector2(1122, 1402), "classic mode is unaffected")
	_check(game.bank.buttons["reference"].visible, "reference returns in classic mode")
	game._begin_local_session(true)
	_check(game.image_id == saved_id, "random mode resumes its saved image")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	game._hide_lobby()
	game._input(esc)
	_check(game.lobby_overlay.visible and game.in_game_menu, "Esc opens the pause menu")
	game._build_settings()
	game._input(esc)
	_check(game.lobby_overlay.visible and game.in_game_menu and not game.lobby_sub_open, "Esc in settings returns to the pause menu")
	game._input(esc)
	_check(not game.lobby_overlay.visible, "Esc on the pause menu resumes")
	SaveManager.delete_save(game.RANDOM_SAVE_PATH)
	print("random mode test done, failures: ", failures)
	quit(1 if failures > 0 else 0)
