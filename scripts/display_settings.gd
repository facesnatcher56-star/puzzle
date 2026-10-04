class_name DisplaySettings
extends RefCounted

const PATH := "user://settings.cfg"
const RESOLUTIONS := [
	Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(2560, 1440), Vector2i(3440, 1440), Vector2i(3840, 2160)
]

static func is_supported() -> bool:
	return not OS.has_feature("mobile") and DisplayServer.get_name() != "headless"

# Resolutions that fit on the current monitor (a window can't usefully be larger than the screen).
static func available_resolutions() -> Array:
	var usable := DisplayServer.screen_get_usable_rect().size
	var result := []
	for res in RESOLUTIONS:
		if res.x <= usable.x and res.y <= usable.y:
			result.append(res)
	if result.is_empty():
		result.append(Vector2i(1280, 720))
	return result

static func load_settings() -> Dictionary:
	var config := ConfigFile.new()
	var defaults := {"fullscreen": false, "width": 1280, "height": 800}
	if config.load(PATH) != OK:
		return defaults
	return {
		"fullscreen": bool(config.get_value("display", "fullscreen", false)),
		"width": int(config.get_value("display", "width", 1280)),
		"height": int(config.get_value("display", "height", 800)),
	}

static func save_settings(fullscreen: bool, size: Vector2i) -> void:
	var config := ConfigFile.new()
	config.load(PATH) # keep the audio section
	config.set_value("display", "fullscreen", fullscreen)
	config.set_value("display", "width", size.x)
	config.set_value("display", "height", size.y)
	config.save(PATH)

static func apply(fullscreen: bool, size: Vector2i) -> void:
	if not is_supported():
		return
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	var usable := DisplayServer.screen_get_usable_rect()
	DisplayServer.window_set_position(usable.position + (usable.size - size) / 2)

static func apply_saved() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var saved := load_settings()
	apply(saved.fullscreen, Vector2i(saved.width, saved.height))

# --- sound ---

static func load_volume() -> float:
	var config := ConfigFile.new()
	if config.load(PATH) != OK:
		return 0.8
	return clampf(float(config.get_value("audio", "volume", 0.8)), 0.0, 1.0)

static func save_volume(value: float) -> void:
	var config := ConfigFile.new()
	config.load(PATH)
	config.set_value("audio", "volume", value)
	config.save(PATH)

static func apply_volume(value: float) -> void:
	AudioServer.set_bus_volume_db(0, -80.0 if value <= 0.001 else linear_to_db(value))

static func load_vibration() -> bool:
	var config := ConfigFile.new()
	if config.load(PATH) != OK:
		return true
	return bool(config.get_value("audio", "vibration", true))

static func save_vibration(value: bool) -> void:
	var config := ConfigFile.new()
	config.load(PATH)
	config.set_value("audio", "vibration", value)
	config.save(PATH)
