class_name PowerLayout
extends RefCounted

# Lays power zones out over a puzzle: about COVERAGE of the cells end up in some zone, zones never overlap but
# like to touch, small ones are common and big ones rare -- except that a big enough puzzle is always given a
# few big ones, so a board is never fifty 1x1s with nothing impressive on it. Lightning and Magnet are mixed
# roughly evenly without being rigid about it.
# The zones are also spread: the board is divided into regions, each new zone is steered toward the regions that
# have the least covered so far, and a last pass fills any region left thin, so there is no big dead area and no
# side of the board without powers.

const COVERAGE := 0.6
const MAX_AREA_SHARE := 0.12 # no zone covers more than this share of the puzzle (but a small one always may reach 4 cells)
const MAX_OVERSHOOT := 1 # a zone may take the coverage this many cells past the target
const KIND_SHARE_LIMIT := 0.62 # neither kind covers more than this share of the powered cells
const NEED_WEIGHT := 9.0 # how strongly a zone is drawn to under-covered parts of the board (contact is worth at most 4)
const MIN_REGION_COVERAGE := 0.4 # the last passes top up any region or side of the board below this
const TRIM_ABOVE := 0.655 # the top-up passes can overshoot; zones that are not needed for the spread are removed down to this
const MAX_DEAD_AREA_SHARE := 0.085 # no empty rectangle may be bigger than this share of the puzzle (but 4 cells is always allowed)

# {w, h, weight}. Both orientations of a rectangle are listed so portrait and landscape boards get both.
const SHAPES := [
	{"w": 1, "h": 1, "weight": 22.0},
	{"w": 1, "h": 2, "weight": 8.0}, {"w": 2, "h": 1, "weight": 8.0},
	{"w": 2, "h": 2, "weight": 14.0},
	{"w": 2, "h": 3, "weight": 6.0}, {"w": 3, "h": 2, "weight": 6.0},
	{"w": 3, "h": 3, "weight": 8.0},
	{"w": 3, "h": 4, "weight": 2.0}, {"w": 4, "h": 3, "weight": 2.0},
	{"w": 4, "h": 4, "weight": 1.5},
	{"w": 4, "h": 5, "weight": 0.35}, {"w": 5, "h": 4, "weight": 0.35},
]

static func generate(columns: int, rows: int, rng: RandomNumberGenerator) -> Array:
	var total := columns * rows
	var target := roundi(total * COVERAGE)
	var max_area := maxi(4, roundi(total * MAX_AREA_SHARE))
	var occupied := PackedInt32Array()
	occupied.resize(total)
	occupied.fill(-1)
	var zones: Array = []
	var covered := 0
	var spread := _Spread.new(columns, rows)
	# Big zones first, while there is room: what a puzzle of this size is guaranteed to have.
	for minimum in _guaranteed_areas(total):
		var options := SHAPES.filter(func(s): return s.w * s.h >= minimum and s.w * s.h <= maxi(max_area, minimum) and s.w <= columns and s.h <= rows)
		if options.is_empty():
			continue
		var shape: Dictionary = options[rng.randi_range(0, options.size() - 1)]
		var placed := _place(zones, occupied, columns, rows, shape.w, shape.h, rng, spread)
		if placed != null:
			covered += placed.area()
	# Then fill toward the coverage target with the common shapes.
	var failed := {}
	var stalls := 0
	while covered < target and stalls < 60:
		var remaining := target - covered
		var candidates := []
		var weights := []
		for shape in SHAPES:
			var area: int = shape.w * shape.h
			if area > max_area or area > remaining + MAX_OVERSHOOT or shape.w > columns or shape.h > rows or failed.has(area * 100 + shape.w):
				continue
			candidates.append(shape)
			weights.append(shape.weight)
		if candidates.is_empty():
			break
		var pick: Dictionary = candidates[_weighted(weights, rng)]
		var zone := _place(zones, occupied, columns, rows, pick.w, pick.h, rng, spread)
		if zone == null:
			failed[pick.w * pick.h * 100 + pick.w] = true # no room left for this shape
			stalls += 1
			continue
		covered += zone.area()
	_top_up_thin_regions(zones, occupied, columns, rows, rng, spread)
	_trim_excess(zones, occupied, columns, rows, rng)
	_assign_kinds(zones, rng)
	return zones

# How the board is cut into regions, and how much of each is covered so far.
class _Spread extends RefCounted:
	var columns := 0
	var rows := 0
	var region_columns := 1
	var region_rows := 1
	var size := PackedInt32Array()
	var covered := PackedInt32Array()
	var band_rows := 1
	var band_columns := 1
	var band_size := [0, 0, 0, 0] # top, bottom, left and right: the outer fifth of the board along each side
	var band_covered := [0, 0, 0, 0]

	func _init(p_columns: int, p_rows: int) -> void:
		columns = p_columns
		rows = p_rows
		region_columns = clampi(roundi(columns / 4.5), 2, 8)
		region_rows = clampi(roundi(rows / 4.5), 2, 8)
		size.resize(region_columns * region_rows)
		covered.resize(region_columns * region_rows)
		band_rows = maxi(1, roundi(rows * 0.2))
		band_columns = maxi(1, roundi(columns * 0.2))
		for r in range(rows):
			for c in range(columns):
				size[region_of(c, r)] += 1
				for band in bands_of(c, r):
					band_size[band] += 1

	# Which sides' bands a cell is in (a corner cell is in two).
	func bands_of(c: int, r: int) -> Array:
		var found := []
		if r < band_rows:
			found.append(0)
		if r >= rows - band_rows:
			found.append(1)
		if c < band_columns:
			found.append(2)
		if c >= columns - band_columns:
			found.append(3)
		return found

	func region_of(c: int, r: int) -> int:
		return (r * region_rows / rows) * region_columns + c * region_columns / columns

	func add(zone: PowerZone) -> void:
		for r in range(zone.row, zone.row + zone.height):
			for c in range(zone.column, zone.column + zone.width):
				covered[region_of(c, r)] += 1
				for band in bands_of(c, r):
					band_covered[band] += 1

	# How far below the target coverage the regions and side bands under this rectangle are (0 = at or above it,
	# 1 = empty): the neediest of the two for each cell, averaged over the rectangle.
	func need(c: int, r: int, w: int, h: int) -> float:
		var total := 0.0
		for y in range(r, r + h):
			for x in range(c, c + w):
				var region := region_of(x, y)
				var worst := clampf(1.0 - float(covered[region]) / (size[region] * COVERAGE), 0.0, 1.0)
				for band in bands_of(x, y):
					worst = maxf(worst, clampf(1.0 - float(band_covered[band]) / (band_size[band] * COVERAGE), 0.0, 1.0))
				total += worst
		return total / (w * h)

# The last passes. First any region or side of the board that is still sparse gets single cells (next to existing
# zones where it can, so chains stay possible); then any big empty rectangle that is left gets a zone in its middle.
static func _top_up_thin_regions(zones: Array, occupied: PackedInt32Array, columns: int, rows: int, rng: RandomNumberGenerator, spread: _Spread) -> void:
	var groups := _groups(columns, rows, spread)
	for cells in groups:
		var guard := 0
		while guard < 60:
			guard += 1
			var have := 0
			var free := []
			for cell in cells:
				if occupied[cell.y * columns + cell.x] >= 0:
					have += 1
				else:
					free.append(cell)
			if float(have) / cells.size() >= MIN_REGION_COVERAGE or free.is_empty():
				break
			var best: Vector2i = free[0]
			var best_contact := -1.0
			for cell in free:
				var contact := _contact(occupied, columns, rows, cell.x, cell.y, 1, 1) + rng.randf()
				if contact > best_contact:
					best_contact = contact
					best = cell
			_add_zone(zones, occupied, columns, rows, best.x, best.y, 1, 1, spread)
	# dead areas
	var limit := maxi(4, int(columns * rows * MAX_DEAD_AREA_SHARE))
	for i in range(80):
		var empty := _largest_empty(occupied, columns, rows)
		if empty.get_area() <= limit:
			break
		var w := mini(2, empty.size.x)
		var h := mini(2, empty.size.y)
		_add_zone(zones, occupied, columns, rows, empty.position.x + (empty.size.x - w) / 2, empty.position.y + (empty.size.y - h) / 2, w, h, spread)

# The cell groups the spread is judged on: the regions, then the four side bands.
static func _groups(columns: int, rows: int, spread: _Spread) -> Array:
	var groups := []
	for region in range(spread.size.size()):
		var cells := []
		for r in range(rows):
			for c in range(columns):
				if spread.region_of(c, r) == region:
					cells.append(Vector2i(c, r))
		groups.append(cells)
	for band in range(4):
		var cells := []
		for r in range(rows):
			for c in range(columns):
				if spread.bands_of(c, r).has(band):
					cells.append(Vector2i(c, r))
		groups.append(cells)
	return groups

# Is every group at least MIN_REGION_COVERAGE covered, with no empty rectangle over the limit?
static func _well_spread(occupied: PackedInt32Array, columns: int, rows: int, groups: Array, limit: int) -> bool:
	for cells in groups:
		var have := 0
		for cell in cells:
			if occupied[cell.y * columns + cell.x] >= 0:
				have += 1
		if float(have) / cells.size() < MIN_REGION_COVERAGE:
			return false
	return _largest_empty(occupied, columns, rows).get_area() <= limit

# Removes zones the spread does not need, until the coverage is back near the target.
static func _trim_excess(zones: Array, occupied: PackedInt32Array, columns: int, rows: int, rng: RandomNumberGenerator) -> void:
	var total := columns * rows
	var spread := _Spread.new(columns, rows)
	var groups := _groups(columns, rows, spread)
	var limit := maxi(4, int(total * MAX_DEAD_AREA_SHARE))
	var covered := 0
	for zone in zones:
		covered += zone.area()
	var order := zones.duplicate()
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var swap = order[i]
		order[i] = order[j]
		order[j] = swap
	for zone in order:
		if float(covered) / total <= TRIM_ABOVE:
			break
		for id in zone.cell_ids():
			occupied[id] = -1
		if _well_spread(occupied, columns, rows, groups, limit):
			zones.erase(zone)
			covered -= zone.area()
		else:
			for id in zone.cell_ids():
				occupied[id] = 0

static func _add_zone(zones: Array, occupied: PackedInt32Array, columns: int, rows: int, c: int, r: int, w: int, h: int, spread: _Spread) -> void:
	var zone := PowerZone.make(columns, rows, c, r, w, h, PowerZone.Kind.LIGHTNING)
	for id in zone.cell_ids():
		occupied[id] = zones.size()
	zones.append(zone)
	spread.add(zone)

# The biggest rectangle of free cells (first one found if there are ties).
static func _largest_empty(occupied: PackedInt32Array, columns: int, rows: int) -> Rect2i:
	var best := Rect2i()
	for top in range(rows):
		var empty_columns := PackedByteArray()
		empty_columns.resize(columns)
		empty_columns.fill(1)
		for bottom in range(top, rows):
			var run := 0
			for c in range(columns):
				if occupied[bottom * columns + c] >= 0:
					empty_columns[c] = 0
				if empty_columns[c]:
					run += 1
					if run * (bottom - top + 1) > best.get_area():
						best = Rect2i(c - run + 1, top, run, bottom - top + 1)
				else:
					run = 0
	return best

# --- measuring a layout (used by the tests) ---

# The share of each region that is covered.
static func region_coverage(zones: Array, columns: int, rows: int) -> Array:
	var spread := _Spread.new(columns, rows)
	for zone in zones:
		spread.add(zone)
	var result := []
	for i in range(spread.size.size()):
		result.append(float(spread.covered[i]) / spread.size[i])
	return result

# The share covered along each side of the board (the outer fifth: top, bottom, left, right).
static func side_coverage(zones: Array, columns: int, rows: int) -> Array:
	var grid := _cells(zones, columns, rows)
	var band_rows := maxi(1, roundi(rows * 0.2))
	var band_columns := maxi(1, roundi(columns * 0.2))
	var sums := [0, 0, 0, 0]
	var counts := [0, 0, 0, 0]
	for r in range(rows):
		for c in range(columns):
			var hit := 1 if grid[r * columns + c] else 0
			if r < band_rows:
				sums[0] += hit
				counts[0] += 1
			if r >= rows - band_rows:
				sums[1] += hit
				counts[1] += 1
			if c < band_columns:
				sums[2] += hit
				counts[2] += 1
			if c >= columns - band_columns:
				sums[3] += hit
				counts[3] += 1
	return [float(sums[0]) / counts[0], float(sums[1]) / counts[1], float(sums[2]) / counts[2], float(sums[3]) / counts[3]]

# The cells of the biggest rectangle with no zone in it at all.
static func largest_empty_rectangle(zones: Array, columns: int, rows: int) -> int:
	var occupied := PackedInt32Array()
	occupied.resize(columns * rows)
	occupied.fill(-1)
	for zone in zones:
		for id in zone.cell_ids():
			occupied[id] = 0
	return _largest_empty(occupied, columns, rows).get_area()

static func _cells(zones: Array, columns: int, rows: int) -> PackedByteArray:
	var grid := PackedByteArray()
	grid.resize(columns * rows)
	for zone in zones:
		for id in zone.cell_ids():
			grid[id] = 1
	return grid

# The areas (in cells) of the big zones a puzzle with `total` pieces must contain.
static func _guaranteed_areas(total: int) -> Array:
	if total >= 200:
		return [16, 12, 12]
	if total >= 100:
		return [12, 12]
	if total >= 48:
		return [9]
	return []

static func _weighted(weights: Array, rng: RandomNumberGenerator) -> int:
	var sum := 0.0
	for w in weights:
		sum += w
	var roll := rng.randf() * sum
	for i in range(weights.size()):
		roll -= weights[i]
		if roll < 0.0:
			return i
	return weights.size() - 1

# Puts a w x h zone somewhere free, preferring spots that touch zones already placed (so powers sit next to each
# other and can chain). Returns the zone, or null if there is no room.
static func _place(zones: Array, occupied: PackedInt32Array, columns: int, rows: int, w: int, h: int, rng: RandomNumberGenerator, spread: _Spread) -> PowerZone:
	var best_score := -1.0
	var best := Vector2i(-1, -1)
	for r in range(rows - h + 1):
		for c in range(columns - w + 1):
			if not _is_free(occupied, columns, c, r, w, h):
				continue
			var score := _contact(occupied, columns, rows, c, r, w, h) * 1.0 + rng.randf() * 2.2 + spread.need(c, r, w, h) * NEED_WEIGHT
			if score > best_score:
				best_score = score
				best = Vector2i(c, r)
	if best.x < 0:
		return null
	var zone := PowerZone.make(columns, rows, best.x, best.y, w, h, PowerZone.Kind.LIGHTNING)
	var index := zones.size()
	zones.append(zone)
	for id in zone.cell_ids():
		occupied[id] = index
	spread.add(zone)
	return zone

static func _is_free(occupied: PackedInt32Array, columns: int, c: int, r: int, w: int, h: int) -> bool:
	for y in range(r, r + h):
		for x in range(c, c + w):
			if occupied[y * columns + x] >= 0:
				return false
	return true

# How many cells just outside the rectangle already belong to a zone.
static func _contact(occupied: PackedInt32Array, columns: int, rows: int, c: int, r: int, w: int, h: int) -> int:
	var count := 0
	for x in range(c, c + w):
		if r > 0 and occupied[(r - 1) * columns + x] >= 0:
			count += 1
		if r + h < rows and occupied[(r + h) * columns + x] >= 0:
			count += 1
	for y in range(r, r + h):
		if c > 0 and occupied[y * columns + c - 1] >= 0:
			count += 1
		if c + w < columns and occupied[y * columns + c + w] >= 0:
			count += 1
	return mini(count, 4) # a few neighbours are plenty; more would just glue everything into one blob

# Roughly half and half by coin flip, nudged so neither kind takes over, and the big zones alternate so a
# board always has a large Lightning and a large Magnet.
static func _assign_kinds(zones: Array, rng: RandomNumberGenerator) -> void:
	var by_size := zones.duplicate()
	by_size.sort_custom(func(a, b): return a.area() > b.area())
	var next_big := rng.randi_range(0, 1)
	for i in range(mini(4, by_size.size())):
		if by_size[i].area() >= 9:
			by_size[i].kind = (next_big + i) % 2
	for zone in zones:
		if zone.area() < 9:
			zone.kind = rng.randi_range(0, 1)
	var cells := [0, 0]
	for zone in zones:
		cells[zone.kind] += zone.area()
	var total: int = cells[0] + cells[1]
	# flip small zones from the over-represented kind until the split is within limits
	var small := zones.filter(func(z): return z.area() < 9)
	for i in range(small.size() - 1, 0, -1): # shuffled with the layout's own generator, so a seed always gives the same board
		var j := rng.randi_range(0, i)
		var swap = small[i]
		small[i] = small[j]
		small[j] = swap
	for zone in small:
		var heavy := 0 if cells[0] > cells[1] else 1
		if total <= 0 or float(cells[heavy]) / total <= KIND_SHARE_LIMIT:
			break
		if zone.kind == heavy:
			zone.kind = 1 - heavy
			cells[heavy] -= zone.area()
			cells[1 - heavy] += zone.area()
