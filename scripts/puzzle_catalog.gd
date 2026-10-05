class_name PuzzleCatalog
extends RefCounted

# The pictures the game ships with and the piece-count options for each. "" is the classic Emberbound
# puzzle; every other id is a Random Puzzle picture. To add artwork, drop the file in assets/random/ and
# add one line to RANDOM_IMAGES.

const SOURCE_IMAGE: Texture2D = preload("res://assets/emberbound.png")
const BOARD_SIZE := Vector2(1122, 1402)
const SIZES := [Vector2i(4, 6), Vector2i(6, 8), Vector2i(8, 12), Vector2i(10, 25)]
const RANDOM_IMAGES := {
	"motel": preload("res://assets/random/motel.webp"),
	"hotel": preload("res://assets/random/hotel.webp"),
	"subway": preload("res://assets/random/subway.webp"),
	"bayou": preload("res://assets/random/bayou.webp"),
}
# Grids for the 4:3 random artwork; chosen so cells stay close to square.
const RANDOM_SIZES := [Vector2i(6, 4), Vector2i(8, 6), Vector2i(12, 9), Vector2i(18, 14)]

static func is_known(id: String) -> bool:
	return id == "" or RANDOM_IMAGES.has(id)

static func is_random(id: String) -> bool:
	return id != ""

static func texture_for(id: String) -> Texture2D:
	return RANDOM_IMAGES[id] if id != "" and RANDOM_IMAGES.has(id) else SOURCE_IMAGE

static func sizes_for(id: String) -> Array:
	return RANDOM_SIZES if id != "" else SIZES

# A random picture other than `current`, so a "new puzzle" is always a visible change.
static func pick_random(current: String) -> String:
	var ids := RANDOM_IMAGES.keys()
	var options := ids.filter(func(id): return id != current)
	if options.is_empty():
		options = ids
	return options[randi() % options.size()]
