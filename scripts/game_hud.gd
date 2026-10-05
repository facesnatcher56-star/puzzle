class_name GameHud
extends Control

# The whole permanent HUD: one thin strip along the top -- SCORE, combo, CHARGE bar, stored Power Charges as
# diamonds, then the network state and a menu button -- plus the short-lived things the board earns: the
# "anchor the corners" objective (only until the four corners are down), award notices that float up from where
# pieces joined, and "POWER CHARGED". Everything else (piece count, restart, new puzzle...) lives behind the pause
# menu or the bank's "⋯" button so the puzzle keeps the screen.

signal menu_requested

const HEIGHT := 36.0
const TABLE_TOP := HEIGHT + 30.0 # the table starts below the strip and the objective band under it
const GOLD := Color(1.0, 0.9, 0.6)
const TEAL := Color(0.55, 0.94, 0.84)
const TIER_COLORS := [Color("9fb0ad"), Color("f4d793"), Color("ffac70"), Color("ff746c")]

var scoring: RunScoring
var manager: PuzzleManager
var session: PuzzleSession

var score_label: Label
var combo_flame: Flame
var combo_label: Label
var charge_bar: ProgressBar
var charge_label: Label
var charges: Diamonds
var objective_label: Label
var network_label: Label
var menu_button: Button
var _toasts := []
var _objective_done := false # the four corners have been anchored in this puzzle; the objective never comes back

# A small flame beside the combo name, drawn in the combo's colour (nothing at all while the combo is NORMAL).
class Flame extends Control:
	var color := Color.WHITE
	func _init() -> void:
		custom_minimum_size = Vector2(14, 20)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var points := PackedVector2Array([Vector2(7, 1), Vector2(12, 9), Vector2(11, 16), Vector2(7, 19), Vector2(3, 16), Vector2(2, 9), Vector2(5, 11), Vector2(6, 5)])
		draw_colored_polygon(points, color)

# Stored Power Charges as diamonds, "◆◆ 2": one filled diamond per charge, up to five, then a count.
class Diamonds extends Control:
	const MAX_SHOWN := 5
	var count := 0
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(28, 22)
	func set_count(value: int) -> void:
		count = value
		custom_minimum_size.x = 28.0 + 15.0 * mini(maxi(count, 1), MAX_SHOWN) + (22.0 if count > MAX_SHOWN else 0.0)
		queue_redraw()
	func _draw() -> void:
		var shown := mini(count, MAX_SHOWN)
		if count == 0:
			_diamond(Vector2(8, 11), 6.0, Color(0.5, 0.58, 0.58, 0.45), false)
			return
		for i in range(shown):
			_diamond(Vector2(8 + i * 15, 11), 6.0, Color(1.0, 0.86, 0.45), true)
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(8 + shown * 15, 16), "%d" % count if count <= MAX_SHOWN else "×%d" % count, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.9, 0.6))
	func _diamond(center: Vector2, radius: float, color: Color, filled: bool) -> void:
		var points := PackedVector2Array([center + Vector2(0, -radius), center + Vector2(radius, 0), center + Vector2(0, radius), center + Vector2(-radius, 0)])
		if filled:
			draw_colored_polygon(points, color)
		else:
			points.append(points[0])
			draw_polyline(points, color, 1.6, true)

func setup(p_scoring: RunScoring, p_manager: PuzzleManager, p_session: PuzzleSession = null) -> void:
	scoring = p_scoring
	manager = p_manager
	session = p_session
	scoring.state_changed.connect(_refresh)
	scoring.awarded.connect(_on_awarded)
	scoring.tier_rose.connect(_on_tier_rose)
	scoring.anchors_completed.connect(_on_anchors_completed)
	manager.piece_changed.connect(_on_piece_changed)
	if session != null:
		session.puzzle_resetting.connect(_on_puzzle_resetting)
		session.puzzle_started.connect(func(_pieces): _on_puzzle_replaced())
		session.puzzle_restored.connect(func(_pieces): _on_puzzle_replaced())

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var strip := PanelContainer.new()
	strip.anchor_right = 1.0
	strip.offset_bottom = HEIGHT
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.1, 0.12, 0.94)
	style.border_color = Color(0.46, 0.77, 0.7, 0.3)
	style.border_width_bottom = 1
	style.content_margin_left = 14
	style.content_margin_right = 8
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	strip.add_theme_stylebox_override("panel", style)
	add_child(strip)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	strip.add_child(row)
	score_label = _label(17, GOLD)
	score_label.custom_minimum_size.x = 150
	row.add_child(score_label)
	var combo := HBoxContainer.new()
	combo.add_theme_constant_override("separation", 4)
	combo_flame = Flame.new()
	combo.add_child(combo_flame)
	combo_label = _label(14, TIER_COLORS[0])
	combo_label.custom_minimum_size.x = 150
	combo.add_child(combo_label)
	row.add_child(combo)
	var charge := HBoxContainer.new()
	charge.add_theme_constant_override("separation", 7)
	charge.add_child(_label(11, Color(0.55, 0.94, 0.84, 0.75), "CHARGE"))
	charge_bar = ProgressBar.new()
	charge_bar.min_value = 0
	charge_bar.max_value = 100
	charge_bar.show_percentage = false
	charge_bar.custom_minimum_size = Vector2(150, 10)
	charge_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	charge_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.14, 0.2, 0.22)
	track.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.45, 0.88, 0.78)
	fill.set_corner_radius_all(4)
	charge_bar.add_theme_stylebox_override("background", track)
	charge_bar.add_theme_stylebox_override("fill", fill)
	charge.add_child(charge_bar)
	charge_label = _label(12, TEAL)
	charge.add_child(charge_label)
	row.add_child(charge)
	charges = Diamonds.new()
	row.add_child(charges)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	network_label = _label(11, Color("9fd6c8"), "")
	row.add_child(network_label)
	menu_button = Button.new()
	menu_button.text = "☰"
	menu_button.focus_mode = Control.FOCUS_NONE
	menu_button.flat = true
	menu_button.custom_minimum_size = Vector2(44, 30)
	menu_button.add_theme_font_size_override("font_size", 19)
	menu_button.tooltip_text = "Pause menu (Esc)"
	menu_button.pressed.connect(func(): menu_requested.emit())
	row.add_child(menu_button)
	objective_label = _label(14, GOLD)
	objective_label.anchor_left = 0.5
	objective_label.anchor_right = 0.5
	objective_label.offset_left = -170
	objective_label.offset_right = 170
	objective_label.offset_top = HEIGHT + 5
	objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	objective_label.add_theme_color_override("font_outline_color", Color(0.04, 0.07, 0.08, 0.9))
	objective_label.add_theme_constant_override("outline_size", 5)
	add_child(objective_label)
	_refresh()

func _label(font_size: int, color: Color, text: String = "") -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func set_network_status(text: String) -> void:
	if network_label != null:
		network_label.text = text

# --- the strip ---

func _refresh() -> void:
	if score_label == null:
		return
	score_label.text = "SCORE  %s" % _with_commas(scoring.score)
	var tier := scoring.tier()
	combo_label.text = "NO STREAK" if scoring.streak == 0 else "STREAK %d  ×%s" % [scoring.streak, RunScoring.format_multiplier(scoring.multiplier())]
	combo_label.add_theme_color_override("font_color", TIER_COLORS[tier])
	combo_flame.color = TIER_COLORS[tier]
	combo_flame.visible = tier > 0
	charge_bar.value = scoring.charge
	charge_label.text = "%d/100" % scoring.charge
	charges.set_count(scoring.power_charges)
	_refresh_objective()

# The objective is shown only while the four corners are not all down, and once they are, never again for this puzzle.
func _refresh_objective() -> void:
	if objective_label == null:
		return
	var anchored := manager.anchored_corner_count()
	if anchored >= 4 or scoring.anchors_rewarded:
		_objective_done = true
	objective_label.visible = not _objective_done and not manager.pieces.is_empty()
	objective_label.text = "ANCHOR THE CORNERS  %d/4" % anchored

func _on_piece_changed(piece_id: int) -> void:
	# Host scoring can arrive before the locked-piece snapshots on a client.
	if manager.corner_ids().has(piece_id):
		_refresh()

func _on_puzzle_resetting() -> void:
	for label in _toasts:
		if is_instance_valid(label):
			label.queue_free()
	_toasts.clear()
	_objective_done = false

func _on_puzzle_replaced() -> void:
	_objective_done = false
	_refresh()

# --- notices ---

func _on_awarded(event: Dictionary) -> void:
	if manager.pieces.is_empty():
		return
	var ids: Array = event.get("piece_ids", [])
	if ids.is_empty():
		return
	var centre := Vector2.ZERO
	for id in ids:
		var piece: PuzzlePieceState = manager.pieces[id]
		centre += piece.correct_position + piece.piece_size * 0.5
	centre /= ids.size()
	var screen := get_viewport().get_canvas_transform() * centre
	var count := int(event.piece_count)
	var title := "%d PIECE JOIN\n" % count if count > 1 else ""
	# the score is everyone's; the streak and Charge are only shown to the player they belong to
	var mine := int(event.get("player", RunScoring.HOST_KEY)) == scoring.local_key()
	if mine and bool(event.get("first_try", false)):
		title = "FIRST TRY!  STREAK %d  ×%s\n" % [int(event.streak), RunScoring.format_multiplier(float(event.multiplier))] + title
	var notice := Label.new()
	notice.text = "%s+%s" % [title, _with_commas(int(event.score_gain))]
	if mine:
		notice.text += "\n+%d CHARGE" % int(event.charge_gain)
	notice.add_theme_font_size_override("font_size", 19 if count >= 4 else 16)
	notice.add_theme_color_override("font_color", TEAL if int(event.source) == PuzzleManager.ConnectionSource.POWER else GOLD)
	notice.add_theme_color_override("font_outline_color", Color(0.04, 0.07, 0.08, 0.85))
	notice.add_theme_constant_override("outline_size", 4)
	notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(notice)
	notice.position = Vector2(clampf(screen.x - 75, 12, maxf(12.0, size.x - 165)), clampf(screen.y - 45, HEIGHT + 40, maxf(HEIGHT + 40, size.y - 190)))
	_keep_toast(notice)
	var tween := notice.create_tween().set_parallel(true)
	tween.tween_property(notice, "position:y", notice.position.y - 48, 1.3)
	tween.tween_property(notice, "modulate:a", 0.0, 1.3).set_delay(0.3)
	tween.chain().tween_callback(func():
		_toasts.erase(notice)
		notice.queue_free())
	if mine and int(event.charges_gained) > 0:
		_show_banner("POWER CHARGED!" + (" ×%d" % int(event.charges_gained) if int(event.charges_gained) > 1 else ""), 19, 0.8)

func _keep_toast(label: Label) -> void:
	_toasts.append(label)
	if _toasts.size() > 4:
		var oldest: Label = _toasts.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()

func _on_tier_rose(_tier: int) -> void:
	if combo_label == null:
		return
	combo_label.pivot_offset = combo_label.size * 0.5
	combo_label.scale = Vector2(1.18, 1.18)
	create_tween().tween_property(combo_label, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _on_anchors_completed(player: int) -> void:
	_objective_done = true
	_refresh_objective()
	_show_banner("ALL CORNERS ANCHORED" + ("\n+1 POWER CHARGE" if player == scoring.local_key() else ""), 17, 1.6)

# A centred banner under the strip that holds for `hold` seconds, then fades.
func _show_banner(text: String, font_size: int, hold: float) -> void:
	var label := _label(font_size, GOLD, text)
	label.add_theme_color_override("font_color", GOLD)
	label.add_theme_color_override("font_outline_color", Color(0.04, 0.07, 0.08, 0.9))
	label.add_theme_constant_override("outline_size", 5)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.anchor_left = 0.5
	label.anchor_right = 0.5
	label.offset_left = -190
	label.offset_right = 190
	label.offset_top = HEIGHT + 40 + 34 * _toasts.size()
	add_child(label)
	_keep_toast(label)
	var tween := label.create_tween()
	tween.tween_interval(hold)
	tween.tween_property(label, "modulate:a", 0.0, 0.5)
	tween.tween_callback(func():
		_toasts.erase(label)
		label.queue_free())

static func _with_commas(value: int) -> String:
	var digits := str(value)
	var result := ""
	while digits.length() > 3:
		result = "," + digits.substr(digits.length() - 3, 3) + result
		digits = digits.substr(0, digits.length() - 3)
	return digits + result
