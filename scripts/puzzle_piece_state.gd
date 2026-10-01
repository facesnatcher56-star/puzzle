class_name PuzzlePieceState
extends RefCounted

# All game-relevant piece data lives here. A future host can own these mutations.
var piece_id: int
var row: int
var column: int
var correct_position: Vector2
var current_position: Vector2
# This piece's own width/height -- pieces are no longer all identical, so any code
# that used to assume a single board-wide cell size must use this instead.
var piece_size: Vector2 = Vector2.ONE
var correct_rotation: int = 0
var current_rotation: int = 0
var top_edge: int
var right_edge: int
var bottom_edge: int
var left_edge: int
var is_edge_piece: bool
var is_corner_piece: bool
# Joined pieces stay movable with their cluster.
var is_snapped: bool = false
var is_on_table: bool = false
var cluster_id: int = -1
var tray_id: int = 0
var owner_peer_id: int = 0
var outline: PackedVector2Array
var uv: PackedVector2Array
# uv == (local point + uv_origin) * uv_scale, so a grown outline can be textured consistently.
var uv_origin := Vector2.ZERO
var uv_scale := Vector2.ONE
var edge_contours: Array = [] # Top, right, bottom, left in local piece coordinates.

func snapshot() -> Dictionary:
	return {
		"piece_id": piece_id, "position": [current_position.x, current_position.y],
		"rotation": current_rotation, "snapped": is_snapped,
		"cluster_id": cluster_id,
		"on_table": is_on_table, "tray_id": tray_id,
		"owner_peer_id": owner_peer_id
	}

# int fields are cast explicitly because a save file round-trips through JSON,
# which has no integer type and hands every number back as a float.
func apply_snapshot(data: Dictionary) -> void:
	current_position = Vector2(data.position[0], data.position[1])
	current_rotation = int(data.rotation)
	is_snapped = data.snapped
	cluster_id = int(data.cluster_id)
	is_on_table = data.on_table
	tray_id = int(data.tray_id)
	owner_peer_id = int(data.get("owner_peer_id", 0))
