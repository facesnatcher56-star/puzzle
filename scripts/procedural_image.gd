class_name ProceduralImage
extends RefCounted

# Makes puzzle pictures from nothing: a theme and a seed always give the same image. Every theme is composed in
# relative coordinates, so the same seed looks the same at any size (the Collection draws small versions).
#
# Everything is built from fast native Image operations -- row and column spans, flat triangles, discs, soft glows
# blended from small masks -- so a full-size picture takes well under a second and nothing needs a renderer,
# which also makes it work (and testable) headless. Pictures are meant to be good puzzles: lots of local variety,
# structure that runs across piece boundaries, and no large flat areas.

const THEMES := [
	{"id": "dusk", "name": "Mountain Dusk", "blurb": "Layered ridges, a low sun and the first stars"},
	{"id": "crystal", "name": "Crystal", "blurb": "Faceted glass in one colour family"},
	{"id": "stained", "name": "Stained Glass", "blurb": "Jewel-coloured panes held in dark lead"},
	{"id": "nebula", "name": "Nebula", "blurb": "Glowing gas clouds and a field of stars"},
	{"id": "geometric", "name": "Geometric", "blurb": "Bold Bauhaus shapes in a tight palette"},
	{"id": "sea", "name": "Sunset Sea", "blurb": "A glowing sun over rolling waves"},
]
const ANY := "any" # "Surprise me": the theme is picked from the seed

static func theme_ids() -> Array:
	return THEMES.map(func(t): return t.id)

static func is_theme(id: String) -> bool:
	return theme_ids().has(id)

static func theme_name(id: String) -> String:
	for theme in THEMES:
		if theme.id == id:
			return theme.name
	return "Surprise"

# "any" becomes a particular theme, the same one every time for the same seed.
static func resolve(theme: String, seed_value: int) -> String:
	if theme == ANY or not is_theme(theme):
		return THEMES[posmod(seed_value, THEMES.size())].id
	return theme

static func generate(theme: String, seed_value: int, size: Vector2i) -> Image:
	theme = resolve(theme, seed_value)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7919 + theme_ids().find(theme) * 104729 + 17
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	match theme:
		"dusk": _dusk(img, rng, seed_value)
		"crystal": _crystal(img, rng)
		"stained": _stained(img, rng)
		"nebula": _nebula(img, rng)
		"geometric": _geometric(img, rng)
		"sea": _sea(img, rng)
	# flat-shaded themes get the most texture; painterly ones need less
	_texture(img, seed_value, 1.0 if theme in ["crystal", "stained", "geometric", "dusk"] else 0.6)
	return img

# Soft mottling plus fine grain laid over the whole picture. A piece cut from the middle of a flat facet, ridge or
# sky would otherwise show nothing to place it by; this gives every region something local, whatever the theme.
# Three layers of noise, each as a small light-and-dark overlay: the coarse one is scaled up smoothly, the finer
# ones are tiled (they come from seamless noise, so the tiles do not show).
static func _texture(img: Image, seed_value: int, strength: float) -> void:
	var size := img.get_size()
	# coarse mottling: noise at an eighth of the size, scaled up
	var coarse := _overlay(_noise_tile(seed_value * 13 + 5, Vector2i(maxi(8, size.x / 8), maxi(8, size.y / 8)), 0.05, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, false), 0.2 * strength)
	coarse.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
	img.blend_rect(coarse, Rect2i(Vector2i.ZERO, size), Vector2i.ZERO)
	_tile_over(img, _overlay(_noise_tile(seed_value * 13 + 982, Vector2i(192, 192), 0.07, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, true), 0.2 * strength))
	_tile_over(img, _overlay(_noise_tile(seed_value * 13 + 1959, Vector2i(96, 96), 0.55, FastNoiseLite.TYPE_PERLIN, true), 0.15 * strength))

static func _noise_tile(seed_value: int, size: Vector2i, frequency: float, noise_type: int, seamless: bool) -> Image:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = noise_type
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	return noise.get_seamless_image(size.x, size.y) if seamless else noise.get_image(size.x, size.y)

# Noise as a transparent overlay: lighter than middle grey becomes white with some alpha, darker becomes black.
static func _overlay(noise: Image, opacity: float) -> Image:
	var out := Image.create(noise.get_width(), noise.get_height(), false, Image.FORMAT_RGBA8)
	for y in range(noise.get_height()):
		for x in range(noise.get_width()):
			var v := noise.get_pixel(x, y).r - 0.5
			out.set_pixel(x, y, Color(1, 1, 1, v * 2.0 * opacity) if v > 0.0 else Color(0, 0, 0, -v * 2.0 * opacity))
	return out

static func _tile_over(img: Image, tile: Image) -> void:
	var step := tile.get_size()
	for y in range(0, img.get_height(), step.y):
		for x in range(0, img.get_width(), step.x):
			img.blend_rect(tile, Rect2i(Vector2i.ZERO, step), Vector2i(x, y))

# --- drawing helpers ---

static func _hsv(h: float, s: float, v: float, a: float = 1.0) -> Color:
	return Color.from_hsv(fposmod(h, 1.0), clampf(s, 0.0, 1.0), clampf(v, 0.0, 1.0), a)

# A vertical gradient across rows y0..y1, easing with `curve`.
static func _rows(img: Image, y0: int, y1: int, top: Color, bottom: Color, curve: float = 1.0) -> void:
	var span := maxi(1, y1 - y0 - 1)
	for y in range(maxi(0, y0), mini(img.get_height(), y1)):
		img.fill_rect(Rect2i(0, y, img.get_width(), 1), top.lerp(bottom, pow(float(y - y0) / span, curve)))

static func _disc(img: Image, cx: float, cy: float, r: float, color: Color, clip: Rect2i = Rect2i()) -> void:
	var bounds := Rect2i(0, 0, img.get_width(), img.get_height())
	if clip.size != Vector2i.ZERO:
		bounds = bounds.intersection(clip)
	for y in range(maxi(bounds.position.y, int(cy - r)), mini(bounds.end.y, int(cy + r) + 1)):
		var dy := y + 0.5 - cy
		if absf(dy) > r:
			continue
		var dx := sqrt(r * r - dy * dy)
		var x0 := maxi(bounds.position.x, int(floor(cx - dx)))
		var x1 := mini(bounds.end.x, int(ceil(cx + dx)))
		if x1 > x0:
			img.fill_rect(Rect2i(x0, y, x1 - x0, 1), color)

# A flat triangle, filled one scanline span at a time (a pixel of overlap on each side keeps neighbours crack-free).
static func _tri(img: Image, a: Vector2, b: Vector2, c: Vector2, color: Color) -> void:
	var y0 := maxi(0, int(floor(minf(a.y, minf(b.y, c.y)))))
	var y1 := mini(img.get_height() - 1, int(ceil(maxf(a.y, maxf(b.y, c.y)))))
	var corners := [a, b, c]
	for y in range(y0, y1 + 1):
		var yc := y + 0.5
		var lo := INF
		var hi := -INF
		for i in range(3):
			var p: Vector2 = corners[i]
			var q: Vector2 = corners[(i + 1) % 3]
			if (p.y <= yc and q.y > yc) or (q.y <= yc and p.y > yc):
				var x := p.x + (yc - p.y) * (q.x - p.x) / (q.y - p.y)
				lo = minf(lo, x)
				hi = maxf(hi, x)
		if hi >= lo:
			var x0 := maxi(0, int(floor(lo)) - 1)
			var x1 := mini(img.get_width(), int(ceil(hi)) + 1)
			if x1 > x0:
				img.fill_rect(Rect2i(x0, y, x1 - x0, 1), color)

static func _line(img: Image, a: Vector2, b: Vector2, width: int, color: Color) -> void:
	var steps := maxi(1, int(maxf(absf(b.x - a.x), absf(b.y - a.y))))
	for i in range(steps + 1):
		var p := a.lerp(b, float(i) / steps)
		img.fill_rect(Rect2i(int(p.x) - width / 2, int(p.y) - width / 2, width, width), color)

# A soft glow: a small mask stretched to `size` and blended over the picture.
static func _glow(img: Image, center: Vector2, size: Vector2, color: Color, falloff: float = 2.0) -> void:
	var mask := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in range(32):
		for x in range(32):
			var d := Vector2(x - 15.5, y - 15.5).length() / 16.0
			mask.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * pow(clampf(1.0 - d, 0.0, 1.0), falloff)))
	mask.resize(maxi(2, int(size.x)), maxi(2, int(size.y)), Image.INTERPOLATE_BILINEAR)
	img.blend_rect(mask, Rect2i(Vector2i.ZERO, mask.get_size()), Vector2i(center - size * 0.5))

static func _noise(seed_value: int, frequency: float) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.frequency = frequency
	return noise

# A jittered grid of points (with a margin so the triangulation covers the whole picture).
static func _points(img: Image, rng: RandomNumberGenerator, columns: int, rows: int, jitter: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var w := float(img.get_width())
	var h := float(img.get_height())
	var cell := Vector2(w / columns, h / rows)
	for r in range(-1, rows + 2):
		for c in range(-1, columns + 2):
			var inside := c >= 0 and c <= columns and r >= 0 and r <= rows
			var wobble := Vector2(rng.randf_range(-jitter, jitter), rng.randf_range(-jitter, jitter)) * cell if inside else Vector2.ZERO
			points.append(Vector2(c * cell.x, r * cell.y) + wobble)
	return points

# --- Mountain Dusk ---

static func _dusk(img: Image, rng: RandomNumberGenerator, seed_value: int) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var look := rng.randi_range(0, 2)
	var top_h: float = [0.72, 0.76, 0.6][look] + rng.randf_range(-0.04, 0.04)
	var low_h: float = [0.07, 0.96, 0.5][look] + rng.randf_range(-0.03, 0.03)
	var horizon := int(h * 0.62)
	var top := _hsv(top_h, 0.8, 0.2)
	var mid := _hsv(top_h + (low_h - top_h + (1.0 if low_h < top_h and look != 2 else 0.0)) * 0.55, 0.65, 0.62)
	var low := _hsv(low_h, 0.5, 1.0)
	_rows(img, 0, int(horizon * 0.6), top, mid, 1.2)
	_rows(img, int(horizon * 0.6), horizon + 2, mid, low, 1.1)
	# stars, fading out toward the glow of the horizon
	for i in range(240):
		var x := rng.randi_range(0, w - 1)
		var y := rng.randi_range(0, int(horizon * 0.75))
		var fade := 1.0 - float(y) / (horizon * 0.75)
		var star := top.lerp(Color(1, 1, 0.92), rng.randf_range(0.4, 1.0) * fade)
		var s := 2 if rng.randf() < 0.12 else 1
		img.fill_rect(Rect2i(x, y, s, s), star)
	# the sun (or moon)
	var sun := Vector2(w * rng.randf_range(0.22, 0.78), horizon - h * rng.randf_range(0.02, 0.16))
	var radius := h * rng.randf_range(0.05, 0.085)
	_glow(img, sun, Vector2(radius, radius) * 11.0, _hsv(low_h, 0.45, 1.0, 0.5), 2.2)
	_glow(img, sun, Vector2(radius, radius) * 4.5, _hsv(low_h + 0.02, 0.3, 1.0, 0.7), 1.6)
	_disc(img, sun.x, sun.y, radius, _hsv(low_h + 0.03, 0.14, 1.0))
	# ridges, far to near: pale and hazy, then dark
	var haze := low.lerp(mid, 0.35)
	var dark := _hsv(top_h, 0.55, 0.1)
	var tops := []
	for i in range(6):
		var t := float(i) / 5.0
		var base := lerpf(horizon * 0.9, h * 0.93, pow(t, 1.25))
		var amp := lerpf(h * 0.05, h * 0.17, t)
		var noise := _noise(seed_value + i * 31, lerpf(0.0022, 0.0075, t) * 1448.0 / w)
		var color := haze.lerp(dark, pow(t, 0.8))
		var heights := PackedFloat32Array()
		for x in range(w):
			var y := base - (0.5 + 0.5 * noise.get_noise_1d(x)) * amp * 2.0
			heights.append(y)
			img.fill_rect(Rect2i(x, int(y), 1, h - int(y)), color)
		tops.append(heights)
	# pines along the nearest ridge
	var near: PackedFloat32Array = tops[5]
	for i in range(46):
		var x := rng.randi_range(0, w - 1)
		var ground := near[x] + 4.0
		var tall := h * rng.randf_range(0.04, 0.095)
		for tier in range(3):
			var tw := tall * (0.17 + 0.1 * tier)
			var y_top := ground - tall * (1.0 - tier * 0.27)
			_tri(img, Vector2(x, y_top), Vector2(x - tw, y_top + tall * 0.42), Vector2(x + tw, y_top + tall * 0.42), dark.darkened(0.2))
		img.fill_rect(Rect2i(x - 1, int(ground - tall * 0.12), 3, int(tall * 0.14)), dark.darkened(0.2))

# --- Crystal ---

static func _crystal(img: Image, rng: RandomNumberGenerator) -> void:
	var w := float(img.get_width())
	var h := float(img.get_height())
	var hue := rng.randf()
	var c1 := _hsv(hue, 0.55, 1.0)
	var c2 := _hsv(hue + rng.randf_range(0.1, 0.2), 0.85, 0.42)
	var c3 := _hsv(hue - rng.randf_range(0.08, 0.16), 0.7, 0.8)
	var points := _points(img, rng, 15, 11, 0.4)
	var triangles := Geometry2D.triangulate_delaunay(points)
	for i in range(0, triangles.size(), 3):
		var a := points[triangles[i]]
		var b := points[triangles[i + 1]]
		var c := points[triangles[i + 2]]
		var centre := (a + b + c) / 3.0
		var t := clampf(centre.x / w * 0.55 + centre.y / h * 0.45, 0.0, 1.0)
		var color := c1.lerp(c2, t).lerp(c3, 0.5 + 0.5 * sin(centre.x / w * 5.0 + centre.y / h * 3.0) * 0.5)
		# every facet catches the light a little differently
		var facet := rng.randf_range(-0.16, 0.16)
		color = _hsv(color.h + rng.randf_range(-0.025, 0.025), color.s, color.v + facet)
		if rng.randf() < 0.06:
			color = color.lightened(0.3) # a glint
		_tri(img, a, b, c, color)

# --- Stained Glass ---

static func _stained(img: Image, rng: RandomNumberGenerator) -> void:
	var w := float(img.get_width())
	var h := float(img.get_height())
	var start := rng.randf()
	var jewels := []
	for i in range(7):
		jewels.append(_hsv(start + i / 7.0 + rng.randf_range(-0.02, 0.02), rng.randf_range(0.75, 0.95), rng.randf_range(0.6, 0.85)))
	var points := _points(img, rng, 11, 8, 0.42)
	var triangles := Geometry2D.triangulate_delaunay(points)
	var count := triangles.size() / 3
	var edges := {} # "low-high" point pair -> the triangles on it
	for t in range(count):
		for k in range(3):
			var p := triangles[t * 3 + k]
			var q := triangles[t * 3 + (k + 1) % 3]
			edges.get_or_add("%d-%d" % [mini(p, q), maxi(p, q)], []).append(t)
	# neighbouring facets sometimes share a pane, so the panes are bigger than single triangles
	var pane := PackedInt32Array()
	pane.resize(count)
	pane.fill(-1)
	for t in range(count):
		for k in range(3):
			var p := triangles[t * 3 + k]
			var q := triangles[t * 3 + (k + 1) % 3]
			for other in edges["%d-%d" % [mini(p, q), maxi(p, q)]]:
				if other < t and pane[t] < 0 and rng.randf() < 0.42:
					pane[t] = pane[other]
		if pane[t] < 0:
			pane[t] = rng.randi_range(0, jewels.size() - 1)
	var light := Vector2(w * rng.randf_range(0.25, 0.75), h * rng.randf_range(0.2, 0.6))
	for t in range(count):
		var a := points[triangles[t * 3]]
		var b := points[triangles[t * 3 + 1]]
		var c := points[triangles[t * 3 + 2]]
		var centre := (a + b + c) / 3.0
		var glow := exp(-pow(centre.distance_to(light) / (w * 0.5), 2.0))
		var jewel: Color = jewels[pane[t]]
		_tri(img, a, b, c, _hsv(jewel.h, jewel.s - 0.2 * glow, jewel.v * (0.62 + 0.55 * glow)))
	# the lead holding the panes: only where two different panes meet, and around the edge
	var lead := Color(0.04, 0.035, 0.05)
	var width := maxi(3, int(w / 340.0))
	for key in edges:
		var owners: Array = edges[key]
		if owners.size() == 2 and pane[owners[0]] == pane[owners[1]]:
			continue
		var ends := (key as String).split("-")
		_line(img, points[int(ends[0])], points[int(ends[1])], width, lead)
	var frame := width * 3
	img.fill_rect(Rect2i(0, 0, int(w), frame), lead)
	img.fill_rect(Rect2i(0, int(h) - frame, int(w), frame), lead)
	img.fill_rect(Rect2i(0, 0, frame, int(h)), lead)
	img.fill_rect(Rect2i(int(w) - frame, 0, frame, int(h)), lead)

# --- Nebula ---

static func _nebula(img: Image, rng: RandomNumberGenerator) -> void:
	var w := float(img.get_width())
	var h := float(img.get_height())
	var hue := rng.randf()
	var palette := [hue, hue + rng.randf_range(0.08, 0.16), hue + rng.randf_range(0.45, 0.55), hue - rng.randf_range(0.06, 0.14)]
	img.fill(_hsv(hue, 0.7, 0.05))
	var centres := []
	for i in range(3):
		centres.append(Vector2(w * rng.randf_range(0.15, 0.85), h * rng.randf_range(0.15, 0.85)))
	for i in range(26):
		var centre: Vector2 = centres[i % 3] + Vector2(rng.randf_range(-0.25, 0.25) * w, rng.randf_range(-0.22, 0.22) * h)
		var radius := w * rng.randf_range(0.1, 0.34)
		var squash := rng.randf_range(0.5, 1.0)
		_glow(img, centre, Vector2(radius, radius * squash) * 2.0, _hsv(palette[rng.randi_range(0, 3)], rng.randf_range(0.55, 0.9), rng.randf_range(0.7, 1.0), rng.randf_range(0.14, 0.34)), 1.8)
	for i in range(9): # dark dust lanes
		var radius := w * rng.randf_range(0.06, 0.18)
		_glow(img, Vector2(w * rng.randf(), h * rng.randf()), Vector2(radius * 2.4, radius * 0.8) * 1.4, Color(0.01, 0.0, 0.02, rng.randf_range(0.3, 0.55)), 1.2)
	for centre in centres: # bright cores
		_glow(img, centre, Vector2(w, w) * 0.14, _hsv(hue + 0.05, 0.25, 1.0, 0.55), 2.0)
	for i in range(620):
		var x := rng.randi_range(0, int(w) - 1)
		var y := rng.randi_range(0, int(h) - 1)
		var b := pow(rng.randf(), 2.5)
		img.fill_rect(Rect2i(x, y, 1, 1), _hsv(rng.randf_range(0.0, 1.0), 0.18, 0.55 + 0.45 * b))
	for i in range(34):
		var at := Vector2(rng.randf() * w, rng.randf() * h)
		_disc(img, at.x, at.y, rng.randf_range(1.5, 3.2), Color(1, 1, 0.95))
		_glow(img, at, Vector2(26, 26), _hsv(rng.randf(), 0.4, 1.0, 0.5), 2.0)
	for i in range(6): # the brightest stars carry spikes
		var at := Vector2(rng.randf_range(0.05, 0.95) * w, rng.randf_range(0.05, 0.95) * h)
		var spike := rng.randf_range(0.02, 0.045) * w
		_line(img, at - Vector2(spike, 0), at + Vector2(spike, 0), 2, Color(1, 1, 0.95, 1))
		_line(img, at - Vector2(0, spike), at + Vector2(0, spike), 2, Color(1, 1, 0.95, 1))
		_glow(img, at, Vector2(spike, spike) * 2.4, Color(1, 0.95, 0.85, 0.6), 2.2)

# --- Geometric ---

static func _geometric(img: Image, rng: RandomNumberGenerator) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var hue := rng.randf()
	var palette := [_hsv(hue, 0.78, 0.92), _hsv(hue + 0.5, 0.72, 0.86), _hsv(hue + 0.14, 0.62, 0.96), _hsv(hue + 0.33, 0.55, 0.32), Color(0.96, 0.93, 0.83)]
	var columns := 4
	var rows := 3
	var cw := w / columns
	var ch := h / rows
	for r in range(rows):
		for c in range(columns):
			var area := Rect2i(c * cw, r * ch, cw, ch)
			if c == columns - 1:
				area.size.x = w - area.position.x
			if r == rows - 1:
				area.size.y = h - area.position.y
			if rng.randf() < 0.28: # some cells split into four smaller ones
				for sub in range(4):
					var half := Rect2i(area.position + Vector2i((sub % 2) * area.size.x / 2, (sub / 2) * area.size.y / 2), area.size / 2)
					_cell(img, rng, half, palette)
			else:
				_cell(img, rng, area, palette)

static func _cell(img: Image, rng: RandomNumberGenerator, area: Rect2i, palette: Array) -> void:
	var back: Color = palette[rng.randi_range(0, palette.size() - 1)]
	var ink: Color = palette[rng.randi_range(0, palette.size() - 1)]
	while ink == back:
		ink = palette[rng.randi_range(0, palette.size() - 1)]
	var accent: Color = palette[rng.randi_range(0, palette.size() - 1)]
	# a cell is never one flat colour: it shades from light to dark, and some carry pinstripes
	var light := back.lightened(0.08)
	var shade := back.darkened(0.11)
	for y in range(area.size.y):
		img.fill_rect(Rect2i(area.position.x, area.position.y + y, area.size.x, 1), light.lerp(shade, float(y) / maxi(1, area.size.y - 1)))
	if rng.randf() < 0.5:
		var stripe := back.darkened(0.16)
		for y in range(0, area.size.y, 14):
			img.fill_rect(Rect2i(area.position.x, area.position.y + y, area.size.x, 2), stripe)
	var centre := Vector2(area.position) + Vector2(area.size) * 0.5
	var radius := minf(area.size.x, area.size.y) * 0.5
	match rng.randi_range(0, 6):
		0:
			_disc(img, centre.x, centre.y, radius * 0.82, ink, area)
		1: # a half disc against one side
			var side := Vector2.from_angle(rng.randi_range(0, 3) * PI * 0.5)
			var anchor := centre + side * radius
			_disc(img, anchor.x, anchor.y, radius * 1.02, ink, area)
		2: # a quarter disc in a corner
			var corner := Vector2(area.position) + Vector2(area.size.x if rng.randf() < 0.5 else 0, area.size.y if rng.randf() < 0.5 else 0)
			_disc(img, corner.x, corner.y, radius * 1.7, ink, area)
		3: # diagonal split
			var a := Vector2(area.position)
			var b := Vector2(area.end.x, area.position.y)
			var c := Vector2(area.position.x, area.end.y)
			var d := Vector2(area.end)
			if rng.randf() < 0.5:
				_tri(img, a, b, d, ink)
			else:
				_tri(img, b, d, c, ink)
		4: # concentric rings
			_disc(img, centre.x, centre.y, radius * 0.86, ink, area)
			_disc(img, centre.x, centre.y, radius * 0.6, back, area)
			_disc(img, centre.x, centre.y, radius * 0.34, accent, area)
		5: # a triangle
			var apex := centre + Vector2(0, -radius * 0.8)
			_tri(img, apex, centre + Vector2(-radius * 0.8, radius * 0.7), centre + Vector2(radius * 0.8, radius * 0.7), ink)
		6: # a field of dots
			var step := maxf(radius * 0.5, 8.0)
			var y := float(area.position.y) + step * 0.5
			while y < area.end.y:
				var x := float(area.position.x) + step * 0.5
				while x < area.end.x:
					_disc(img, x, y, step * 0.28, ink, area)
					x += step
				y += step

# --- Sunset Sea ---

static func _sea(img: Image, rng: RandomNumberGenerator) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var sky_h := rng.randf_range(0.6, 0.78)
	var low_h := rng.randf_range(0.0, 0.12)
	var horizon := int(h * rng.randf_range(0.5, 0.6))
	var top := _hsv(sky_h, 0.7, 0.34)
	var low := _hsv(low_h, 0.45, 1.0)
	_rows(img, 0, horizon + 2, top, low, 1.15)
	var sun := Vector2(w * rng.randf_range(0.3, 0.7), horizon - h * rng.randf_range(0.0, 0.1))
	var radius := h * rng.randf_range(0.075, 0.11)
	_glow(img, sun, Vector2(radius, radius) * 10.0, _hsv(low_h, 0.4, 1.0, 0.55), 2.0)
	for i in range(7): # long soft clouds, lit from below
		var at := Vector2(w * rng.randf(), h * rng.randf_range(0.08, 0.42))
		var length := w * rng.randf_range(0.18, 0.4)
		_glow(img, at, Vector2(length, length * rng.randf_range(0.05, 0.12)), _hsv(low_h + rng.randf_range(0.0, 0.08), 0.5, 1.0, rng.randf_range(0.25, 0.5)), 1.4)
	_disc(img, sun.x, sun.y, radius, _hsv(low_h + 0.04, 0.12, 1.0), Rect2i(0, 0, w, horizon + 1))
	# the sea: bands of waves, each nearer and darker than the last
	var far := _hsv(sky_h, 0.45, 0.62).lerp(low, 0.25)
	var near := _hsv(sky_h + 0.04, 0.8, 0.14)
	_rows(img, horizon, h, far, near, 0.9)
	# the sun's reflection: short bright dashes that widen toward the viewer
	for y in range(horizon + 2, h, 2):
		var depth := float(y - horizon) / (h - horizon)
		for k in range(3):
			var half := (0.012 + 0.07 * depth) * w * rng.randf()
			var x := sun.x + rng.randf_range(-1.0, 1.0) * (0.01 + 0.04 * depth) * w
			img.fill_rect(Rect2i(int(x - half), y, int(half * 2.0), 1), _hsv(low_h + 0.04, 0.3, 1.0).lerp(far, depth * 0.55))
	var bands := 9
	for i in range(bands):
		var t := float(i + 1) / bands
		var base := horizon + (h - horizon) * pow(t, 1.45) * 0.97
		var amp := lerpf(2.0, h * 0.032, t)
		var f1 := lerpf(0.02, 0.006, t) * 1448.0 / w
		var f2 := f1 * 2.7
		var p1 := rng.randf() * TAU
		var p2 := rng.randf() * TAU
		var color := far.lerp(near, pow(t, 0.9))
		var crest := color.lerp(_hsv(low_h, 0.3, 1.0), 0.35 * (1.0 - t * 0.6))
		for x in range(w):
			var y := base + sin(x * f1 + p1) * amp + sin(x * f2 + p2) * amp * 0.4
			var y0 := int(y)
			img.fill_rect(Rect2i(x, y0, 1, h - y0), color)
			img.fill_rect(Rect2i(x, y0, 1, maxi(1, int(2 + 3 * t))), crest)
