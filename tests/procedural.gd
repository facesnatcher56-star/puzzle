extends SceneTree

# Generated pictures: every theme is deterministic, quick, varied enough to be a good puzzle, and independent of
# resolution; and a generated puzzle follows the same rules as a bundled random picture -- same size, same
# piece-count options, same cutting and powers -- and saves, restarts and syncs exactly.

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("PROCEDURAL TEST FAILED: " + message)

func _run() -> void:
	_test_themes()
	_test_images()
	_test_catalog()
	_test_puzzles()
	_test_save_and_sync()
	print("procedural test done, failures: ", failures)
	for child in root.get_children():
		child.free()
	quit(1 if failures > 0 else 0)

func _mean(img: Image) -> Color:
	var total := Vector3.ZERO
	var count := 0
	for y in range(0, img.get_height(), 3):
		for x in range(0, img.get_width(), 3):
			var c := img.get_pixel(x, y)
			total += Vector3(c.r, c.g, c.b)
			count += 1
	return Color(total.x / count, total.y / count, total.z / count)

# The share of 120-pixel blocks that are not flat: a flat block is a piece nobody can place by its picture.
func _busy_blocks(img: Image) -> float:
	var busy := 0
	var blocks := 0
	for by in range(0, img.get_height() - 119, 120):
		for bx in range(0, img.get_width() - 119, 120):
			var values := []
			for k in range(0, 14 * 14):
				values.append(img.get_pixel(bx + (k % 14) * 8, by + (k / 14) * 8).get_luminance())
			var mean := 0.0
			for v in values:
				mean += v
			mean /= values.size()
			var variance := 0.0
			for v in values:
				variance += (v - mean) * (v - mean)
			blocks += 1
			busy += 1 if sqrt(variance / values.size()) > 0.012 else 0
	return float(busy) / blocks

func _distinct_colours(img: Image) -> int:
	var seen := {}
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			var c := img.get_pixel(x, y)
			seen[Vector3i(int(c.r * 31), int(c.g * 31), int(c.b * 31))] = true
	return seen.size()

# --- themes ---

func _test_themes() -> void:
	_check(ProceduralImage.THEMES.size() >= 6, "there are several themes to pick from")
	for theme in ProceduralImage.THEMES:
		_check(theme.name != "" and theme.blurb != "" and ProceduralImage.is_theme(theme.id), "theme %s has a name and a blurb" % theme.id)
	var picked := {}
	for seed_value in range(1, 25):
		var theme := ProceduralImage.resolve(ProceduralImage.ANY, seed_value)
		_check(ProceduralImage.is_theme(theme) and theme == ProceduralImage.resolve(ProceduralImage.ANY, seed_value), "Surprise Me picks a real theme, the same one for a seed")
		picked[theme] = true
	_check(picked.size() == ProceduralImage.THEMES.size(), "Surprise Me reaches every theme")
	_check(ProceduralImage.resolve("dusk", 5) == "dusk" and ProceduralImage.is_theme(ProceduralImage.resolve("not a theme", 5)), "a named theme stays itself; an unknown one falls back to a real one")

# --- the pictures ---

func _test_images() -> void:
	var size := PuzzleCatalog.GENERATED_SIZE
	for theme in ProceduralImage.theme_ids():
		print("procedural: checking %s" % theme) # progress, so a watcher can tell a slow run from a hung one
		var t0 := Time.get_ticks_msec()
		var img := ProceduralImage.generate(theme, 42, size)
		var took := Time.get_ticks_msec() - t0
		_check(img.get_size() == size, "%s is the full picture size" % theme)
		_check(took < 4000, "%s generates quickly (%d ms)" % [theme, took])
		var again := ProceduralImage.generate(theme, 42, size)
		_check(img.get_data() == again.get_data(), "%s is identical for the same seed" % theme)
		var other := ProceduralImage.generate(theme, 43, size)
		_check(img.get_data() != other.get_data(), "%s differs for another seed" % theme)
		_check(_busy_blocks(img) >= 0.9, "%s has no large flat areas (%.2f of blocks busy)" % [theme, _busy_blocks(img)])
		_check(_distinct_colours(img) >= 250, "%s has plenty of colour variety (%d)" % [theme, _distinct_colours(img)])
		# one more seed, so a lucky palette does not pass for the theme
		var third := ProceduralImage.generate(theme, 9001, size)
		_check(_busy_blocks(third) >= 0.9 and _distinct_colours(third) >= 250, "%s stays varied on another seed" % theme)
		# the same composition at any size: the small version matches the big one's overall colour
		var small := ProceduralImage.generate(theme, 42, size / 4)
		var a := _mean(img)
		var b := _mean(small)
		_check(absf(a.r - b.r) < 0.08 and absf(a.g - b.g) < 0.08 and absf(a.b - b.b) < 0.08, "%s looks the same at a quarter of the size" % theme)
		# opaque: nothing was left unpainted
		var corner := img.get_pixel(size.x - 1, size.y - 1)
		_check(corner.a == 1.0 and img.get_pixel(0, 0).a == 1.0 and img.get_pixel(size.x / 2, size.y / 2).a == 1.0, "%s is fully painted" % theme)
	# themes do not all look alike
	var means := []
	for theme in ProceduralImage.theme_ids():
		means.append(_mean(ProceduralImage.generate(theme, 7, size / 4)))
	var distinct := 0
	for i in range(means.size()):
		for j in range(i + 1, means.size()):
			var d := Vector3(means[i].r - means[j].r, means[i].g - means[j].g, means[i].b - means[j].b).length()
			distinct += 1 if d > 0.04 else 0
	_check(distinct >= 10, "the themes have different overall looks (%d of 15 pairs)" % distinct)

# --- the catalog ---

func _test_catalog() -> void:
	_check(PuzzleCatalog.is_known("gen:dusk") and PuzzleCatalog.is_known("gen:any") and not PuzzleCatalog.is_known("gen:bogus") and not PuzzleCatalog.is_known("gen:"), "generated ids are known only for real themes")
	_check(PuzzleCatalog.is_random("gen:dusk"), "a generated puzzle plays by the random-puzzle rules")
	_check(PuzzleCatalog.sizes_for("gen:sea") == PuzzleCatalog.RANDOM_SIZES, "it offers the same piece counts as a random picture")
	var bundled: Texture2D = PuzzleCatalog.texture_for("motel")
	var made := PuzzleCatalog.texture_for("gen:crystal", 11)
	_check(made.get_size() == bundled.get_size(), "a generated picture is the same size as a bundled random one")
	_check(PuzzleCatalog.texture_for("gen:crystal", 11) == made and PuzzleCatalog.texture_for("gen:crystal", 12) != made, "the same seed gives the cached picture, another seed a new one")
	_check(PuzzleCatalog.thumbnail_for("gen:crystal", 11).get_size() == Vector2(PuzzleCatalog.GENERATED_SIZE / PuzzleCatalog.THUMBNAIL_DIVISOR), "thumbnails are drawn small")
	_check(PuzzleCatalog.label_for("gen:nebula", 3) == "Generated  •  Nebula" and PuzzleCatalog.label_for("", 0) == "Emberbound" and PuzzleCatalog.label_for("motel", 0) == "Random  •  Motel", "pictures are named for menus")
	_check(PuzzleCatalog.label_for("gen:any", 4).begins_with("Generated  •  ") and PuzzleCatalog.label_for("gen:any", 4) == "Generated  •  " + ProceduralImage.theme_name(ProceduralImage.resolve("any", 4)), "a Surprise Me picture is named for the theme it became")

# --- puzzles ---

func _fresh_session() -> PuzzleSession:
	var network := NetworkSession.new()
	root.add_child(network)
	var manager := PuzzleManager.new()
	var session := PuzzleSession.new()
	session.setup(manager, network)
	root.add_child(session)
	network.configure(manager, Callable(session, "puzzle_config"))
	return session

func _test_puzzles() -> void:
	SaveManager.save_dir = "user://test_saves_procedural"
	var expected := [24, 48, 108, 252]
	for theme in ["dusk", "crystal", "stained", "nebula", "geometric", "sea", "any"]:
		print("procedural: puzzle from %s" % theme)
		var session := _fresh_session()
		session.new_generated_session(theme)
		_check(session.image_id == "gen:" + theme and session.sizes == PuzzleCatalog.RANDOM_SIZES, "%s: a generated puzzle uses the random-picture piece counts" % theme)
		_check(Vector2i(session.board_size) == PuzzleCatalog.GENERATED_SIZE, "%s: on the same board as a random picture" % theme)
		SaveManager.delete_slot(session.save_slot)
	var session := _fresh_session()
	session.new_generated_session("crystal")
	SaveManager.delete_slot(session.save_slot)
	var picture_data := session.source.get_image().get_data()
	for i in range(PuzzleCatalog.RANDOM_SIZES.size()):
		session.size_index = i
		session.start_puzzle(false)
		var count: int = session.columns * session.rows
		_check(count == expected[i] and session.manager.pieces.size() == expected[i], "%d pieces are cut" % expected[i])
		_check(session.source.get_image().get_data() == picture_data, "a restart keeps the same picture")
		# the same cutting as a bundled random picture: piece shapes depend only on the seed and the grid
		var reference := PuzzleGenerator.generate(PuzzleCatalog.texture_for("motel"), session.columns, session.rows, session.seed_value, session.board_size, false)
		var same_shapes := true
		for k in range(count):
			same_shapes = same_shapes and session.manager.pieces[k].outline == reference[k].outline and session.manager.pieces[k].correct_position == reference[k].correct_position and session.manager.pieces[k].piece_size == reference[k].piece_size
		_check(same_shapes, "%d pieces are cut exactly as they are for a bundled picture" % count)
		# and powered exactly the same way
		var covered := 0
		for zone in session.power_zones:
			covered += zone.area()
		_check(float(covered) / count >= 0.52 and float(covered) / count <= 0.68 and session.power_zones.size() >= 3, "%d pieces get the usual board powers (%d zones covering %d)" % [count, session.power_zones.size(), covered])
	# a new puzzle is a new picture in the same theme, at the size that was chosen
	session.size_index = 1
	session.start_puzzle(false)
	var before_seed := session.seed_value
	session.start_puzzle(true)
	_check(session.seed_value == before_seed + 1 and session.image_id == "gen:crystal" and session.size_index == 1 and session.manager.pieces.size() == 48, "New Puzzle keeps the theme and the piece count")
	_check(session.source.get_image().get_data() != picture_data, "...and makes a different picture")
	SaveManager.delete_slot(session.save_slot)

# --- saving and joining ---

func _test_save_and_sync() -> void:
	var session := _fresh_session()
	session.new_generated_session("stained")
	session.size_index = 1
	session.start_puzzle(false)
	var slot := session.save_slot
	session.write_save()
	var picture_data := session.source.get_image().get_data()
	var title := SaveFormat.title(SaveManager.load_state(SaveManager.slot_path(slot)))
	_check(title == "Generated  •  Stained Glass", "the saved game is named for its theme (%s)" % title)
	var loaded := _fresh_session()
	_check(loaded.load_session(slot) and loaded.image_id == "gen:stained" and loaded.seed_value == session.seed_value, "a generated puzzle loads from its save")
	_check(loaded.source.get_image().get_data() == picture_data, "...with exactly the same picture")
	_check(loaded.manager.pieces.size() == 48 and loaded.size_index == 1, "...and the same piece count")
	# a joining player rebuilds the picture from the host's config alone
	var guest := _fresh_session()
	var config := session.puzzle_config()
	var snapshots := []
	for piece in session.manager.pieces:
		snapshots.append(piece.snapshot())
	_check(config.image_id == "gen:stained" and config.seed_value == session.seed_value, "the host's config names the picture and its seed")
	guest.restore_from_host(config, snapshots)
	_check(guest.source.get_image().get_data() == picture_data and guest.manager.pieces.size() == 48, "a joining player gets the identical picture")
	# a finished puzzle's Collection entry remembers the seed so its thumbnail can be drawn again
	var entry := Collection.entry_from(config, "x", 1000, 1, false)
	_check(int(entry.seed_value) == session.seed_value and PuzzleCatalog.thumbnail_for(entry.image_id, int(entry.seed_value)).get_size() == Vector2(PuzzleCatalog.GENERATED_SIZE / PuzzleCatalog.THUMBNAIL_DIVISOR), "the Collection can redraw a generated picture")
	_check(Collection.totals([entry]).pictures == 0, "generated pictures are not counted against the bundled set")
	SaveManager.delete_slot(slot)
