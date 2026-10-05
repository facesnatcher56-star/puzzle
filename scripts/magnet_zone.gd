class_name MagnetZone
extends RefCounted

# A rectangular marking on the board. Its perimeter is fixed; attached pieces never extend its reach.
var columns := 0
var rows := 0
var column := 0
var row := 0
var width := 0
var height := 0
var activated := false

static func make(grid_columns: int, grid_rows: int, c: int, r: int, w: int, h: int) -> MagnetZone:
	var zone := MagnetZone.new()
	zone.columns = grid_columns
	zone.rows = grid_rows
	zone.column = c
	zone.row = r
	zone.width = w
	zone.height = h
	return zone

static func random(grid_columns: int, grid_rows: int, rng: RandomNumberGenerator, lightning: LightningZone) -> MagnetZone:
	var choices := []
	var total := grid_columns * grid_rows
	var desired := clampi(roundi(total * 0.08), 4, 12)
	for min_side in [2, 1]: # narrow zones are a fallback on the smallest grids
		for w in range(min_side, mini(grid_columns + 1, 5)):
			for h in range(min_side, mini(grid_rows + 1, 5)):
				if w * h < 2 or w * h > int(total * 0.25):
					continue
				for r in range(grid_rows - h + 1):
					for c in range(grid_columns - w + 1):
						if lightning != null and c < lightning.column + lightning.width and c + w > lightning.column and r < lightning.row + lightning.height and r + h > lightning.row:
							continue
						choices.append({"c": c, "r": r, "w": w, "h": h, "gap": absi(w * h - desired)})
		if not choices.is_empty():
			break
	if choices.is_empty():
		return null
	choices.sort_custom(func(a, b): return a.gap < b.gap)
	var best_gap: int = choices[0].gap
	var best := []
	for choice in choices:
		if choice.gap > best_gap:
			break
		best.append(choice)
	var picked: Dictionary = best[rng.randi_range(0, best.size() - 1)]
	return make(grid_columns, grid_rows, picked.c, picked.r, picked.w, picked.h)

func cell_ids() -> Array:
	var ids := []
	for r in range(row, row + height):
		for c in range(column, column + width):
			ids.append(r * columns + c)
	return ids

func perimeter_ids() -> Array:
	var ids := []
	for r in range(row, row + height):
		if column > 0:
			ids.append(r * columns + column - 1)
		if column + width < columns:
			ids.append(r * columns + column + width)
	for c in range(column, column + width):
		if row > 0:
			ids.append((row - 1) * columns + c)
		if row + height < rows:
			ids.append((row + height) * columns + c)
	return ids

func is_charged(manager: PuzzleManager) -> bool:
	for id in cell_ids():
		if id >= manager.pieces.size() or not manager.is_in_main_puzzle(id):
			return false
	return true

func world_rect(manager: PuzzleManager) -> Rect2:
	var first: PuzzlePieceState = manager.pieces[row * columns + column]
	var last: PuzzlePieceState = manager.pieces[(row + height - 1) * columns + column + width - 1]
	return Rect2(first.correct_position, last.correct_position + last.piece_size - first.correct_position)

func to_dict() -> Dictionary:
	return {"column": column, "row": row, "width": width, "height": height, "activated": activated}

static func from_dict(data: Dictionary, grid_columns: int, grid_rows: int) -> MagnetZone:
	for key in ["column", "row", "width", "height"]:
		if not data.has(key):
			return null
	var zone := make(grid_columns, grid_rows, int(data.column), int(data.row), int(data.width), int(data.height))
	if zone.width < 1 or zone.height < 1 or zone.width * zone.height < 2 or zone.column < 0 or zone.row < 0:
		return null
	if zone.column + zone.width > grid_columns or zone.row + zone.height > grid_rows:
		return null
	zone.activated = bool(data.get("activated", false))
	return zone
