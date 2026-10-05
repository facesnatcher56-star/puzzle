class_name Collection
extends RefCounted

# Every finished puzzle is kept here with its stats, separate from in-progress saves.
# An entry: {id, image_id, columns, rows, pieces, time_ms, completed_at, online}

static var path := "user://collection.json"
# Headless runs are automated tests; they must never write into a player's real collection.
static var enabled := DisplayServer.get_name() != "headless"

static func load_all() -> Array:
	if not FileAccess.file_exists(path):
		return []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("entries")) != TYPE_ARRAY:
		return []
	var entries: Array = parsed.entries
	entries.sort_custom(func(a, b): return float(a.get("completed_at", 0)) > float(b.get("completed_at", 0)))
	return entries

static func _store(entries: Array) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"version": 1, "entries": entries}))
	file.close()
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return
	if dir.file_exists(path.get_file()):
		dir.remove(path.get_file())
	dir.rename(tmp.get_file(), path.get_file())

# Adds a finished puzzle. An entry with the same id is replaced, so recording is safe to repeat.
static func add(entry: Dictionary) -> void:
	if not enabled:
		return
	var entries := load_all()
	for i in range(entries.size() - 1, -1, -1):
		if entries[i].get("id", "") == entry.get("id", "x"):
			entries.remove_at(i)
	entries.append(entry)
	_store(entries)

static func remove(id: String) -> void:
	var entries := load_all()
	for i in range(entries.size() - 1, -1, -1):
		if entries[i].get("id", "") == id:
			entries.remove_at(i)
	_store(entries)

# Builds an entry from a finished puzzle's config (the same dictionary a save holds).
static func entry_from(config: Dictionary, id: String, time_ms: int, completed_at: int, online: bool) -> Dictionary:
	var columns := int(config.columns)
	var rows := int(config.rows)
	return {
		"id": id, "image_id": str(config.get("image_id", "")),
		"columns": columns, "rows": rows, "pieces": columns * rows,
		"time_ms": time_ms, "completed_at": completed_at, "online": online
	}

# Same picture and piece count: the "best time" bucket.
static func bucket(entry: Dictionary) -> String:
	return "%s|%d" % [entry.get("image_id", ""), int(entry.get("pieces", 0))]

# {bucket: fastest time_ms}
static func best_times(entries: Array) -> Dictionary:
	var best := {}
	for entry in entries:
		var key := bucket(entry)
		var time := int(entry.get("time_ms", 0))
		if time > 0 and (not best.has(key) or time < best[key]):
			best[key] = time
	return best

static func totals(entries: Array) -> Dictionary:
	var pieces := 0
	var time_ms := 0
	var pictures := {}
	for entry in entries:
		pieces += int(entry.get("pieces", 0))
		time_ms += int(entry.get("time_ms", 0))
		pictures[str(entry.get("image_id", ""))] = true
	return {"count": entries.size(), "pieces": pieces, "time_ms": time_ms, "pictures": pictures.size()}

# True if a saved puzzle's snapshots show every piece placed and joined into one group.
static func save_is_complete(saved: Dictionary) -> bool:
	var pieces: Array = saved.get("pieces", [])
	if pieces.is_empty():
		return false
	var group := -2
	for snap in pieces:
		if not snap.on_table:
			return false
		if group == -2:
			group = int(snap.cluster_id)
		elif int(snap.cluster_id) != group:
			return false
	return true
