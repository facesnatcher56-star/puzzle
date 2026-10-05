class_name PuzzleBoard
extends Node2D

# The pieces on the table: one view per placed piece, their selection, stacking order and the finder glow.
# It reacts to the PuzzleManager's state (create/position/refresh views) and offers table-level operations
# such as picking the piece under a point, nudging a dropped group clear of a hidden one, and spreading
# everything out. It never decides what a gesture means -- the input controller does.

const PIECE_SCENE: PackedScene = preload("res://scenes/puzzle_piece.tscn")

var manager: PuzzleManager
var session: PuzzleSession
var network: NetworkSession

var views := {} # piece id -> PuzzlePieceView for every piece on the table
var selected_id := -1
var highlight_kind := "" # "EDGES" or "CORNERS" while that bank button is hovered/pressed

func setup(p_manager: PuzzleManager, p_session: PuzzleSession, p_network: NetworkSession) -> void:
	manager = p_manager
	session = p_session
	network = p_network

func _ready() -> void:
	z_index = 1 # resting pieces' shadows sit at z 0, above the board but under every piece

# Removes every piece view. Views are detached immediately: a queued-free view would still be hit-tested
# until the end of the frame.
func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	views.clear()
	selected_id = -1

# --- keeping views in step with the manager ---

# Creates the view for a piece that just arrived on the table (placed here or by a remote player) and
# brings it up to date: position, rotation, joined sides, locked look and finder glow.
func on_piece_changed(piece_id: int) -> void:
	var piece := manager.get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return
	if not views.has(piece_id):
		var new_view: PuzzlePieceView = PIECE_SCENE.instantiate()
		add_child(new_view)
		new_view.table_mode = true
		new_view.manager = manager
		new_view.setup(piece, session.source, piece.piece_size)
		views[piece_id] = new_view
	views[piece_id].place_centered(piece.current_position + piece.piece_size * 0.5)
	views[piece_id].refresh_seams()
	views[piece_id].set_locked(piece.is_locked)
	if highlight_kind != "":
		refresh_type_highlight()

# --- picking and selecting ---

func pick(world: Vector2) -> int:
	var children := get_children()
	for i in range(children.size() - 1, -1, -1):
		var view := children[i] as PuzzlePieceView
		if view != null and view.hit_test(world):
			return view.data.piece_id
	return -1

# Selects the group containing `piece_id` (-1 clears the selection).
func select(piece_id: int) -> void:
	for view in views.values():
		view.set_selected(false)
	selected_id = piece_id
	if piece_id >= 0:
		for member_id in manager.cluster_members(piece_id):
			if views.has(member_id):
				views[member_id].set_selected(true)

# --- stacking ---

func bring_cluster_forward(piece_id: int) -> void:
	for member_id in manager.cluster_members(piece_id):
		if views.has(member_id):
			views[member_id].move_to_front()
			views[member_id].z_index = 10

func set_cluster_z(piece_id: int, value: int) -> void:
	for member_id in manager.cluster_members(piece_id):
		if views.has(member_id):
			views[member_id].z_index = value

# Locked sections form the base layer; above them bigger groups sit underneath smaller ones, so a loose
# piece can never be buried under a finished chunk of the puzzle. Same-size groups keep their recency
# order (last touched on top).
func restack() -> void:
	var entries := []
	var children := get_children()
	for i in range(children.size()):
		var view := children[i] as PuzzlePieceView
		if view != null:
			entries.append({"view": view, "size": manager.cluster_members(view.data.piece_id).size(), "index": i, "locked": manager.is_locked(view.data.piece_id)})
	entries.sort_custom(func(a, b):
		if a.locked != b.locked:
			return a.locked
		return a.size > b.size or (a.size == b.size and a.index < b.index))
	for i in range(entries.size()):
		move_child(entries[i].view, i)

# --- geometry helpers ---

# Bounding box, in world space, of the whole group containing `piece_id`.
func cluster_rect(piece_id: int) -> Rect2:
	var rect := Rect2()
	var started := false
	for member_id in manager.cluster_members(piece_id):
		var member: PuzzlePieceState = manager.pieces[member_id]
		var center := member.piece_size * 0.5
		var angle := deg_to_rad(member.current_rotation)
		for point in member.outline:
			var world := member.current_position + center + (point - center).rotated(angle)
			if not started:
				rect = Rect2(world, Vector2.ZERO)
				started = true
			else:
				rect = rect.expand(world)
	return rect

# Loose pieces must never end up hidden: a dropped group that would almost completely cover another
# group of the same size is moved aside (bigger groups already sit underneath smaller ones, see restack).
func nudge_clear_of_covered(piece_id: int) -> void:
	var piece := manager.get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return
	var my_size := manager.cluster_members(piece_id).size()
	var mine := cluster_rect(piece_id)
	var step := minf(session.cell.x, session.cell.y) * 0.25
	var total := Vector2.ZERO
	for key in manager.clusters.keys():
		var members: Array = manager.clusters[key]
		if piece.cluster_id == key or members.size() != my_size or manager.is_locked(members[0]):
			continue
		var other := cluster_rect(members[0])
		var other_area := other.get_area()
		if other_area <= 0.0 or mine.intersection(other).get_area() < other_area * 0.55:
			continue
		var direction := mine.get_center() - other.get_center()
		if direction.length() < 1.0:
			direction = Vector2.RIGHT.rotated(randf() * TAU)
		direction = direction.normalized()
		for i in range(60):
			if mine.intersection(other).get_area() < other_area * 0.2:
				break
			mine.position += direction * step
			total += direction * step
	if total != Vector2.ZERO:
		network.request_move(piece_id, piece.current_position + total)

# Lays every loose group out in rows beside the board. Locked sections stay where they are.
func spread() -> void:
	var group_ids := manager.clusters.keys()
	if group_ids.is_empty():
		return
	group_ids.sort()
	var board_size := session.board_size
	var origin := Vector2(board_size.x * 0.62, -board_size.y * 0.42)
	var cursor := origin
	var row_height := 0.0
	var available_width := board_size.x * 1.7
	var gap := minf(session.cell.x, session.cell.y) * 0.72
	for group_id in group_ids:
		var members: Array = manager.clusters[group_id]
		var first: PuzzlePieceState = manager.pieces[members[0]]
		if first.is_locked:
			continue
		var bounds := Rect2(first.current_position + first.piece_size * 0.5, Vector2.ZERO)
		for member_id in members:
			var member: PuzzlePieceState = manager.pieces[member_id]
			var member_center := member.piece_size * 0.5
			for point in member.outline:
				var world_point := member.current_position + member_center + (point - member_center).rotated(deg_to_rad(member.current_rotation))
				bounds = bounds.expand(world_point)
		if cursor.x > origin.x and cursor.x + bounds.size.x > origin.x + available_width:
			cursor = Vector2(origin.x, cursor.y + row_height)
			row_height = 0
		network.request_move(first.piece_id, first.current_position + cursor - bounds.position)
		cursor.x += bounds.size.x + gap
		row_height = maxf(row_height, bounds.size.y + gap)

# --- finder glow ---

# Glows every loose (not joined to anything) piece of the given type ("EDGES", "CORNERS" or "" for none).
func set_type_highlight(kind: String) -> void:
	highlight_kind = kind
	refresh_type_highlight()

func refresh_type_highlight() -> void:
	for piece_id in views:
		var piece := manager.get_piece(piece_id)
		var lit := highlight_kind != "" and piece != null and manager.cluster_members(piece_id).size() == 1 and (piece.is_corner_piece if highlight_kind == "CORNERS" else piece.is_edge_piece)
		views[piece_id].set_flagged(lit)
