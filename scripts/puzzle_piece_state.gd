class_name PuzzlePieceState
extends RefCounted

# All game-relevant piece data lives here. A future host can own these mutations.
var piece_id: int
var row: int
var column: int
var correct_position: Vector2
var current_position: Vector2
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
var edge_contours: Array = [] # Top, right, bottom, left in local piece coordinates.

func snapshot() -> Dictionary:
	return {
		"piece_id": piece_id, "position": [current_position.x, current_position.y],
		"rotation": current_rotation, "snapped": is_snapped,
		"cluster_id": cluster_id,
		"on_table": is_on_table, "tray_id": tray_id,
		"owner_peer_id": owner_peer_id
	}
