class_name PieceBank
extends Control

signal piece_hovered(piece_id: int, screen_position: Vector2)
signal piece_unhovered(piece_id: int)
signal piece_pressed(piece_id: int, screen_position: Vector2)
signal action_requested(action: String)

var pieces: Array[PuzzlePieceState] = []
var display_order: Array[int] = []
var source: Texture2D
var bank_height := 178.0
var expanded_height := 178.0
var collapsed := false
var filter_name := "ALL"
var selected_id := -1
var scroll: ScrollContainer
var row: HBoxContainer
var header_scroll: ScrollContainer
var header: HBoxContainer
var count_label: Label
var placed_label: Label
var buttons := {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	_apply_height()
	header_scroll = ScrollContainer.new()
	header_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	header_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(header_scroll)
	header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	header_scroll.add_child(header)
	for label in ["ALL", "EDGES", "CORNERS", "TRAY 1"]:
		_add_button(label, "filter:" + label)
	_add_button("TO TRAY 1", "assign_tray")
	_add_button("SPREAD PIECES", "spread")
	_add_button("RESET", "reset")
	_add_button("NEW", "new")
	_add_button("REFERENCE", "reference")
	_add_button("▾ BANK", "collapse")
	count_label = Label.new()
	count_label.add_theme_color_override("font_color", Color("dce7e6"))
	header.add_child(count_label)
	placed_label = Label.new()
	placed_label.add_theme_color_override("font_color", Color("a6b9b9"))
	header.add_child(placed_label)
	scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	scroll.add_child(row)
	resized.connect(_layout)
	_layout()

func _add_button(label: String, action: String) -> void:
	var button := Button.new()
	button.text = label
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.y = 30
	button.add_theme_font_size_override("font_size", 13)
	button.pressed.connect(func(): action_requested.emit(action))
	header.add_child(button)
	buttons[action] = button

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("202b33"), true)
	draw_line(Vector2(0, 0), Vector2(size.x, 0), Color("7b8d91"), 2.0)
	draw_rect(Rect2(Vector2(size.x * 0.5 - 26, 3), Vector2(52, 4)), Color("819397"), true)

func _layout() -> void:
	if header == null:
		return
	header_scroll.position = Vector2(12, 12)
	header_scroll.size = Vector2(size.x - 24, 39)
	header.custom_minimum_size.y = 36
	scroll.position = Vector2(12, 56)
	scroll.size = Vector2(size.x - 24, maxf(0, size.y - 63))
	scroll.visible = not collapsed
	queue_redraw()

func _apply_height() -> void:
	offset_top = -bank_height
	offset_bottom = 0

func set_height(value: float) -> void:
	if collapsed:
		return
	bank_height = clampf(value, 122, maxf(122, minf(340, get_viewport_rect().size.y * 0.5)))
	expanded_height = bank_height
	_apply_height()
	_layout()

func toggle_collapsed() -> void:
	collapsed = not collapsed
	bank_height = 50 if collapsed else expanded_height
	buttons["collapse"].text = "▴ BANK" if collapsed else "▾ BANK"
	_apply_height()
	_layout()

func configure(states: Array[PuzzlePieceState], image: Texture2D, seed_value: int) -> void:
	pieces = states
	source = image
	display_order.clear()
	for i in range(states.size()):
		display_order.append(i)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 1729
	for i in range(display_order.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, i)
		var temporary := display_order[i]
		display_order[i] = display_order[swap_index]
		display_order[swap_index] = temporary
	selected_id = -1
	filter_name = "ALL"
	refresh()

func set_filter(value: String) -> void:
	filter_name = value
	refresh()

func set_selected(piece_id: int) -> void:
	selected_id = piece_id
	for item in row.get_children():
		(item as PieceBankItem).set_active(item.piece_id == selected_id)

func refresh() -> void:
	if row == null or source == null:
		return
	for child in row.get_children():
		row.remove_child(child)
		child.queue_free()
	for piece_id in display_order:
		var piece := pieces[piece_id]
		if piece.is_on_table or not _passes_filter(piece):
			continue
		var item := PieceBankItem.new()
		row.add_child(item)
		item.setup(piece, source, piece.piece_size)
		item.set_active(piece.piece_id == selected_id)
		item.hovered.connect(func(id: int, pos: Vector2): piece_hovered.emit(id, pos))
		item.unhovered.connect(func(id: int): piece_unhovered.emit(id))
		item.pressed.connect(func(id: int, pos: Vector2): piece_pressed.emit(id, pos))
	update_counts()
	for name in ["ALL", "EDGES", "CORNERS", "TRAY 1"]:
		buttons["filter:" + name].modulate = Color("f3dba4") if filter_name == name else Color.WHITE

func update_counts() -> void:
	var remaining := 0
	var placed := 0
	var group_sizes := {}
	var largest_group := 0
	for piece in pieces:
		if not piece.is_on_table:
			remaining += 1
		else:
			placed += 1
			group_sizes[piece.cluster_id] = group_sizes.get(piece.cluster_id, 0) + 1
			largest_group = maxi(largest_group, group_sizes[piece.cluster_id])
	count_label.text = "  Remaining %d" % remaining
	placed_label.text = "  Placed %d / %d  •  Largest group %d" % [placed, pieces.size(), largest_group]

func _passes_filter(piece: PuzzlePieceState) -> bool:
	match filter_name:
		"EDGES": return piece.is_edge_piece
		"CORNERS": return piece.is_corner_piece
		"TRAY 1": return piece.tray_id == 1
		_: return true
