extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("DISPLAY SETTINGS TEST FAILED: " + message)

func _run() -> void:
	_check(DisplaySettings.resolutions_for(Vector2i(3840, 2160)).has(Vector2i(3840, 2160)), "a 4K monitor offers 4K")
	_check(DisplaySettings.resolutions_for(Vector2i(3840, 2160)).has(Vector2i(2560, 1440)), "...and 2K")
	_check(DisplaySettings.resolutions_for(Vector2i(2560, 1440)).has(Vector2i(2560, 1440)) and not DisplaySettings.resolutions_for(Vector2i(2560, 1440)).has(Vector2i(3840, 2160)), "a 2K monitor offers 2K but not 4K")
	_check(DisplaySettings.resolutions_for(Vector2i(800, 600)) == [Vector2i(1280, 720)], "a tiny screen still gets one choice")
	_check(DisplaySettings.resolution_label(Vector2i(3840, 2160)).contains("4K") and DisplaySettings.resolution_label(Vector2i(2560, 1440)).contains("2K"), "the 2K and 4K entries are named")
	print("display settings test done, failures: ", failures)
	quit(1 if failures > 0 else 0)
