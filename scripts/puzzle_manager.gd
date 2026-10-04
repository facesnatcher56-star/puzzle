class_name PuzzleManager
extends RefCounted

signal piece_changed(piece_id: int)
signal bank_changed
signal pieces_joined(cluster_id: int, member_ids: Array)
signal puzzle_completed

var pieces: Array[PuzzlePieceState] = []
var cell_size := Vector2.ONE
var columns := 0
var rows := 0
var started_at := 0
var clusters := {} # Cluster ID -> piece IDs; the lowest piece ID survives a merge.
var completion_announced := false

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
		if owner != 0 and owner != player_id:
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

func request_move(piece_id: int, position: Vector2) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return false
	var delta := position - piece.current_position
	for member_id in cluster_members(piece_id):
		pieces[member_id].current_position += delta
		piece_changed.emit(member_id)
	return true

func request_rotate(piece_id: int) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return false
	var members := cluster_members(piece_id)
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
	return true

func request_release(piece_id: int, player_id: int = 0) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or not piece.is_on_table or piece.owner_peer_id != player_id:
		return false
	for member_id in cluster_members(piece_id):
		pieces[member_id].owner_peer_id = 0
	return snap_piece(piece_id)

# Used when a networked peer disconnects mid-drag so their held pieces don't stay locked forever.
func release_pieces_owned_by(player_id: int) -> void:
	if player_id == 0:
		return
	var held := []
	for piece in pieces:
		if piece.owner_peer_id == player_id:
			held.append(piece.piece_id)
	for piece_id in held:
		request_release(piece_id, player_id)

# A joint requires correct neighboring IDs, complementary edges, equal rotation,
# and almost coincident edge contours. The board's world position is irrelevant.
func snap_piece(piece_id: int) -> bool:
	var piece := get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return false
	var joined_any := false
	var moving_cluster: int = piece.cluster_id
	var contact_tolerance := minf(cell_size.x, cell_size.y) * 0.15
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
	if not completion_announced and pieces.size() > 0 and table_count() == pieces.size() and clusters.size() == 1:
		completion_announced = true
		puzzle_completed.emit()
	return joined_any

func _edges_touch(a: PuzzlePieceState, side: int, b: PuzzlePieceState) -> bool:
	var a_edge := _world_edge(a, side)
	var b_edge := _world_edge(b, (side + 2) % 4)
	var tolerance_squared := pow(maxf(2.0, minf(cell_size.x, cell_size.y) * 0.035), 2)
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
