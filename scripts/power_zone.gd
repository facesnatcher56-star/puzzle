class_name PowerZone
extends RefCounted

# One board-power zone: a rectangle of whole puzzle cells that does something once every one of its cells is
# part of the main puzzle (see PuzzleManager.is_in_main_puzzle).
#   LIGHTNING  strikes a number of unfinished places that grows with the zone's area.
#   MAGNET     pulls into place the pieces for every cell touching the zone's edge, so a bigger zone has a
#              longer edge and a bigger payoff.
# A zone fires once. QUEUED means it has been charged and its effect is still waiting its turn, so a save made
# at that moment can finish the job without ever charging it twice.
# This class is only data and rules; PowerController runs the zones and PowerView draws them.

enum Kind { LIGHTNING, MAGNET }
enum State { IDLE, QUEUED, DONE }

var kind := Kind.LIGHTNING
var columns := 0 # the puzzle grid this zone belongs to
var rows := 0
var column := 0 # top-left cell
var row := 0
var width := 1 # size in cells
var height := 1
var state := State.IDLE

static func make(grid_columns: int, grid_rows: int, zone_column: int, zone_row: int, zone_width: int, zone_height: int, zone_kind: int) -> PowerZone:
	var zone := PowerZone.new()
	zone.columns = grid_columns
	zone.rows = grid_rows
	zone.column = zone_column
	zone.row = zone_row
	zone.width = zone_width
	zone.height = zone_height
	zone.kind = zone_kind
	return zone

func area() -> int:
	return width * height

func is_used() -> bool:
	return state != State.IDLE

# How many places a Lightning zone strikes: more work to charge, more strikes.
static func strikes_for_area(cells: int) -> int:
	if cells <= 1:
		return 1
	if cells <= 3:
		return 2
	if cells <= 6:
		return 3
	if cells <= 11:
		return 5
	if cells <= 19:
		return 7
	return 9 if cells < 30 else 10

func strike_count() -> int:
	return strikes_for_area(area())

# Piece ids (row * columns + column) of the cells the zone covers.
func cell_ids() -> Array:
	var ids := []
	for r in range(row, row + height):
		for c in range(column, column + width):
			ids.append(r * columns + c)
	return ids

func contains_cell(piece_id: int) -> bool:
	var c := piece_id % columns
	var r := piece_id / columns
	return c >= column and c < column + width and r >= row and r < row + height

# The cells that share an edge with the zone but are not in it: what a Magnet pulls in.
func perimeter_ids() -> Array:
	var ids := []
	for c in range(column, column + width):
		if row > 0:
			ids.append((row - 1) * columns + c)
		if row + height < rows:
			ids.append((row + height) * columns + c)
	for r in range(row, row + height):
		if column > 0:
			ids.append(r * columns + column - 1)
		if column + width < columns:
			ids.append(r * columns + column + width)
	return ids

# True when every cell of the zone is part of the main puzzle. Pieces merely lying over the zone's spots do
# not count -- they have to be joined to the board.
func is_charged(manager: PuzzleManager) -> bool:
	for id in cell_ids():
		if id >= manager.pieces.size() or not manager.is_in_main_puzzle(id):
			return false
	return true

# The zone's footprint in board coordinates (the same space as PuzzlePieceState.correct_position).
func world_rect(manager: PuzzleManager) -> Rect2:
	var first: PuzzlePieceState = manager.pieces[row * columns + column]
	var last: PuzzlePieceState = manager.pieces[(row + height - 1) * columns + column + width - 1]
	return Rect2(first.correct_position, last.correct_position + last.piece_size - first.correct_position)

func to_dict() -> Dictionary:
	return {"kind": kind, "column": column, "row": row, "width": width, "height": height, "state": state}

# Rebuilds a zone from a save or a host's sync; null when the data does not fit the grid.
static func from_dict(data: Dictionary, grid_columns: int, grid_rows: int) -> PowerZone:
	for key in ["kind", "column", "row", "width", "height"]:
		if not data.has(key):
			return null
	var zone := make(grid_columns, grid_rows, int(data.column), int(data.row), int(data.width), int(data.height), int(data.kind))
	if zone.width < 1 or zone.height < 1 or zone.column < 0 or zone.row < 0:
		return null
	if zone.column + zone.width > grid_columns or zone.row + zone.height > grid_rows:
		return null
	if zone.kind != Kind.LIGHTNING and zone.kind != Kind.MAGNET:
		return null
	zone.state = clampi(int(data.get("state", State.IDLE)), State.IDLE, State.DONE)
	return zone

# A saved list of zones; zones that do not fit the grid or overlap an earlier one are dropped.
static func list_from(data, grid_columns: int, grid_rows: int) -> Array:
	var zones := []
	if typeof(data) != TYPE_ARRAY:
		return zones
	var taken := {}
	for entry in data:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var zone := from_dict(entry, grid_columns, grid_rows)
		if zone == null:
			continue
		var clash := false
		for id in zone.cell_ids():
			clash = clash or taken.has(id)
		if clash:
			continue
		for id in zone.cell_ids():
			taken[id] = true
		zones.append(zone)
	return zones

static func list_to_data(zones: Array) -> Array:
	var data := []
	for zone in zones:
		data.append(zone.to_dict())
	return data

# The zones of a save: its "zones" list, or -- for a save made when a puzzle had one Lightning and one Magnet
# zone -- those two, so an unfinished game keeps its markings.
static func zones_from_save(saved: Dictionary, grid_columns: int, grid_rows: int) -> Array:
	if saved.has("zones"):
		return list_from(saved.zones, grid_columns, grid_rows)
	var legacy := []
	for entry in [["lightning", Kind.LIGHTNING], ["magnet", Kind.MAGNET]]:
		var data = saved.get(entry[0], null)
		if typeof(data) != TYPE_DICTIONARY:
			continue
		var upgraded: Dictionary = data.duplicate()
		upgraded["kind"] = entry[1]
		upgraded["state"] = State.DONE if bool(data.get("activated", false)) else State.IDLE
		legacy.append(upgraded)
	return list_from(legacy, grid_columns, grid_rows)
