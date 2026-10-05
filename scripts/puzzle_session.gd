class_name PuzzleSession
extends Node

# The running puzzle: which picture and grid are in play, the generated pieces (via the PuzzleManager),
# and everything about starting, restoring, saving and loading one. It knows nothing about widgets;
# whoever owns the screen listens to its signals and updates the display.

# The table must be cleared (piece views, selection, drag state, previews) before the puzzle changes.
signal puzzle_resetting
# The picture (and therefore board size and piece-count options) changed.
signal image_changed(id: String)
# A brand-new puzzle was generated and handed to the manager.
signal puzzle_started(pieces: Array)
# A saved or synced puzzle was rebuilt.
signal puzzle_restored(pieces: Array)

const AUTOSAVE_INTERVAL := 2.0

var manager: PuzzleManager
var network: NetworkSession
var scoring := RunScoring.new()

var image_id := "" # "" = the classic Emberbound puzzle, otherwise a PuzzleCatalog.RANDOM_IMAGES key
var source: Texture2D = PuzzleCatalog.SOURCE_IMAGE
var board_size := PuzzleCatalog.BOARD_SIZE
var sizes: Array = PuzzleCatalog.SIZES
var size_index := 3 # which entry of `sizes` the next puzzle uses
var columns := 8
var rows := 6
var cell := Vector2(132, 117.333)
var seed_value := 52813
# Pieces start at random quarter-turns. Players can always rotate; this only exists so tests can ask for an
# unrotated start.
var random_rotation := true

# The board-power zones of the running puzzle (empty for a save from before zones existed). They are part of the
# puzzle's configuration, so they are saved, and sent to joining players, with the rest of it.
var power_zones: Array = []

var save_slot := "" # file slot the running puzzle autosaves into; "" while a client (clients never save)
var save_dirty := false
var needs_new_slot := false # a completed puzzle's save slot is retired; the next puzzle gets a fresh one
var restoring := false # true while snapshots are being applied; effects and detection stay quiet

var _last_change_msec := 0
var _last_saved_msec := 0
var _autosave_timer: Timer

func setup(p_manager: PuzzleManager, p_network: NetworkSession) -> void:
	manager = p_manager
	network = p_network
	scoring.setup(manager, network)
	scoring.state_changed.connect(mark_dirty)
	manager.piece_changed.connect(mark_dirty.unbind(1))
	manager.pieces_joined.connect(mark_dirty.unbind(2))
	manager.group_locked.connect(mark_dirty.unbind(3))
	manager.puzzle_completed.connect(mark_dirty)
	manager.bank_changed.connect(mark_dirty)

func _ready() -> void:
	_autosave_timer = Timer.new()
	_autosave_timer.wait_time = AUTOSAVE_INTERVAL
	_autosave_timer.autostart = true
	_autosave_timer.timeout.connect(_on_autosave_tick)
	add_child(_autosave_timer)

# --- starting and loading ---

func new_session(random_mode: bool) -> void:
	save_slot = SaveManager.new_slot_id()
	if random_mode:
		seed_value = randi_range(1, 1000000)
		apply_image(pick_random_image())
	else:
		apply_image("")
	start_puzzle(false)
	write_save() # list it under Load Game straight away

# A new puzzle with a picture made on the spot from `theme` (a ProceduralImage theme id, or "any").
func new_generated_session(theme: String) -> void:
	save_slot = SaveManager.new_slot_id()
	seed_value = randi_range(1, 1000000)
	apply_image(PuzzleCatalog.generated_id(theme))
	start_puzzle(false)
	write_save()

# Loads a saved puzzle into this session; false if the file is missing, damaged, or names artwork this build lacks.
func load_session(slot: String) -> bool:
	var saved := SaveManager.load_state(SaveManager.slot_path(slot))
	if saved.is_empty() or not PuzzleCatalog.is_known(str(saved.get("image_id", ""))):
		return false
	save_slot = slot
	restore_puzzle(saved)
	return true

# Generates a fresh puzzle from the current picture and grid. A new seed also starts a new save slot,
# and in Random mode picks a different picture.
func start_puzzle(new_seed: bool) -> void:
	if needs_new_slot and not network.is_client():
		save_slot = SaveManager.new_slot_id()
		needs_new_slot = false
	if new_seed:
		seed_value += 1
		if not network.is_client():
			save_slot = SaveManager.new_slot_id()
		if PuzzleCatalog.is_generated(image_id):
			var keep_size := size_index
			apply_image(image_id) # a new seed is a new picture from the same theme, at the size already chosen
			size_index = keep_size
		elif image_id != "":
			apply_image(pick_random_image())
	puzzle_resetting.emit()
	var grid: Vector2i = sizes[size_index]
	columns = grid.x
	rows = grid.y
	cell = Vector2(board_size.x / columns, board_size.y / rows)
	var generated := PuzzleGenerator.generate(source, columns, rows, seed_value, board_size, random_rotation)
	if generated.size() != columns * rows:
		push_error("Puzzle generation failed: expected %d pieces, got %d" % [columns * rows, generated.size()])
		return
	manager.configure(generated, cell, columns, rows)
	scoring.reset()
	var zone_rng := RandomNumberGenerator.new()
	zone_rng.randomize()
	power_zones = PowerLayout.generate(columns, rows, zone_rng)
	puzzle_started.emit(generated)
	if network.is_host():
		network.broadcast_full_state()
	mark_dirty()

# Rebuilds a puzzle from a save (or a host's synced state): same pieces, positions and rotations.
func restore_puzzle(saved: Dictionary) -> void:
	puzzle_resetting.emit()
	var saved_image := str(saved.get("image_id", ""))
	if not PuzzleCatalog.is_known(saved_image):
		push_error("Puzzle restore failed: unknown image '%s'" % saved_image)
		return
	seed_value = int(saved.seed_value) # first: a generated picture is made from the seed
	apply_image(saved_image)
	columns = int(saved.columns)
	rows = int(saved.rows)
	cell = Vector2(board_size.x / columns, board_size.y / rows)
	var size_match := sizes.find(Vector2i(columns, rows))
	if size_match >= 0:
		size_index = size_match
	# Every piece's rotation comes from the saved snapshots, so how the pieces were first scrambled is irrelevant here.
	var generated := PuzzleGenerator.generate(source, columns, rows, seed_value, board_size, true)
	if generated.size() != columns * rows:
		push_error("Puzzle restore failed: expected %d pieces, got %d" % [columns * rows, generated.size()])
		return
	manager.configure(generated, cell, columns, rows)
	scoring.from_dict(saved.get("scoring", {}) if saved.get("scoring", {}) is Dictionary else {})
	power_zones = PowerZone.zones_from_save(saved, columns, rows)
	restoring = true
	manager.apply_snapshots(saved.pieces) # emits piece_changed for every piece; the board creates each on-table view reactively
	restoring = false
	scoring.reconcile_legacy_anchors()
	manager.started_at = Time.get_ticks_msec() - int(saved.get("elapsed_ms", 0))
	puzzle_restored.emit(generated)

# A client receives the host's puzzle; it must never write that puzzle to its own save slot.
func restore_from_host(config: Dictionary, snapshots: Array) -> void:
	save_slot = ""
	var saved := config.duplicate()
	saved["pieces"] = snapshots
	restore_puzzle(saved)

# Switches picture, board size and piece-count options.
func apply_image(id: String) -> void:
	image_id = id
	source = PuzzleCatalog.texture_for(id, seed_value)
	board_size = source.get_size()
	sizes = PuzzleCatalog.sizes_for(id)
	size_index = sizes.size() - 1
	image_changed.emit(id)

# --- configuration shared with saves and the network ---

func puzzle_config() -> Dictionary:
	var config := {
		"seed_value": seed_value, "columns": columns, "rows": rows,
		"rotation_enabled": true, "image_id": image_id, # key kept so saves stay readable by older builds
		"elapsed_ms": Time.get_ticks_msec() - manager.started_at
	}
	config["zones"] = PowerZone.list_to_data(power_zones)
	config["scoring"] = scoring.to_dict()
	return config

# --- saving ---

func mark_dirty() -> void:
	save_dirty = true
	_last_change_msec = Time.get_ticks_msec()

func write_save() -> void:
	if save_slot == "":
		return
	var piece_snapshots := []
	for piece in manager.pieces:
		var snap := piece.snapshot()
		snap.owner_peer_id = 0
		piece_snapshots.append(snap)
	var data := puzzle_config()
	data["pieces"] = piece_snapshots
	SaveManager.save(data, SaveManager.slot_path(save_slot))
	save_dirty = false
	_last_saved_msec = Time.get_ticks_msec()

# Saves if there is something unsaved and this player owns the puzzle (solo or host).
func flush_save() -> void:
	if network != null and (network.is_solo() or network.is_host()) and save_dirty:
		write_save()

func _on_autosave_tick() -> void:
	if not save_dirty or not (network.is_solo() or network.is_host()):
		return
	var now := Time.get_ticks_msec()
	if now - _last_change_msec >= 1500 or now - _last_saved_msec >= 15000:
		write_save()

# Id for this puzzle's Collection entry (its save slot, so recording is idempotent).
func entry_id() -> String:
	return save_slot if save_slot != "" else SaveManager.new_slot_id()

# The puzzle was finished: its save slot is deleted and autosave stops until the next puzzle starts.
func retire_save_slot() -> void:
	if save_slot != "":
		SaveManager.delete_slot(save_slot)
		save_slot = ""
		needs_new_slot = true
	save_dirty = false

# --- choosing a random picture ---

# Pictures that are neither finished (in the Collection) nor in progress (a saved game), so Random Puzzle
# always offers something new.
static func fresh_random_images() -> Array:
	var taken := {}
	for entry in Collection.load_all():
		taken[str(entry.get("image_id", ""))] = true
	for entry in active_saves():
		taken[str(entry.data.get("image_id", ""))] = true
	return PuzzleCatalog.RANDOM_IMAGES.keys().filter(func(id): return not taken.has(id))

# A random picture for a new puzzle: a fresh one if any are left. Once every picture has been finished or
# started, pictures that have not been finished are used, and as a last resort any picture except the one
# on the table, so the game never runs out of puzzles.
func pick_random_image() -> String:
	var fresh := fresh_random_images().filter(func(id): return id != image_id) # a new puzzle is always a visible change
	if not fresh.is_empty():
		return fresh[randi() % fresh.size()]
	var finished := {}
	for entry in Collection.load_all():
		finished[str(entry.get("image_id", ""))] = true
	var unfinished := PuzzleCatalog.RANDOM_IMAGES.keys().filter(func(id): return not finished.has(id) and id != image_id)
	if not unfinished.is_empty():
		return unfinished[randi() % unfinished.size()]
	return PuzzleCatalog.pick_random([image_id])

# Saved games still in progress. Any save that turns out to be finished (completed in an older build, or
# the app was closed right at the end) is moved into the Collection instead of cluttering this list.
static func active_saves() -> Array:
	var active := []
	for entry in SaveManager.list_saves():
		if Collection.save_is_complete(entry.data):
			Collection.add(Collection.entry_from(entry.data, entry.slot, int(entry.data.get("elapsed_ms", 0)), int(entry.data.get("saved_at", 0)), false))
			SaveManager.delete_slot(entry.slot)
		else:
			active.append(entry)
	return active
