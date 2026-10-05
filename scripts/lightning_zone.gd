class_name LightningZone
extends RefCounted

# The Lightning Zone: a rectangle of whole puzzle cells printed on the board. Once every cell in it belongs to
# the main puzzle (see PuzzleManager.is_in_main_puzzle) it activates, once, and lightning places `strikes`
# more pieces. A bigger zone means more work to charge, so it pays out more strikes.
# This class is just the zone's data and rules; LightningController runs it and LightningView draws it.

enum Tier { SMALL, MEDIUM, LARGE }

const TIER_WEIGHTS := [45, 35, 20]
# Share of the puzzle's pieces the zone covers, kept between a floor and a ceiling so small puzzles get
# sensible zones and large ones don't get enormous ones.
const TIER_AREA_SHARE := [0.04, 0.08, 0.14]
const TIER_MIN_AREA := [4, 6, 9]
const TIER_MAX_AREA := [8, 16, 30]
const TIER_STRIKES := [Vector2i(3, 3), Vector2i(5, 6), Vector2i(8, 10)]
const MAX_ZONE_SHARE := 0.4 # a zone never covers more than this share of the puzzle
const MAX_STRIKE_SHARE := 0.5 # ...and never strikes more than this share of the pieces outside it

var columns := 0 # the puzzle grid this zone belongs to
var rows := 0
var column := 0 # top-left cell of the zone
var row := 0
var width := 0 # size in cells
var height := 0
var tier := Tier.SMALL
var strikes := 0
var activated := false

static func make(grid_columns: int, grid_rows: int, zone_column: int, zone_row: int, zone_width: int, zone_height: int, strike_count: int, zone_tier: int = Tier.SMALL) -> LightningZone:
	var zone := LightningZone.new()
	zone.columns = grid_columns
	zone.rows = grid_rows
	zone.column = zone_column
	zone.row = zone_row
	zone.width = zone_width
	zone.height = zone_height
	zone.strikes = strike_count
	zone.tier = zone_tier
	return zone

# A random zone for a fresh puzzle on a `grid_columns` x `grid_rows` grid.
static func random(grid_columns: int, grid_rows: int, rng: RandomNumberGenerator) -> LightningZone:
	var total := grid_columns * grid_rows
	var zone_tier := _weighted_tier(rng)
	var target_area := clampi(roundi(total * TIER_AREA_SHARE[zone_tier]), TIER_MIN_AREA[zone_tier], TIER_MAX_AREA[zone_tier])
	var dims := _pick_dimensions(grid_columns, grid_rows, target_area, int(total * MAX_ZONE_SHARE), rng)
	var strike_range: Vector2i = TIER_STRIKES[zone_tier]
	var strike_count := rng.randi_range(strike_range.x, strike_range.y)
	strike_count = mini(strike_count, maxi(1, int((total - dims.x * dims.y) * MAX_STRIKE_SHARE)))
	return make(grid_columns, grid_rows, rng.randi_range(0, grid_columns - dims.x), rng.randi_range(0, grid_rows - dims.y), dims.x, dims.y, strike_count, zone_tier)

static func _weighted_tier(rng: RandomNumberGenerator) -> int:
	var roll := rng.randi_range(0, 99)
	var running := 0
	for i in range(TIER_WEIGHTS.size()):
		running += TIER_WEIGHTS[i]
		if roll < running:
			return i
	return Tier.SMALL

# A width and height (at least 2 cells each, never a whole side of the board) whose area is close to
# `target_area` and whose shape roughly follows the board's. Falls back to the closest area available.
static func _pick_dimensions(grid_columns: int, grid_rows: int, target_area: int, max_area: int, rng: RandomNumberGenerator) -> Vector2i:
	var grid_aspect := float(grid_columns) / float(grid_rows)
	var tolerance := maxi(1, roundi(target_area * 0.25))
	var good := []
	var closest := Vector2i(2, 2)
	var closest_gap := 1000000
	for w in range(2, grid_columns):
		for h in range(2, grid_rows):
			var area := w * h
			if area > max_area:
				continue
			var gap := absi(area - target_area)
			var aspect := float(w) / float(h)
			if gap <= tolerance and aspect >= grid_aspect * 0.5 and aspect <= grid_aspect * 2.0:
				good.append(Vector2i(w, h))
			if gap < closest_gap:
				closest_gap = gap
				closest = Vector2i(w, h)
	if good.is_empty():
		return closest
	return good[rng.randi_range(0, good.size() - 1)]

func cell_count() -> int:
	return width * height

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
	return {"column": column, "row": row, "width": width, "height": height, "tier": tier, "strikes": strikes, "activated": activated}

# Rebuilds a zone from a save or a host's sync; null when the data is missing or does not fit the grid.
static func from_dict(data: Dictionary, grid_columns: int, grid_rows: int) -> LightningZone:
	for key in ["column", "row", "width", "height", "strikes"]:
		if not data.has(key):
			return null
	var zone := make(grid_columns, grid_rows, int(data.column), int(data.row), int(data.width), int(data.height), int(data.strikes), int(data.get("tier", Tier.SMALL)))
	if zone.width < 1 or zone.height < 1 or zone.column < 0 or zone.row < 0 or zone.strikes < 0:
		return null
	if zone.column + zone.width > grid_columns or zone.row + zone.height > grid_rows:
		return null
	zone.activated = bool(data.get("activated", false))
	return zone
