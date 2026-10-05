class_name PowerLayout
extends RefCounted

# Lays power zones out over a puzzle: about COVERAGE of the cells end up in some zone, zones never overlap but
# like to touch, small ones are common and big ones rare -- except that a big enough puzzle is always given a
# few big ones, so a board is never fifty 1x1s with nothing impressive on it. Lightning and Magnet are mixed
# roughly evenly without being rigid about it.

const COVERAGE := 0.6
const MAX_AREA_SHARE := 0.12 # no zone covers more than this share of the puzzle (but a small one always may reach 4 cells)
const MAX_OVERSHOOT := 1 # a zone may take the coverage this many cells past the target
const KIND_SHARE_LIMIT := 0.62 # neither kind covers more than this share of the powered cells

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
	# Big zones first, while there is room: what a puzzle of this size is guaranteed to have.
	for minimum in _guaranteed_areas(total):
		var options := SHAPES.filter(func(s): return s.w * s.h >= minimum and s.w * s.h <= maxi(max_area, minimum) and s.w <= columns and s.h <= rows)
		if options.is_empty():
			continue
		var shape: Dictionary = options[rng.randi_range(0, options.size() - 1)]
		var placed := _place(zones, occupied, columns, rows, shape.w, shape.h, rng)
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
		var zone := _place(zones, occupied, columns, rows, pick.w, pick.h, rng)
		if zone == null:
			failed[pick.w * pick.h * 100 + pick.w] = true # no room left for this shape
			stalls += 1
			continue
		covered += zone.area()
	_assign_kinds(zones, rng)
	return zones

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
static func _place(zones: Array, occupied: PackedInt32Array, columns: int, rows: int, w: int, h: int, rng: RandomNumberGenerator) -> PowerZone:
	var best_score := -1.0
	var best := Vector2i(-1, -1)
	for r in range(rows - h + 1):
		for c in range(columns - w + 1):
			if not _is_free(occupied, columns, c, r, w, h):
				continue
			var score := _contact(occupied, columns, rows, c, r, w, h) * 1.0 + rng.randf() * 2.2
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
