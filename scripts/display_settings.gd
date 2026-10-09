class_name DisplaySettings
extends RefCounted

const PATH := "user://settings.cfg"
# Cached copy of the vibration setting so snaps never read the file; set at startup and when toggled.
static var vibration_enabled := true
const RESOLUTIONS := [
	Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(2560, 1440), Vector2i(2560, 1600), Vector2i(3440, 1440), Vector2i(3840, 2160)
]

static func is_supported() -> bool:
	return not OS.has_feature("mobile") and DisplayServer.get_name() != "headless"

# Resolutions that fit on the monitor, judged against its full size (not the area left after the task bar, which
# would hide 1440p and 4K from a monitor of exactly that size). `screen` is the monitor's size in pixels.
static func resolutions_for(screen: Vector2i) -> Array:
	var result := []
	for res in RESOLUTIONS:
		if res.x <= screen.x and res.y <= screen.y:
			result.append(res)
	if result.is_empty():
		result.append(Vector2i(1280, 720))
	return result

# The largest monitor connected, so a 4K screen plugged into a handheld or laptop still offers 4K.
static func largest_screen() -> Vector2i:
	var best := DisplayServer.screen_get_size()
	for i in range(DisplayServer.get_screen_count()):
		var size := DisplayServer.screen_get_size(i)
		if size.x * size.y > best.x * best.y:
			best = size
	return best

# The monitor to use for a window of `size`: the one it is on if it fits, otherwise the biggest.
static func screen_for(size: Vector2i) -> int:
	var current := DisplayServer.window_get_current_screen()
	var current_size := DisplayServer.screen_get_size(current)
	if size.x <= current_size.x and size.y <= current_size.y:
		return current
	var best := current
	for i in range(DisplayServer.get_screen_count()):
		var candidate := DisplayServer.screen_get_size(i)
		var best_size := DisplayServer.screen_get_size(best)
		if candidate.x * candidate.y > best_size.x * best_size.y:
			best = i
	return best

static func available_resolutions() -> Array:
	return resolutions_for(largest_screen())

# "2560 x 1440 (2K)", "3840 x 2160 (4K)"; the others are just the size.
static func resolution_label(size: Vector2i) -> String:
	var text := "%d x %d" % [size.x, size.y]
	if size == Vector2i(2560, 1440):
		return text + " (2K)"
	if size == Vector2i(3840, 2160):
		return text + " (4K)"
	if size == Vector2i(1920, 1080):
		return text + " (Full HD)"
	return text

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
	DisplayServer.window_set_current_screen(screen_for(size)) # a 4K window goes to the 4K monitor
	DisplayServer.window_set_size(size)
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	var corner := usable.position + (usable.size - size) / 2
	DisplayServer.window_set_position(Vector2i(maxi(corner.x, usable.position.x), maxi(corner.y, usable.position.y))) # never leave the title bar off-screen

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
	vibration_enabled = value
	var config := ConfigFile.new()
	config.load(PATH)
	config.set_value("audio", "vibration", value)
	config.save(PATH)
