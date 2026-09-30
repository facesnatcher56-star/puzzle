class_name SaveManager
extends RefCounted

const SAVE_PATH := "user://autosave.json" # legacy single-slot save, imported by migrate_legacy()
const LEGACY_RANDOM_PATH := "user://autosave_random.json"
const SCHEMA_VERSION := 1
# Overridable so tests never touch the player's real saves.
static var save_dir := "user://saves"

static func slot_path(slot: String) -> String:
	return save_dir.path_join(slot + ".json")

static func new_slot_id() -> String:
	return "%d_%04d" % [int(Time.get_unix_time_from_system()), randi() % 10000]

# Every saved puzzle, newest first, as {slot, data}. Unreadable or incompatible files are skipped.
static func list_saves() -> Array:
	var result := []
	var dir := DirAccess.open(save_dir)
	if dir == null:
		return result
	for file_name in dir.get_files():
		if not file_name.ends_with(".json"):
			continue
		var slot := file_name.get_basename()
		var data := load_state(slot_path(slot))
		if not data.is_empty():
			result.append({"slot": slot, "data": data})
	result.sort_custom(func(a, b): return float(a.data.get("saved_at", 0)) > float(b.data.get("saved_at", 0)))
	return result

static func delete_slot(slot: String) -> void:
	delete_save(slot_path(slot))

# One-time import of the old one-save-per-mode files into the slot list.
static func migrate_legacy() -> void:
	for path in [SAVE_PATH, LEGACY_RANDOM_PATH]:
		var data := load_state(path)
		if not data.is_empty():
			data["saved_at"] = FileAccess.get_modified_time(path)
			save(data, slot_path("legacy_" + path.get_file().get_basename()), false)
		if has_save(path):
			delete_save(path)

# Writes to a temp file then renames over the real path, so a process kill mid-write
# (e.g. Android backgrounding the app) can never leave a half-written save in place.
static func save(data: Dictionary, path: String = SAVE_PATH, stamp: bool = true) -> Error:
	var payload := data.duplicate(true)
	payload["version"] = SCHEMA_VERSION
	if stamp:
		payload["saved_at"] = int(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp_name := path.get_file() + ".tmp"
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return ERR_CANT_OPEN
	var file := FileAccess.open(path.get_base_dir().path_join(tmp_name), FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(payload))
	file.close()
	if dir.file_exists(path.get_file()):
		dir.remove(path.get_file())
	return dir.rename(tmp_name, path.get_file())

# Returns {} if there is no save, or it's missing/corrupt/from an incompatible schema.
static func load_state(path: String = SAVE_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY or not _is_valid(parsed):
		return {}
	return parsed

static func has_save(path: String = SAVE_PATH) -> bool:
	return FileAccess.file_exists(path)

static func delete_save(path: String = SAVE_PATH) -> void:
	if not FileAccess.file_exists(path):
		return
	var dir := DirAccess.open(path.get_base_dir())
	if dir != null:
		dir.remove(path.get_file())

static func _is_valid(data: Dictionary) -> bool:
	if int(data.get("version", -1)) != SCHEMA_VERSION:
		return false
	for key in ["seed_value", "columns", "rows", "rotation_enabled", "pieces"]:
		if not data.has(key):
			return false
	var pieces = data.pieces
	return typeof(pieces) == TYPE_ARRAY and pieces.size() == int(data.columns) * int(data.rows)
