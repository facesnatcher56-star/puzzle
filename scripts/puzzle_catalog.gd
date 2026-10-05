class_name PuzzleCatalog
extends RefCounted

# The pictures the game ships with and the piece-count options for each. "" is the classic Emberbound
# puzzle; every other id is a Random Puzzle picture. To add artwork, drop the file in assets/random/ and
# add one line to RANDOM_IMAGES.
# "gen:<theme>" ids are pictures made on the spot by ProceduralImage (see GENERATED_SIZE): the picture is a
# pure function of the theme and the puzzle's seed, so saves and joining players rebuild it exactly. They follow
# the same rules as the bundled random pictures -- the same 4:3 size, piece-count options, cutting and powers.

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

const GENERATED_PREFIX := "gen:"
const GENERATED_SIZE := Vector2i(1448, 1086) # the same size as the bundled random pictures
const THUMBNAIL_DIVISOR := 4
static var _generated_cache := {} # "id|seed|width" -> ImageTexture, newest last

static func generated_id(theme: String) -> String:
	return GENERATED_PREFIX + theme

static func is_generated(id: String) -> bool:
	return id.begins_with(GENERATED_PREFIX)

static func generated_theme(id: String) -> String:
	return id.trim_prefix(GENERATED_PREFIX)

static func is_known(id: String) -> bool:
	if is_generated(id):
		var theme := generated_theme(id)
		return theme == ProceduralImage.ANY or ProceduralImage.is_theme(theme)
	return id == "" or RANDOM_IMAGES.has(id)

# A readable name for a picture ("any" generated pictures are named after the theme their seed picked).
static func label_for(id: String, seed_value: int = 0) -> String:
	if id == "":
		return "Emberbound"
	if is_generated(id):
		return "Generated  •  " + ProceduralImage.theme_name(ProceduralImage.resolve(generated_theme(id), seed_value))
	return "Random  •  " + id.capitalize()

static func is_random(id: String) -> bool:
	return id != ""

# The picture itself. A generated picture depends on the seed as well as the id.
static func texture_for(id: String, seed_value: int = 0) -> Texture2D:
	if is_generated(id):
		return _generated_texture(id, seed_value, GENERATED_SIZE)
	return RANDOM_IMAGES[id] if id != "" and RANDOM_IMAGES.has(id) else SOURCE_IMAGE

# A small version for lists (generated pictures are drawn small, not scaled down from the full picture).
static func thumbnail_for(id: String, seed_value: int = 0) -> Texture2D:
	if is_generated(id):
		return _generated_texture(id, seed_value, GENERATED_SIZE / THUMBNAIL_DIVISOR)
	return texture_for(id, seed_value)

static func _generated_texture(id: String, seed_value: int, size: Vector2i) -> Texture2D:
	var key := "%s|%d|%d" % [id, seed_value, size.x]
	if not _generated_cache.has(key):
		var image := ProceduralImage.generate(generated_theme(id), seed_value, size)
		_generated_cache[key] = ImageTexture.create_from_image(image)
		while _generated_cache.size() > 6: # a restart and a few thumbnails, never an ever-growing pile of pictures
			_generated_cache.erase(_generated_cache.keys()[0])
	return _generated_cache[key]

static func sizes_for(id: String) -> Array:
	return RANDOM_SIZES if id != "" else SIZES

# A random picture that is not in `excluded`. If every picture is excluded, any picture is allowed rather
# than leaving the player without a puzzle.
static func pick_random(excluded: Array) -> String:
	var ids := RANDOM_IMAGES.keys()
	var options := ids.filter(func(id): return not excluded.has(id))
	if options.is_empty():
		options = ids
	return options[randi() % options.size()]
