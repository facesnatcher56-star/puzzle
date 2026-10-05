class_name RunScoreView
extends Control

signal edge_pulse_requested

# Compact shared-run HUD plus short, world-positioned award notices.
const GOLD := Color(1.0, 0.9, 0.6)
const TEAL := Color(0.55, 0.94, 0.84)

var scoring: RunScoring
var manager: PuzzleManager
var score_label: Label
var combo_label: Label
var charge_bar: ProgressBar
var charge_label: Label
var stored_label: Label
var anchors_label: Label
var pulse_button: Button
var _toasts := []

func setup(p_scoring: RunScoring, p_manager: PuzzleManager, p_session: PuzzleSession = null) -> void:
	scoring = p_scoring
	manager = p_manager
	scoring.state_changed.connect(_refresh)
	scoring.awarded.connect(_on_awarded)
	scoring.tier_rose.connect(_on_tier_rose)
	scoring.anchors_completed.connect(_show_anchors_completed)
	manager.piece_changed.connect(_on_piece_changed)
	if p_session != null:
		p_session.puzzle_resetting.connect(_clear_toasts)

func _clear_toasts() -> void:
	for label in _toasts:
		if is_instance_valid(label):
			label.queue_free()
	_toasts.clear()

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -282
	panel.offset_right = -12
	panel.offset_top = 61
	panel.offset_bottom = 199
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.15, 0.17, 0.89)
	style.border_color = Color(0.46, 0.77, 0.7, 0.48)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	style.content_margin_left = 11
	style.content_margin_right = 11
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	panel.add_child(column)
	var top := HBoxContainer.new()
	column.add_child(top)
	score_label = Label.new()
	score_label.add_theme_font_size_override("font_size", 18)
	score_label.add_theme_color_override("font_color", GOLD)
	top.add_child(score_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	combo_label = Label.new()
	combo_label.add_theme_font_size_override("font_size", 14)
	top.add_child(combo_label)
	charge_bar = ProgressBar.new()
	charge_bar.min_value = 0
	charge_bar.max_value = 100
	charge_bar.show_percentage = false
	charge_bar.custom_minimum_size = Vector2(0, 9)
	charge_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(charge_bar)
	var bottom := HBoxContainer.new()
	column.add_child(bottom)
	charge_label = Label.new()
	charge_label.add_theme_font_size_override("font_size", 12)
	charge_label.add_theme_color_override("font_color", TEAL)
	bottom.add_child(charge_label)
	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(bottom_spacer)
	stored_label = Label.new()
	stored_label.add_theme_font_size_override("font_size", 12)
	stored_label.add_theme_color_override("font_color", GOLD)
	bottom.add_child(stored_label)
	var actions := HBoxContainer.new()
	column.add_child(actions)
	anchors_label = Label.new()
	anchors_label.add_theme_font_size_override("font_size", 12)
	anchors_label.add_theme_color_override("font_color", GOLD)
	actions.add_child(anchors_label)
	var action_spacer := Control.new()
	action_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(action_spacer)
	pulse_button = Button.new()
	pulse_button.text = "EDGE PULSE · 1"
	pulse_button.focus_mode = Control.FOCUS_NONE
	pulse_button.add_theme_font_size_override("font_size", 11)
	pulse_button.pressed.connect(func(): edge_pulse_requested.emit())
	actions.add_child(pulse_button)
	_refresh()

func _refresh() -> void:
	if score_label == null:
		return
	score_label.text = "SCORE  %s" % _with_commas(scoring.score)
	var tier := scoring.tier()
	combo_label.text = RunScoring.tier_name(tier)
	if tier > 0:
		combo_label.text += " ×%s" % ["1", "1.25", "1.5", "2"][tier]
	combo_label.add_theme_color_override("font_color", [Color("c8d4d0"), Color("f4d793"), Color("ffac70"), Color("ff746c")][tier])
	charge_bar.value = scoring.charge
	charge_label.text = "CHARGE  %d / 100" % scoring.charge
	stored_label.text = "Power Charges  %d" % scoring.power_charges
	anchors_label.text = "ANCHORS  %d/4" % manager.anchored_corner_count()
	pulse_button.disabled = scoring.power_charges < 1

func _on_piece_changed(piece_id: int) -> void:
	# Host scoring can arrive before the locked-piece snapshots on a client.
	if manager.corner_ids().has(piece_id):
		_refresh()

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
	var notice := Label.new()
	notice.text = "%s+%s\n+%d CHARGE" % [title, _with_commas(int(event.score_gain)), int(event.charge_gain)]
	notice.add_theme_font_size_override("font_size", 19 if count >= 4 else 16)
	notice.add_theme_color_override("font_color", TEAL if int(event.source) == PuzzleManager.ConnectionSource.POWER else GOLD)
	notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(notice)
	notice.position = Vector2(clampf(screen.x - 75, 12, size.x - 165), clampf(screen.y - 45, 170, size.y - 125))
	_toasts.append(notice)
	if _toasts.size() > 4:
		var oldest: Label = _toasts.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()
	var tween := notice.create_tween().set_parallel(true)
	tween.tween_property(notice, "position:y", notice.position.y - 48, 1.3)
	tween.tween_property(notice, "modulate:a", 0.0, 1.3).set_delay(0.3)
	tween.chain().tween_callback(func():
		_toasts.erase(notice)
		notice.queue_free())
	if int(event.charges_gained) > 0:
		_show_charged(int(event.charges_gained))

func _on_tier_rose(_tier: int) -> void:
	if combo_label == null:
		return
	combo_label.scale = Vector2(1.12, 1.12)
	create_tween().tween_property(combo_label, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _show_charged(gained: int) -> void:
	var label := Label.new()
	label.text = "POWER CHARGED!" + (" ×%d" % gained if gained > 1 else "")
	label.add_theme_font_size_override("font_size", 19)
	label.add_theme_color_override("font_color", GOLD)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	label.position = Vector2(maxf(10, size.x - 282), 160)
	_toasts.append(label)
	var tween := label.create_tween()
	tween.tween_interval(0.8)
	tween.tween_property(label, "modulate:a", 0.0, 0.5)
	tween.tween_callback(func():
		_toasts.erase(label)
		label.queue_free())

func _show_anchors_completed() -> void:
	if anchors_label == null:
		return
	var label := Label.new()
	label.text = "ALL CORNERS ANCHORED\n+1 POWER CHARGE"
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", GOLD)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	label.position = Vector2(maxf(10, size.x - 282), 206)
	_toasts.append(label)
	var tween := label.create_tween()
	tween.tween_interval(1.6)
	tween.tween_property(label, "modulate:a", 0.0, 0.6)
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
