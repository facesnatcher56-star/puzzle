class_name PuzzleManager
extends RefCounted

signal piece_changed(piece_id: int)
signal bank_changed
signal pieces_joined(cluster_id: int, member_ids: Array)
signal puzzle_completed
signal group_locked(cluster_id: int, member_ids: Array, side_names: Array)
signal main_puzzle_connected(piece_ids: Array, source: int)
signal loose_puzzle_connected(piece_count: int, member_ids: Array, source: int)
# A first-try placement is in progress: `piece_id` is a solo piece that has never been dropped near another piece,
# and the player has just let go of it. Joins that happen next belong to that attempt. `first_try_ended` follows
# once the drop is resolved; `missed` is true if it was dropped within snapping distance of another piece without joining.
signal first_try_started(piece_id: int)
signal first_try_ended(piece_id: int, missed: bool)

enum ConnectionSource { MANUAL, POWER }

# How far (as a share of the smaller cell side) a piece may sit from its true spot and still join. The contact
# check uses the same distance: with a tighter one, a shallow V-shaped tab -- whose contour stops touching its
# groove after about a third of that distance -- refused to join while square and round tabs joined fine.
const SNAP_TOLERANCE := 0.20

var pieces: Array[PuzzlePieceState] = []
var cell_size := Vector2.ONE
var columns := 0
var rows := 0
var started_at := 0
var clusters := {} # Cluster ID -> piece IDs; the lowest piece ID survives a merge.
var completion_announced := false
# The player whose action is being carried out right now (the one who let go of a piece, or whose power is moving
# pieces): scoring credits Charge and streak to them. 0 is the host or a solo player.
var acting_player := 0

func configure(states: Array[PuzzlePieceState], cell: Vector2, grid_columns: int, grid_rows: int) -> void:
	pieces = states
	cell_size = cell
	columns = grid_columns
	rows = grid_rows
	clusters.clear()
	completion_announced = false
	started_at = Time.get_ticks_msec()

func get_piece(piece_id: int) -> PuzzlePieceState:
	if piece_id < 0 or piece_id >= pieces.size():
		push_error("Invalid puzzle piece ID: %d" % piece_id)
		return null
	return pieces[piece_id]

func cluster_members(piece_id: int) -> Array:
	var piece := get_piece(piece_id)
	if piece == null or piece.cluster_id < 0:
		return []
	return clusters.get(piece.cluster_id, [])

# True when the piece on `side` is part of the same joined group, i.e. the two share a seam that is closed for good.
func is_joined_side(piece_id: int, side: int) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or not piece.is_on_table or piece.cluster_id < 0:
		return false
	var neighbor_id := _correct_neighbor(piece, side)
	if neighbor_id < 0:
		return false
	var neighbor: PuzzlePieceState = pieces[neighbor_id]
	return neighbor.is_on_table and neighbor.cluster_id == piece.cluster_id

func request_place_from_bank(piece_id: int, position: Vector2, player_id: int = 0) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or piece.is_on_table:
		return false
	piece.is_on_table = true
	piece.current_position = position
	piece.cluster_id = piece_id
	piece.owner_peer_id = player_id
	clusters[piece_id] = [piece_id]
	piece_changed.emit(piece_id)
	bank_changed.emit()
	return true

func request_pickup(piece_id: int, player_id: int = 0) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return false
	var members := cluster_members(piece_id)
	for member_id in members:
		var owner: int = pieces[member_id].owner_peer_id
		if pieces[member_id].is_locked or (owner != 0 and owner != player_id):
			return false
	for member_id in members:
		pieces[member_id].owner_peer_id = player_id
	return true

# True when nobody else is holding any piece of this group, so `player_id` may act on it.
func is_free_for(piece_id: int, player_id: int) -> bool:
	for member_id in cluster_members(piece_id):
		var owner: int = pieces[member_id].owner_peer_id
		if owner != 0 and owner != player_id:
			return false
	return true

func is_locked(piece_id: int) -> bool:
	var piece := get_piece(piece_id)
	return piece != null and piece.is_locked

func request_move(piece_id: int, position: Vector2) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return false
	if piece.is_locked:
		return false
	var delta := position - piece.current_position
	for member_id in cluster_members(piece_id):
		pieces[member_id].current_position += delta
		piece_changed.emit(member_id)
	return true

func request_rotate(piece_id: int) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or not piece.is_on_table or piece.is_locked:
		return false
	_rotate_group(cluster_members(piece_id))
	return true

# Turns a joined group a quarter turn clockwise about its own middle.
func _rotate_group(members: Array) -> void:
	var pivot := Vector2.ZERO
	for member_id in members:
		var member: PuzzlePieceState = pieces[member_id]
		pivot += member.current_position + member.piece_size * 0.5
	pivot /= members.size()
	for member_id in members:
		var member: PuzzlePieceState = pieces[member_id]
		var center := member.current_position + member.piece_size * 0.5
		member.current_position = pivot + (center - pivot).rotated(PI * 0.5) - member.piece_size * 0.5
		member.current_rotation = (member.current_rotation + 90) % 360
		piece_changed.emit(member_id)

func request_release(piece_id: int, player_id: int = 0, count_failed_attempt: bool = true) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or not piece.is_on_table or piece.is_locked or piece.owner_peer_id != player_id:
		return false
	# `count_failed_attempt` is false for a drop that was not a deliberate placement (a menu opened mid-drag, or the
	# group was barely moved). A deliberate drop of a solo piece that has never been near another piece is the one
	# chance at a first-try placement; dropping it anywhere not near another piece, as often as you like, costs nothing.
	var previous_actor := acting_player
	acting_player = player_id
	var group := cluster_members(piece_id)
	var eligible := count_failed_attempt and group.size() == 1 and not piece.attempted
	var near := count_failed_attempt and _near_other_piece(piece_id)
	if eligible:
		first_try_started.emit(piece_id)
	for member_id in group:
		pieces[member_id].owner_peer_id = 0
	var joined := snap_piece(piece_id)
	var attached := piece.is_locked or cluster_members(piece_id).size() > 1
	var missed := near and not attached
	if missed:
		for member_id in group:
			pieces[member_id].attempted = true
	if eligible:
		first_try_ended.emit(piece_id, missed)
	acting_player = previous_actor
	return joined

# Used when a networked peer disconnects mid-drag so their held pieces don't stay locked forever.
func release_pieces_owned_by(player_id: int) -> void:
	if player_id == 0:
		return
	var held := []
	for piece in pieces:
		if piece.owner_peer_id == player_id:
			held.append(piece.piece_id)
	for piece_id in held:
		request_release(piece_id, player_id, false)

# A joint requires correct neighboring IDs, complementary edges, equal rotation,
# and almost coincident edge contours. The board's world position is irrelevant.
func snap_piece(piece_id: int, source: int = ConnectionSource.MANUAL) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return false
	var joined_any := false
	var loose_join_count := 0
	var moving_cluster: int = piece.cluster_id
	var contact_tolerance := minf(cell_size.x, cell_size.y) * SNAP_TOLERANCE
	while true:
		var best_target := -1
		var best_offset := Vector2.ZERO
		var best_distance := contact_tolerance + 0.001
		for member_id in clusters[moving_cluster]:
			var member: PuzzlePieceState = pieces[member_id]
			for side in range(4):
				var neighbor_id := _correct_neighbor(member, side)
				if neighbor_id < 0:
					continue
				var neighbor: PuzzlePieceState = pieces[neighbor_id]
				if not neighbor.is_on_table or neighbor.cluster_id == moving_cluster or neighbor.current_rotation != member.current_rotation:
					continue
				if _edge_type(member, side) == 0 or _edge_type(member, side) != -_edge_type(neighbor, (side + 2) % 4):
					continue
				# Pieces turn about their own centers, and neighbors differ in size, so the offset between their
				# stored (top-left) positions is the rotated center offset minus the size difference -- not the
				# rotated top-left offset, which lands rotated pieces several pixels out of true.
				var correct_center_delta := (neighbor.correct_position + neighbor.piece_size * 0.5) - (member.correct_position + member.piece_size * 0.5)
				var expected := correct_center_delta.rotated(deg_to_rad(member.current_rotation)) - (neighbor.piece_size - member.piece_size) * 0.5
				var offset := neighbor.current_position - member.current_position - expected
				var distance := offset.length()
				if distance <= contact_tolerance and distance < best_distance and _edges_touch(member, side, neighbor):
					best_distance = distance
					best_target = neighbor.cluster_id
					best_offset = offset
		if best_target < 0:
			break
		var moved_members: Array = clusters[moving_cluster]
		for member_id in moved_members:
			pieces[member_id].current_position += best_offset
		var other_members: Array = clusters[best_target]
		if not pieces[moved_members[0]].is_locked and not pieces[other_members[0]].is_locked:
			loose_join_count += mini(moved_members.size(), other_members.size())
		var merged: Array = moved_members.duplicate()
		merged.append_array(other_members)
		merged.sort()
		var new_id: int = mini(moving_cluster, best_target)
		clusters.erase(moving_cluster)
		clusters.erase(best_target)
		clusters[new_id] = merged
		for member_id in merged:
			var member: PuzzlePieceState = pieces[member_id]
			member.cluster_id = new_id
			member.is_snapped = true
			piece_changed.emit(member_id)
		moving_cluster = new_id
		joined_any = true
		pieces_joined.emit(new_id, merged.duplicate())
	var locked_before := locked_count()
	_try_lock(moving_cluster, source)
	if loose_join_count > 0 and locked_count() == locked_before:
		loose_puzzle_connected.emit(loose_join_count, clusters[moving_cluster].duplicate(), source)
	if not completion_announced and pieces.size() > 0 and table_count() == pieces.size() and clusters.size() == 1:
		completion_announced = true
		puzzle_completed.emit()
	return joined_any

# --- Locking to the board ---
# A correctly placed corner anchors its cluster immediately. Any group that later joins
# a locked anchor becomes part of the immovable main puzzle.

func corner_ids() -> Array:
	if columns < 2 or rows < 2:
		return []
	return [0, columns - 1, (rows - 1) * columns, rows * columns - 1]

func anchored_corner_count() -> int:
	var count := 0
	for id in corner_ids():
		if pieces[id].is_locked:
			count += 1
	return count

# Names of the border sides this group fully contains ("TOP", "BOTTOM", "LEFT", "RIGHT").
func complete_sides(member_ids: Array) -> Array:
	var have := {}
	for id in member_ids:
		have[id] = true
	var sides := []
	var top := true
	var bottom := true
	for c in range(columns):
		top = top and have.has(c)
		bottom = bottom and have.has((rows - 1) * columns + c)
	var left := true
	var right := true
	for r in range(rows):
		left = left and have.has(r * columns)
		right = right and have.has(r * columns + columns - 1)
	if top:
		sides.append("TOP")
	if bottom:
		sides.append("BOTTOM")
	if left:
		sides.append("LEFT")
	if right:
		sides.append("RIGHT")
	return sides

# --- Lightning ---
# The "main puzzle" is every locked piece: the sections bolted to the board, which is where a group ends up
# once it holds a whole side of the border and everything that has joined it since.

func is_in_main_puzzle(piece_id: int) -> bool:
	return is_locked(piece_id)

# The pieces lightning may strike: not yet part of the main puzzle, not held by a player, and belonging to a
# group (a loose piece is a group of one, in the bank or on the table) that has a member sitting right
# beside the main puzzle -- so wherever it lands, it joins. Struck groups are never torn apart: any piece of
# a group is as good a target as another, so a big group is proportionally more likely to be hit.
func lightning_targets() -> Array:
	var wanted := {} # group key -> true
	for piece in pieces:
		if not piece.is_locked:
			continue
		for side in range(4):
			var neighbor_id := _correct_neighbor(piece, side)
			if neighbor_id >= 0 and not pieces[neighbor_id].is_locked:
				wanted[_group_key(pieces[neighbor_id])] = true
	var targets := []
	for piece in pieces:
		if piece.is_locked or not wanted.has(_group_key(piece)):
			continue
		if _group_is_held(piece):
			continue
		targets.append(piece.piece_id)
	return targets

# Moves the group containing `piece_id` (or the lone piece, fetched from the bank if need be) so that this
# piece sits exactly where it belongs and upright, keeping every join inside the group, then joins it to the
# main puzzle. Returns the ids of the pieces that were moved (empty if the piece is already in the main puzzle).
func strike_piece(piece_id: int) -> Array:
	var piece := get_piece(piece_id)
	if piece == null or piece.is_locked:
		return []
	var from_bank := not piece.is_on_table
	var moved: Array
	if from_bank:
		piece.is_on_table = true
		piece.cluster_id = piece_id
		piece.current_rotation = 0
		clusters[piece_id] = [piece_id]
		moved = [piece_id]
	else:
		moved = cluster_members(piece_id).duplicate()
		while piece.current_rotation != 0:
			_rotate_group(moved)
	# A group's pieces already sit in their true relative places, so putting each at its own spot is the same
	# as sliding the whole group by one offset; doing it per piece just keeps the result free of drift.
	for member_id in moved:
		var member: PuzzlePieceState = pieces[member_id]
		member.current_position = member.correct_position
		member.owner_peer_id = 0
		piece_changed.emit(member_id)
	if from_bank:
		bank_changed.emit()
	snap_piece(piece_id, ConnectionSource.POWER)
	return moved

# --- Cluster Surge ---
# The player's own power: pull the correct neighbours of a chosen group onto it. Unlike Lightning and Magnet,
# which put things where they belong on the board, a Surge joins neighbours to the group *where it sits* -- a
# loose island grows in place -- and when the group is part of the main puzzle that is the same thing as the
# neighbour's true place on the board.

# The neighbours a Surge on `piece_id`'s group could pull: one entry per neighbouring group that is outside the
# main puzzle and not held, as {piece, member, side} -- `piece` is the neighbour touching `member`'s `side`.
func surge_targets(piece_id: int) -> Array:
	var piece := get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return []
	var group := cluster_members(piece_id)
	var seen := {}
	var found := []
	for member_id in group:
		var member: PuzzlePieceState = pieces[member_id]
		for side in range(4):
			var neighbor_id := _correct_neighbor(member, side)
			if neighbor_id < 0:
				continue
			var neighbor: PuzzlePieceState = pieces[neighbor_id]
			if neighbor.is_locked or _group_is_held(neighbor):
				continue
			if neighbor.is_on_table and neighbor.cluster_id == member.cluster_id:
				continue
			var key := _group_key(neighbor)
			if seen.has(key):
				continue
			seen[key] = true
			found.append({"piece": neighbor_id, "member": member_id, "side": side})
	return found

# The edges of the group where a Surge could pull something in, as world-space polylines (for a faint preview).
func surge_seams(piece_id: int) -> Array:
	var seams := []
	for target in surge_targets(piece_id):
		seams.append(world_edge(pieces[target.member], target.side))
	return seams

# Brings the neighbour `target_id` onto `anchor_id`'s group: the neighbour's whole group (or the lone piece, fetched
# from the bank) is turned to match, slid so that it sits exactly beside the anchor's group, and joined to it.
# Returns the ids of the pieces that moved (empty if the neighbour is not eligible any more).
func pull_to_group(target_id: int, anchor_id: int) -> Array:
	var target := get_piece(target_id)
	var anchor := get_piece(anchor_id)
	if target == null or anchor == null or target.is_locked or not anchor.is_on_table:
		return []
	if target.is_on_table and target.cluster_id == anchor.cluster_id:
		return []
	# the member of the anchor's group that touches the target on the board
	var touching := -1
	for member_id in cluster_members(anchor_id):
		for side in range(4):
			if _correct_neighbor(pieces[member_id], side) == target_id:
				touching = member_id
	if touching < 0:
		return []
	if anchor.is_locked:
		return strike_piece(target_id)
	var base: PuzzlePieceState = pieces[touching]
	var from_bank := not target.is_on_table
	var moved: Array
	if from_bank:
		target.is_on_table = true
		target.cluster_id = target_id
		clusters[target_id] = [target_id]
		target.current_rotation = base.current_rotation
		moved = [target_id]
	else:
		moved = cluster_members(target_id).duplicate()
		while target.current_rotation != base.current_rotation:
			_rotate_group(moved)
	var wanted_centre := base.current_position + base.piece_size * 0.5 + ((target.correct_position + target.piece_size * 0.5) - (base.correct_position + base.piece_size * 0.5)).rotated(deg_to_rad(base.current_rotation))
	var offset := wanted_centre - (target.current_position + target.piece_size * 0.5)
	for member_id in moved:
		var member: PuzzlePieceState = pieces[member_id]
		member.current_position += offset
		member.owner_peer_id = 0
		piece_changed.emit(member_id)
	if from_bank:
		bank_changed.emit()
	snap_piece(target_id, ConnectionSource.POWER)
	return moved

func world_edge(piece: PuzzlePieceState, side: int) -> PackedVector2Array:
	return _world_edge(piece, side)

func _group_key(piece: PuzzlePieceState) -> int:
	return piece.cluster_id if piece.is_on_table and piece.cluster_id >= 0 else -1 - piece.piece_id

func power_group_key(piece_id: int) -> int:
	return _group_key(pieces[piece_id])

func is_power_group_held(piece_id: int) -> bool:
	return _group_is_held(pieces[piece_id])

func _group_is_held(piece: PuzzlePieceState) -> bool:
	if not piece.is_on_table:
		return false
	for member_id in cluster_members(piece.piece_id):
		if pieces[member_id].owner_peer_id != 0:
			return true
	return false

# True when any piece of this group is within snapping distance of a piece that is not in the group: their
# outlines' boxes are no further apart than a piece may sit from its true spot and still join.
func _near_other_piece(piece_id: int) -> bool:
	var tolerance := minf(cell_size.x, cell_size.y) * SNAP_TOLERANCE
	var own := cluster_members(piece_id)
	for id in own:
		var member: PuzzlePieceState = pieces[id]
		var centre := member.current_position + member.piece_size * 0.5
		for other in pieces:
			if not other.is_on_table or other.cluster_id == member.cluster_id:
				continue
			var gap := (member.piece_size + other.piece_size) * 0.5 + Vector2(tolerance, tolerance)
			var apart := (other.current_position + other.piece_size * 0.5 - centre).abs()
			if apart.x <= gap.x and apart.y <= gap.y:
				return true
	return false

func _try_lock(cluster_id: int, source: int = ConnectionSource.MANUAL) -> void:
	if not clusters.has(cluster_id):
		return
	var members: Array = clusters[cluster_id]
	var already := false
	for id in members:
		already = already or pieces[id].is_locked
	var sides := []
	if not already:
		var anchor_id := -1
		for id in corner_ids():
			if members.has(id):
				anchor_id = id
				break
		if anchor_id < 0:
			return
		sides = complete_sides(members)
		var anchor: PuzzlePieceState = pieces[anchor_id]
		var tolerance := minf(cell_size.x, cell_size.y) * 0.45
		for id in members:
			if pieces[id].current_rotation != 0:
				return
		if (anchor.current_position - anchor.correct_position).length() > tolerance:
			return
	var newly_locked := []
	for id in members:
		var member: PuzzlePieceState = pieces[id]
		if not member.is_locked:
			newly_locked.append(id)
		member.is_locked = true
		member.current_position = member.correct_position
		member.current_rotation = 0
		member.owner_peer_id = 0
		member.is_snapped = true
	for id in members:
		piece_changed.emit(id)
	if not newly_locked.is_empty():
		main_puzzle_connected.emit(newly_locked.duplicate(), source)
		group_locked.emit(cluster_id, members.duplicate(), sides)

func locked_count() -> int:
	var count := 0
	for piece in pieces:
		if piece.is_locked:
			count += 1
	return count

func _edges_touch(a: PuzzlePieceState, side: int, b: PuzzlePieceState) -> bool:
	var a_edge := _world_edge(a, side)
	var b_edge := _world_edge(b, (side + 2) % 4)
	var tolerance_squared := pow(maxf(2.0, minf(cell_size.x, cell_size.y) * SNAP_TOLERANCE), 2)
	for i in range(a_edge.size() - 1):
		for j in range(b_edge.size() - 1):
			if Geometry2D.segment_intersects_segment(a_edge[i], a_edge[i + 1], b_edge[j], b_edge[j + 1]) != null:
				return true
			if _point_segment_distance_squared(a_edge[i], b_edge[j], b_edge[j + 1]) <= tolerance_squared:
				return true
			if _point_segment_distance_squared(b_edge[j], a_edge[i], a_edge[i + 1]) <= tolerance_squared:
				return true
	return false

func _world_edge(piece: PuzzlePieceState, side: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	var center := piece.piece_size * 0.5
	var angle := deg_to_rad(piece.current_rotation)
	for point in piece.edge_contours[side]:
		result.append(piece.current_position + center + (point - center).rotated(angle))
	return result

func _point_segment_distance_squared(point: Vector2, start: Vector2, end: Vector2) -> float:
	var segment := end - start
	var length_squared := segment.length_squared()
	if length_squared < 0.000001:
		return point.distance_squared_to(start)
	var t := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_squared_to(start + segment * t)

func _correct_neighbor(piece: PuzzlePieceState, side: int) -> int:
	match side:
		0: return piece.piece_id - columns if piece.row > 0 else -1
		1: return piece.piece_id + 1 if piece.column < columns - 1 else -1
		2: return piece.piece_id + columns if piece.row < rows - 1 else -1
		3: return piece.piece_id - 1 if piece.column > 0 else -1
	return -1

func _edge_type(piece: PuzzlePieceState, side: int) -> int:
	match side:
		0: return piece.top_edge
		1: return piece.right_edge
		2: return piece.bottom_edge
		3: return piece.left_edge
	return 0

# Fully recomputes clusters from each piece's own cluster_id rather than replaying
# the host's incremental merge steps, so a client never has to reproduce that algebra.
func rebuild_clusters() -> void:
	clusters.clear()
	for piece in pieces:
		if piece.is_on_table and piece.cluster_id >= 0:
			clusters.get_or_add(piece.cluster_id, []).append(piece.piece_id)

# Applies authoritative snapshots (from a save file or a host's network sync) onto
# the current pieces array, which must already be configured with matching geometry.
func apply_snapshots(snapshots: Array) -> void:
	for data in snapshots:
		var piece := get_piece(int(data.piece_id))
		if piece != null:
			piece.apply_snapshot(data)
	rebuild_clusters()
	realign_clusters()
	completion_announced = pieces.size() > 0 and table_count() == pieces.size() and clusters.size() == 1
	for piece in pieces:
		piece_changed.emit(piece.piece_id)
	bank_changed.emit()

# Snaps every joined group back to its exact true layout, anchored on its lowest-numbered piece.
# Saves made by older builds could hold groups whose pieces had drifted a few pixels apart (rotated
# joins were computed slightly wrong), which showed up as gaps and mismatched seams inside a group.
func realign_clusters() -> void:
	for members in clusters.values():
		var any_locked := false
		for id in members:
			any_locked = any_locked or pieces[id].is_locked
		if any_locked:
			for id in members:
				pieces[id].is_locked = true
				pieces[id].current_position = pieces[id].correct_position
				pieces[id].current_rotation = 0
			continue
		if members.size() < 2:
			continue
		var anchor: PuzzlePieceState = pieces[members[0]]
		var angle := deg_to_rad(anchor.current_rotation)
		var anchor_drift := anchor.current_position + anchor.piece_size * 0.5 - (anchor.correct_position + anchor.piece_size * 0.5).rotated(angle)
		for i in range(1, members.size()):
			var member: PuzzlePieceState = pieces[members[i]]
			if member.current_rotation != anchor.current_rotation:
				continue
			var center := (member.correct_position + member.piece_size * 0.5).rotated(angle) + anchor_drift
			member.current_position = center - member.piece_size * 0.5

func move_piece_to_tray(piece_id: int, tray_id: int) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or piece.is_on_table:
		return false
	piece.tray_id = tray_id
	piece_changed.emit(piece_id)
	bank_changed.emit()
	return true

func table_count() -> int:
	var count := 0
	for piece in pieces:
		if piece.is_on_table:
			count += 1
	return count

func completed_count() -> int:
	var largest := 0
	for members in clusters.values():
		largest = maxi(largest, members.size())
	return largest

func elapsed_seconds() -> int:
	return int((Time.get_ticks_msec() - started_at) / 1000)
