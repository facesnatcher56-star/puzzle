class_name AbilityBar
extends Control

# The player's powers, in a small bar just above the piece bank: numbered slots (hotkeys 1-4) that show an icon,
# the Power Charge cost and whether you can afford it, plus a rotate button for touch players. Slots mostly show
# icons, with a short tooltip on hover.
#
# Using a power: select a group on the table and press its number or click its slot. With nothing selected the
# slot enters targeting mode and the next group you click becomes the target; Esc (or clicking empty table)
# cancels. Hovering a slot -- or holding a finger on it -- faintly previews where the power could act on the
# current selection, and releasing on the slot uses it.
# The bar decides nothing about the puzzle: it emits `ability_requested` and the matching controller acts.

signal ability_requested(ability_id: String, piece_id: int)
# The slot is being hovered or held with `piece_id` selected (-1 when it stops), so the board can preview it.
signal preview_changed(ability_id: String, piece_id: int)
signal targeting_changed(active: bool)
signal rotate_requested

const SLOT_COUNT := 4
const HEIGHT := 64.0
const GAP := 7.0
const GOLD := Color(1.0, 0.88, 0.5)
const TEAL := Color(0.55, 0.94, 0.84)

# What each slot holds. Slots past the end of this list are not unlocked yet and show "?".
const ABILITIES := [
	{"id": "cluster_surge", "name": "Cluster Surge", "cost": 1,
		"text": "Pulls up to 3 of the selected group's correct neighbours onto it and snaps them in. Select a group first, or press the number and then click one."},
]

var power_charges := 0
var selection := Callable() # () -> int: the group selected on the table, or -1
var can_use := Callable() # (ability_id: String, piece_id: int) -> bool
var targeting_slot := -1
var slots: Array = []
var rotate_button: ToolButton
var hint: Label
var _hint_tween: Tween

# One numbered slot (or the rotate button): draws itself and reports presses to the bar.
class Slot extends Control:
	var bar: AbilityBar
	var index := -1 # -1 for the rotate button
	var held := false
	var hovered := false
	var denied := 0.0 # 1 -> 0 after a refused use, shown as a red flash

	func _init(p_bar: AbilityBar, p_index: int) -> void:
		bar = p_bar
		index = p_index
		var touch := DisplayServer.is_touchscreen_available()
		custom_minimum_size = Vector2(78, 62) if touch else Vector2(66, 56)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_entered.connect(func():
			hovered = true
			bar._slot_hover(self, true)
			queue_redraw())
		mouse_exited.connect(func():
			hovered = false
			held = false
			bar._slot_hover(self, false)
			queue_redraw())

	func ability() -> Dictionary:
		return AbilityBar.ABILITIES[index] if index >= 0 and index < AbilityBar.ABILITIES.size() else {}

	func shake() -> void:
		denied = 1.0
		create_tween().tween_method(func(v: float):
			denied = v
			queue_redraw(), 1.0, 0.0, 0.45)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				held = true
				bar._slot_hover(self, true)
			else:
				var was_held := held
				held = false
				bar._slot_hover(self, hovered)
				if was_held and Rect2(Vector2.ZERO, size).has_point(event.position):
					bar._slot_pressed(self)
			queue_redraw()
			accept_event()

	func _draw() -> void:
		var info := ability()
		var unlocked := index < 0 or not info.is_empty()
		var affordable := index < 0 or (unlocked and bar.power_charges >= int(info.cost))
		var targeting := index >= 0 and bar.targeting_slot == index
		var tint := Color.WHITE if (hovered or targeting or held) else Color(0.8, 0.85, 0.85)
		if denied > 0.0:
			tint = Color.WHITE.lerp(Color(1.0, 0.35, 0.3), denied)
		if affordable and unlocked and index >= 0 and not (hovered or targeting or held):
			# a ready power breathes a little
			tint = tint.lightened(0.08 + 0.06 * sin(Time.get_ticks_msec() * 0.004))
			queue_redraw()
		draw_style_box(UiStyle.slot(targeting or held or (hovered and unlocked), tint), Rect2(Vector2.ZERO, size))
		if (targeting or held) and unlocked:
			draw_texture_rect(UiStyle.GLOW, Rect2(Vector2(-14, -14), size + Vector2(28, 28)), false, Color(1.0, 0.85, 0.4, 0.28))
		var fade := 1.0 if (affordable and unlocked) else 0.4
		if index < 0:
			AbilityBar.draw_rotate_icon(self, size * 0.5 + Vector2(0, 2), minf(size.x, size.y) * 0.5, Color(0.8, 0.9, 0.88, 0.85))
			_corner_text("R", Vector2(7, 14), Color(0.7, 0.8, 0.8, 0.8))
			return
		if not unlocked:
			var font := ThemeDB.fallback_font
			draw_string(font, Vector2(0, size.y * 0.62), "?", HORIZONTAL_ALIGNMENT_CENTER, size.x, 28, Color(0.55, 0.65, 0.65, 0.4))
			_corner_text(str(index + 1), Vector2(7, 14), Color(0.7, 0.8, 0.8, 0.45))
			return
		AbilityBar.draw_surge_icon(self, size * 0.5 + Vector2(-3, 0), minf(size.x, size.y) * 1.08, fade)
		_corner_text(str(index + 1), Vector2(7, 14), Color(1.0, 0.92, 0.7, fade))
		# the cost: a diamond (a Power Charge) and its number
		var cost_at := Vector2(size.x - 28, size.y - 13)
		AbilityBar.draw_diamond(self, cost_at, 5.0, Color(1.0, 0.86, 0.45, fade))
		draw_string(ThemeDB.fallback_font, cost_at + Vector2(8, 5), str(int(info.cost)), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.92, 0.7, fade))

	func _corner_text(text: String, at: Vector2, color: Color) -> void:
		draw_string(ThemeDB.fallback_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, color)

class ToolButton extends Slot:
	pass

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(GAP))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	rotate_button = ToolButton.new(self, -1)
	rotate_button.tooltip_text = "Rotate the selected group (R)"
	row.add_child(rotate_button)
	var divider := Control.new()
	divider.custom_minimum_size.x = 8
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(divider)
	for i in range(SLOT_COUNT):
		var slot := Slot.new(self, i)
		slot.tooltip_text = tooltip_for(i)
		row.add_child(slot)
		slots.append(slot)
	var slot_size: Vector2 = slots[0].custom_minimum_size
	var width := rotate_button.custom_minimum_size.x + 8 + SLOT_COUNT * slot_size.x + (SLOT_COUNT + 1) * GAP
	offset_left = -width * 0.5
	offset_right = width * 0.5
	row.position = Vector2(0, 0)
	row.size = Vector2(width, slot_size.y)
	hint = Label.new()
	hint.visible = false
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", GOLD)
	hint.add_theme_color_override("font_outline_color", Color(0.04, 0.07, 0.08, 0.92))
	hint.add_theme_constant_override("outline_size", 5)
	hint.anchor_right = 1.0
	hint.offset_left = -120
	hint.offset_right = 120
	hint.offset_top = -26
	add_child(hint)
	rotate_button.set_meta("rotate", true)
	_place_above(178.0)

# Keeps the bar just above the piece bank, whatever height the bank has been dragged to.
func reposition(bank_height: float) -> void:
	_place_above(bank_height)

func _place_above(bank_height: float) -> void:
	offset_bottom = -bank_height - 6.0
	offset_top = offset_bottom - HEIGHT

func tooltip_for(index: int) -> String:
	if index >= ABILITIES.size():
		return "Locked - a new power will go here"
	var info: Dictionary = ABILITIES[index]
	return "%s  [%d]\nCost: %d Power Charge\n%s" % [info.name, index + 1, info.cost, info.text]

func set_power_charges(value: int) -> void:
	power_charges = value
	for slot in slots:
		slot.queue_redraw()

# --- slot input ---

func _slot_hover(slot: Slot, active: bool) -> void:
	if slot.index < 0:
		return
	var info := slot.ability()
	if info.is_empty():
		return
	var piece := _selected()
	if active and piece >= 0 and power_charges >= int(info.cost):
		preview_changed.emit(info.id, piece)
	else:
		preview_changed.emit(info.id, -1)

func _slot_pressed(slot: Slot) -> void:
	if slot.index < 0:
		rotate_requested.emit()
	else:
		trigger_slot(slot.index)

# --- using a power ---

func _selected() -> int:
	return int(selection.call()) if selection.is_valid() else -1

# A slot's hotkey or click. Uses the power on the selected group, or starts targeting if nothing is selected.
func trigger_slot(index: int) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return
	if index >= ABILITIES.size():
		slots[index].shake()
		_say("Nothing here yet")
		return
	var info: Dictionary = ABILITIES[index]
	if power_charges < int(info.cost):
		slots[index].shake()
		_say("Needs %d Power Charge" % int(info.cost))
		return
	var piece := _selected()
	if piece < 0:
		_set_targeting(index)
		return
	_use(index, piece)

# The input controller calls this for a click on the table while targeting. Returns true if the click was used up.
func complete_targeting(piece_id: int) -> bool:
	if targeting_slot < 0:
		return false
	var index := targeting_slot
	_set_targeting(-1)
	if piece_id >= 0:
		_use(index, piece_id)
	return true

func cancel_targeting() -> bool:
	if targeting_slot < 0:
		return false
	_set_targeting(-1)
	return true

func is_targeting() -> bool:
	return targeting_slot >= 0

func _use(index: int, piece_id: int) -> void:
	var info: Dictionary = ABILITIES[index]
	if can_use.is_valid() and not bool(can_use.call(info.id, piece_id)):
		slots[index].shake()
		_say("Nothing to pull from there")
		return
	_set_targeting(-1)
	preview_changed.emit(info.id, -1)
	ability_requested.emit(info.id, piece_id)

func _set_targeting(index: int) -> void:
	var was := targeting_slot >= 0
	targeting_slot = index
	if index >= 0:
		_say("Pick a group for %s  ·  Esc to cancel" % ABILITIES[index].name, 0.0)
	elif hint != null:
		hint.visible = false
	for slot in slots:
		slot.queue_redraw()
	if (index >= 0) != was:
		targeting_changed.emit(index >= 0)

# A short message above the bar; `seconds` of 0 keeps it up until the next one (used for targeting).
func _say(text: String, seconds: float = 1.4) -> void:
	if hint == null:
		return
	if _hint_tween != null and _hint_tween.is_valid():
		_hint_tween.kill()
	hint.text = text
	hint.modulate.a = 1.0
	hint.visible = true
	if seconds > 0.0:
		_hint_tween = create_tween()
		_hint_tween.tween_interval(seconds)
		_hint_tween.tween_property(hint, "modulate:a", 0.0, 0.3)
		_hint_tween.tween_callback(func(): hint.visible = false)

# --- icons (drawn, so they stay sharp at any size) ---

static func draw_diamond(canvas: CanvasItem, center: Vector2, radius: float, color: Color) -> void:
	UiStyle.draw_gem(canvas, center, radius * 3.0, color)

static func draw_rotate_icon(canvas: CanvasItem, center: Vector2, size: float, color: Color) -> void:
	var radius := size * 0.28
	canvas.draw_arc(center, radius, -0.3 * PI, 1.35 * PI, 24, color, 2.6, true)
	var tip := center + Vector2.from_angle(1.35 * PI) * radius
	canvas.draw_colored_polygon(PackedVector2Array([tip + Vector2(-5, -5), tip + Vector2(6, -2), tip + Vector2(-1, 6)]), color)

# Cluster Surge: three joined puzzle cells (gold) with energy arrows drawing three more cells in toward them.
# Deliberately not a magnet -- Magnet belongs to the board.
static func draw_surge_icon(canvas: CanvasItem, center: Vector2, size: float, fade: float = 1.0) -> void:
	var u := size * 0.2
	var gold := Color(1.0, 0.86, 0.45, fade)
	var teal := Color(0.55, 0.94, 0.84, fade)
	# the cluster: an L of three cells, joined by little tabs
	var cells := [Vector2(-0.55, -0.55), Vector2(0.55, -0.55), Vector2(-0.55, 0.55)]
	for cell in cells:
		var origin: Vector2 = center + cell * u - Vector2(u, u) * 0.5
		canvas.draw_rect(Rect2(origin, Vector2(u, u)), gold, true)
		canvas.draw_rect(Rect2(origin, Vector2(u, u)), Color(0.15, 0.11, 0.04, 0.55 * fade), false, 1.2)
	canvas.draw_circle(center + Vector2(0, -0.55) * u, u * 0.16, Color(0.15, 0.11, 0.04, 0.6 * fade))
	canvas.draw_circle(center + Vector2(-0.55, 0) * u, u * 0.16, Color(0.15, 0.11, 0.04, 0.6 * fade))
	# the incoming cells, drawn hollow, each with an arrow pointing at the cluster
	var incoming := [[Vector2(1.9, -0.55), Vector2(-1, 0)], [Vector2(1.5, 1.2), Vector2(-0.7, -0.7)], [Vector2(-0.55, 1.95), Vector2(0, -1)]]
	for entry in incoming:
		var spot: Vector2 = center + (entry[0] as Vector2) * u
		var direction: Vector2 = (entry[1] as Vector2).normalized()
		canvas.draw_rect(Rect2(spot - Vector2(u, u) * 0.4, Vector2(u, u) * 0.8), teal, false, 1.6)
		var tail := spot + direction * u * 0.55
		var tip := tail + direction * u * 0.75
		canvas.draw_line(tail, tip, teal, 1.8, true)
		var side := Vector2(-direction.y, direction.x)
		canvas.draw_colored_polygon(PackedVector2Array([tip + direction * u * 0.28, tip + side * u * 0.2, tip - side * u * 0.2]), teal)
