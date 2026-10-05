class_name Sfx
extends Node

# All sounds are synthesized here at runtime (no audio files), so the game stays small and every
# effect can be tuned in code. Snaps scale with how big the joined group is, and consecutive snaps
# climb a pentatonic scale so a run of good joins sounds like a little melody.

const RATE := 32000
# Semitones above C5, pentatonic over two octaves.
const SCALE := [0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24]
const STREAK_WINDOW_MSEC := 4500

var enabled := DisplayServer.get_name() != "headless"
var players: Array[AudioStreamPlayer] = []
var next_player := 0
var streak := 0
var last_snap_msec := -100000
var cache := {}

func _ready() -> void:
	for i in range(10):
		var player := AudioStreamPlayer.new()
		add_child(player)
		players.append(player)

# --- public sounds ---

func snap(group_size: int, huge: bool = false) -> void:
	var now := Time.get_ticks_msec()
	streak = streak + 1 if now - last_snap_msec < STREAK_WINDOW_MSEC else 0
	last_snap_msec = now
	var note: int = SCALE[mini(streak, SCALE.size() - 1)]
	var kind := "small"
	if huge:
		kind = "huge"
	elif group_size >= 30:
		kind = "large"
	elif group_size >= 8:
		kind = "medium"
	_play(_stream("%s_%d" % [kind, note], func(): return _render_snap(kind, note)), -4.0 if kind == "small" else -2.0)

func drop() -> void:
	_play(_stream("drop", func(): return _render_tap(0.9)), -12.0)

func lock() -> void:
	_play(_stream("lock", func(): return _render_lock()), 0.0)

func pickup() -> void:
	_play(_stream("pickup", func(): return _render_tap(0.5)), -18.0)

func complete() -> void:
	_play(_stream("complete", func(): return _render_complete()), -1.0)

# --- playback ---

func _play(stream: AudioStream, volume_db: float) -> void:
	if not enabled or players.is_empty():
		return
	var player := players[next_player]
	next_player = (next_player + 1) % players.size()
	player.stream = stream
	player.volume_db = volume_db
	player.play()

func _stream(key: String, builder: Callable) -> AudioStream:
	if not cache.has(key):
		cache[key] = builder.call()
	return cache[key]

# --- synthesis ---

static func _freq(semitones_above_c5: int) -> float:
	return 523.25 * pow(2.0, semitones_above_c5 / 12.0)

# A quick wooden "thock": a pitch-dropping thump plus a tiny click.
static func _thock(t: float, weight: float) -> float:
	if t < 0.0:
		return 0.0
	var thump := sin(TAU * (80.0 + 170.0 * exp(-t * 55.0)) * t) * exp(-t * 34.0)
	var click := (randf() * 2.0 - 1.0) * exp(-t * 420.0) * 0.35
	return (thump * 0.85 + click) * weight

# A soft bell: fundamental plus two inharmonic partials, fast attack, smooth decay.
static func _bell(t: float, freq: float, decay: float, level: float) -> float:
	if t < 0.0:
		return 0.0
	var attack := 1.0 - exp(-t * 900.0)
	var tone := sin(TAU * freq * t) + 0.42 * sin(TAU * freq * 2.01 * t) * exp(-t * 4.0) + 0.18 * sin(TAU * freq * 3.97 * t) * exp(-t * 9.0)
	return tone * exp(-t * decay) * attack * level

static func _sparkle(t: float, freq: float, level: float) -> float:
	if t < 0.0:
		return 0.0
	return sin(TAU * freq * t) * exp(-t * 26.0) * (1.0 - exp(-t * 2000.0)) * level

func _make(duration: float, sampler: Callable) -> AudioStreamWAV:
	var count := int(duration * RATE)
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	for i in range(count):
		var sample: float = sampler.call(float(i) / RATE)
		bytes.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	return wav

func _render_tap(weight: float) -> AudioStreamWAV:
	return _make(0.18, func(t: float): return _thock(t, 0.55 * weight))

func _render_snap(kind: String, note: int) -> AudioStreamWAV:
	var f := _freq(note)
	match kind:
		"small":
			return _make(0.75, func(t: float): return _thock(t, 0.8) + _bell(t, f, 7.0, 0.32))
		"medium":
			return _make(1.0, func(t: float):
				return _thock(t, 1.0) + _bell(t, f, 5.5, 0.30) + _bell(t - 0.045, f * 1.5, 5.5, 0.22) + _bell(t - 0.09, f * 2.0, 6.0, 0.16))
		"large":
			return _make(1.5, func(t: float):
				var boom := sin(TAU * 58.0 * t) * exp(-t * 6.0) * 0.5
				return _thock(t, 1.1) + boom + _bell(t, f, 4.2, 0.28) + _bell(t - 0.06, f * 1.25, 4.2, 0.22) + _bell(t - 0.12, f * 1.5, 4.2, 0.22) + _bell(t - 0.18, f * 2.0, 4.6, 0.2) + _sparkle(t - 0.2, f * 6.0, 0.08))
	# huge: a big, resonant chord with a rising shimmer
	return _make(2.2, func(t: float):
		var boom := sin(TAU * 49.0 * t) * exp(-t * 4.0) * 0.6
		var sound := _thock(t, 1.2) + boom
		for step in range(5):
			sound += _bell(t - step * 0.07, f * [1.0, 1.25, 1.5, 2.0, 2.5][step], 3.0, 0.2)
		for k in range(6):
			sound += _sparkle(t - 0.25 - k * 0.07, f * 4.0 * (1.0 + k * 0.12), 0.07)
		return sound)

# A heavy, satisfying "clunk" like a bolt sliding home: deep thump, a metallic ping and a settling chord.
func _render_lock() -> AudioStreamWAV:
	return _make(1.3, func(t: float):
		var boom := sin(TAU * (62.0 + 90.0 * exp(-t * 30.0)) * t) * exp(-t * 7.0) * 0.75
		var clank := sin(TAU * 2350.0 * t) * exp(-t * 38.0) * 0.28 + sin(TAU * 3510.0 * t) * exp(-t * 52.0) * 0.18
		var slide := _thock(t - 0.07, 0.9)
		var settle := _bell(t - 0.1, _freq(-5), 4.0, 0.22) + _bell(t - 0.1, _freq(2), 4.0, 0.16) + _bell(t - 0.16, _freq(7), 4.4, 0.14)
		return _thock(t, 1.3) + boom + clank + slide + settle)

func _render_complete() -> AudioStreamWAV:
	var arpeggio := [0, 4, 7, 12, 16, 19, 24]
	return _make(4.2, func(t: float):
		var sound := _thock(t, 1.0) + sin(TAU * 49.0 * t) * exp(-t * 3.0) * 0.45
		for i in range(arpeggio.size()):
			sound += _bell(t - i * 0.085, _freq(arpeggio[i]), 2.8, 0.2)
		# final swelling chord
		var swell := clampf((t - 0.7) * 3.0, 0.0, 1.0) * exp(-(maxf(t - 0.7, 0.0)) * 1.1)
		for semitone in [0, 7, 12, 16, 24]:
			sound += sin(TAU * _freq(semitone) * t) * swell * 0.07
			sound += sin(TAU * _freq(semitone) * 1.003 * t) * swell * 0.05
		for k in range(14):
			sound += _sparkle(t - 0.9 - k * 0.11, 2200.0 + (k * 337) % 1800, 0.06)
		return sound)
