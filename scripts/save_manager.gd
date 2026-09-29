class_name SaveManager
extends RefCounted

const SAVE_PATH := "user://autosave.json"
const SCHEMA_VERSION := 1

# Writes to a temp file then renames over the real path, so a process kill mid-write
# (e.g. Android backgrounding the app) can never leave a half-written save in place.
static func save(data: Dictionary, path: String = SAVE_PATH) -> Error:
	var payload := data.duplicate(true)
	payload["version"] = SCHEMA_VERSION
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
