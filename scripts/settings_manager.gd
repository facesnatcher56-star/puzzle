class_name SettingsManager
extends RefCounted

const PATH := "user://settings.json"
const RESOLUTIONS := [
	Vector2i(1280, 720), Vector2i(1280, 800), Vector2i(1366, 768), Vector2i(1600, 900),
	Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)
]

# "resolution" stays empty until the player picks one, so a first launch keeps whatever
# window size the OS/project gave us instead of forcing our own.
static func defaults() -> Dictionary:
	return {"fullscreen": false, "resolution": [], "vsync": true, "ui_scale": 1.0, "keep_awake": true}

static func load_settings(path: String = PATH) -> Dictionary:
	var result := defaults()
	if not FileAccess.file_exists(path):
		return result
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return result
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return result
	for key in result.keys():
		if parsed.has(key) and typeof(parsed[key]) == typeof(result[key]):
			result[key] = parsed[key]
	result["ui_scale"] = clampf(float(result["ui_scale"]), 0.7, 1.6)
	return result

static func save_settings(settings: Dictionary, path: String = PATH) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(settings))
		file.close()

# Resolutions that fit on the current screen, largest last.
static func available_resolutions() -> Array:
	var screen := DisplayServer.screen_get_size()
	var result := []
	for res in RESOLUTIONS:
		if res.x <= screen.x and res.y <= screen.y:
			result.append(res)
	return result

# base_scale is the platform's own content scale (mobile density scaling); the player's
# UI-scale setting multiplies on top of it.
static func apply(settings: Dictionary, base_scale: float, window: Window) -> void:
	window.content_scale_factor = base_scale * float(settings.ui_scale)
	if OS.has_feature("mobile"):
		DisplayServer.screen_set_keep_on(bool(settings.keep_awake))
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if settings.vsync else DisplayServer.VSYNC_DISABLED)
	var want_fullscreen := bool(settings.fullscreen)
	var is_fullscreen := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	if want_fullscreen:
		if not is_fullscreen:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	if is_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	var res: Array = settings.resolution
	if res.size() == 2:
		var size := Vector2i(int(res[0]), int(res[1]))
		if DisplayServer.window_get_size() != size:
			DisplayServer.window_set_size(size)
			var screen_pos := DisplayServer.screen_get_position()
			var screen_size := DisplayServer.screen_get_size()
			DisplayServer.window_set_position(screen_pos + ((screen_size - size) / 2).max(Vector2i.ZERO))
