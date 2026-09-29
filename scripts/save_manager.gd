class_name SaveManager
extends RefCounted

# One JSON file per puzzle in progress, so players can keep as many going as they like.
const SAVES_DIR := "user://saves"
const LEGACY_SAVE_PATH := "user://autosave.json"
const SCHEMA_VERSION := 1

static func new_id() -> String:
	return "%d_%04d" % [int(Time.get_unix_time_from_system()), randi() % 10000]

static func path_for(id: String) -> String:
	return SAVES_DIR.path_join(id + ".json")

# Writes to a temp file then renames over the real path, so a process kill mid-write
# (e.g. Android backgrounding the app) can never leave a half-written save in place.
static func save(data: Dictionary, path: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var payload := data.duplicate(true)
	payload["version"] = SCHEMA_VERSION
	payload["saved_at"] = int(Time.get_unix_time_from_system())
	if not payload.has("created_at"):
		payload["created_at"] = payload["saved_at"]
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

static func save_puzzle(id: String, data: Dictionary) -> Error:
	return save(data, path_for(id))

# Returns {} if there is no save, or it's missing/corrupt/from an incompatible schema.
static func load_state(path: String) -> Dictionary:
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

static func load_puzzle(id: String) -> Dictionary:
	return load_state(path_for(id))

static func has_save(path: String) -> bool:
	return FileAccess.file_exists(path)

static func delete_save(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var dir := DirAccess.open(path.get_base_dir())
	if dir != null:
		dir.remove(path.get_file())

static func delete_puzzle(id: String) -> void:
	delete_save(path_for(id))

# Lightweight per-puzzle info for the load screen; unreadable files are skipped.
# Newest-played first.
static func list_puzzles(dir_path: String = SAVES_DIR) -> Array:
	_migrate_legacy(dir_path)
	var result := []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return result
	for file_name in dir.get_files():
		if not file_name.ends_with(".json"):
			continue
		var data := load_state(dir_path.path_join(file_name))
		if data.is_empty():
			continue
		result.append(summarize(file_name.get_basename(), data))
	result.sort_custom(func(a, b): return a.saved_at > b.saved_at)
	return result

static func summarize(id: String, data: Dictionary) -> Dictionary:
	var total: int = data.pieces.size()
	var cluster_sizes := {}
	for entry in data.pieces:
		if entry.on_table and int(entry.cluster_id) >= 0:
			var key := int(entry.cluster_id)
			cluster_sizes[key] = int(cluster_sizes.get(key, 0)) + 1
	var joined := 0
	var largest := 0
	for size in cluster_sizes.values():
		largest = maxi(largest, size)
		if size > 1:
			joined += size
	return {
		"id": id, "image": str(data.get("image", "emberbound")), "pieces": total, "joined": joined, "largest": largest,
		"complete": total > 0 and largest == total,
		"rotation_enabled": bool(data.rotation_enabled),
		"elapsed_ms": int(data.get("elapsed_ms", 0)),
		"saved_at": int(data.get("saved_at", 0))
	}

# The pre-multi-slot build kept a single user://autosave.json; adopt it as a normal save.
static func _migrate_legacy(dir_path: String) -> void:
	if dir_path != SAVES_DIR or not FileAccess.file_exists(LEGACY_SAVE_PATH):
		return
	var data := load_state(LEGACY_SAVE_PATH)
	if not data.is_empty():
		save_puzzle(new_id(), data)
	delete_save(LEGACY_SAVE_PATH)

static func _is_valid(data: Dictionary) -> bool:
	if int(data.get("version", -1)) != SCHEMA_VERSION:
		return false
	for key in ["seed_value", "columns", "rows", "rotation_enabled", "pieces"]:
		if not data.has(key):
			return false
	var pieces = data.pieces
	return typeof(pieces) == TYPE_ARRAY and pieces.size() == int(data.columns) * int(data.rows)
