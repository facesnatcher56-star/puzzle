class_name PieceBank
extends Control

signal piece_hovered(piece_id: int, screen_position: Vector2)
signal piece_unhovered(piece_id: int)
signal piece_pressed(piece_id: int, screen_position: Vector2)
signal action_requested(action: String)
signal action_hovered(action: String)
signal action_unhovered(action: String)

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
var buttons := {} # "filter:ALL", "filter:EDGES", "filter:CORNERS", "filter:TRAY 1" and "collapse"
var tools_button: MenuButton
var tools_menu: PopupMenu

# The less-used actions live behind the "⋯" button. Menu item id -> the action it requests.
const TOOLS := [["reference", "Reference"], ["spread", "Spread Pieces"], ["assign_tray", "Move to Tray"], ["reset", "Restart"], ["new", "New Puzzle"]]
const FILTERS := [["ALL", "ALL"], ["EDGES", "EDGE"], ["CORNERS", "CORNER"], ["TRAY 1", "TRAY 1"]]

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
	for entry in FILTERS:
		_add_button(entry[1], "filter:" + entry[0])
	count_label = Label.new()
	count_label.add_theme_color_override("font_color", Color("dce7e6"))
	count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	count_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(count_label)
	_add_tools_menu()
	_add_button("▾", "collapse")
	scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	scroll.add_child(row)
	resized.connect(_layout)
	_layout()

func _add_tools_menu() -> void:
	tools_button = MenuButton.new()
	tools_button.text = "⋯"
	tools_button.focus_mode = Control.FOCUS_NONE
	tools_button.custom_minimum_size = Vector2(44, 34)
	tools_button.add_theme_font_size_override("font_size", 18)
	tools_menu = tools_button.get_popup()
	for i in range(TOOLS.size()):
		tools_menu.add_item(TOOLS[i][1], i)
	tools_menu.id_pressed.connect(func(id: int): action_requested.emit(TOOLS[id][0]))
	header.add_child(tools_button)

# Greys out a tool in the "⋯" menu (e.g. Reference in Random mode, which has no reference picture).
func set_tool_enabled(action: String, enabled: bool) -> void:
	for i in range(TOOLS.size()):
		if TOOLS[i][0] == action:
			tools_menu.set_item_disabled(i, not enabled)

func is_tool_enabled(action: String) -> bool:
	for i in range(TOOLS.size()):
		if TOOLS[i][0] == action:
			return not tools_menu.is_item_disabled(i)
	return false

func _add_button(label: String, action: String) -> void:
	var button := Button.new()
	button.text = label
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(44, 34)
	button.add_theme_font_size_override("font_size", 13)
	button.pressed.connect(func(): action_requested.emit(action))
	button.mouse_entered.connect(func(): action_hovered.emit(action))
	button.mouse_exited.connect(func(): action_unhovered.emit(action))
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
	buttons["collapse"].text = "▴" if collapsed else "▾"
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
	for entry in FILTERS:
		buttons["filter:" + entry[0]].modulate = Color("f3dba4") if filter_name == entry[0] else Color.WHITE

# A cheap update after pieces move between the bank and the table: drops the tiles of pieces that left. It only
# falls back to a full rebuild when a tile has to appear (a tray change), so placing a piece costs the same on a
# 1,000-piece puzzle as on a 24-piece one instead of rebuilding every remaining tile.
func sync() -> void:
	if row == null or source == null:
		return
	var shown := {}
	for item in row.get_children():
		shown[(item as PieceBankItem).piece_id] = item
	var gone := []
	for piece in pieces:
		var wanted := not piece.is_on_table and _passes_filter(piece)
		if wanted and not shown.has(piece.piece_id):
			refresh()
			return
		if not wanted and shown.has(piece.piece_id):
			gone.append(shown[piece.piece_id])
	for item in gone:
		row.remove_child(item)
		item.queue_free()
	update_counts()

func update_counts() -> void:
	var remaining := 0
	for piece in pieces:
		if not piece.is_on_table:
			remaining += 1
	count_label.text = "  %d remaining" % remaining

func _passes_filter(piece: PuzzlePieceState) -> bool:
	match filter_name:
		"EDGES": return piece.is_edge_piece
		"CORNERS": return piece.is_corner_piece
		"TRAY 1": return piece.tray_id == 1
		_: return true
