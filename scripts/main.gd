extends Node2D

const SOURCE_IMAGE: Texture2D = preload("res://assets/emberbound.png")
const PIECE_SCENE: PackedScene = preload("res://scenes/puzzle_piece.tscn")
const BOARD_SIZE := Vector2(1122, 1402)
const SIZES := [Vector2i(4, 6), Vector2i(6, 8), Vector2i(8, 12), Vector2i(10, 25)]
# Random Puzzle mode: each entry is picked at random and played with no reference image.
# Add more artwork here and it joins the pool automatically.
const RANDOM_IMAGES := {
	"motel": preload("res://assets/random/motel.webp"),
	"hotel": preload("res://assets/random/hotel.webp"),
	"subway": preload("res://assets/random/subway.webp"),
	"bayou": preload("res://assets/random/bayou.webp"),
}
# Grids for the 4:3 random artwork; chosen so cells stay close to square.
const RANDOM_SIZES := [Vector2i(6, 4), Vector2i(8, 6), Vector2i(12, 9), Vector2i(18, 14)]

@onready var camera: Camera2D = $Camera2D
@onready var piece_layer: Node2D = $Pieces
@onready var ui_layer: CanvasLayer = $UI

var manager := PuzzleManager.new()
var source: Texture2D = SOURCE_IMAGE
var image_id := "" # "" = the classic Emberbound puzzle, otherwise a RANDOM_IMAGES key
var board_size := BOARD_SIZE
var sizes: Array = SIZES
var columns := 8
var rows := 6
var cell := Vector2(132, 117.333)
var seed_value := 52813
var table_views := {}
var selected_table_id := -1
var dragging_table_id := -1
var drag_offset := Vector2.ZERO
var mouse_panning := false
var resizing_bank := false
var bank_press_id := -1
var bank_press_screen := Vector2.ZERO
var bank_dragging := false
var selected_bank_id := -1
var fingers := {}
var touch_table_id := -1
var touch_last := Vector2.ZERO
var touch_panning := false
var pinch_distance := 0.0
var bank_scrolling := false
var hover_table_id := -1
var rotation_enabled := true

var network: NetworkSession
var save_dirty := false
var last_change_msec := 0
var last_saved_msec := 0
var autosave_timer: Timer

var ui_root: Control
var bank: PieceBank
var preview_panel: Panel
var preview_view: PuzzlePieceView
var drag_ghost: PuzzlePieceView
var reference_overlay: Control
var reference_panel: Panel
var reference_title_bar: Control
var reference_close_button: Button
var reference_image_area: Control
var reference_image_view: TextureRect
var reference_grip: ColorRect
var reference_positioned := false
var reference_dragging := false
var reference_resizing := false
var reference_resize_start_size := Vector2.ZERO
var reference_resize_start_mouse := Vector2.ZERO
var reference_panning := false
var reference_zoom := 1.0
var reference_touch_index := -1
var complete_banner: PanelContainer
var complete_label: Label
var rotation_button: Button
var rotation_toggle: CheckButton
var size_picker: OptionButton
var title_label: Label
var top_hint: Label
var network_status_label: Label
var leave_button: Button

var lobby_overlay: Control
var lobby_stack: VBoxContainer
var lobby_sub_open := false
var in_game_menu := false # the lobby overlay doubles as the Esc/pause menu while a puzzle is open
var settings_fullscreen_picker: OptionButton
var settings_resolution_picker: OptionButton
var host_port_field: LineEdit
var host_game_picker: OptionButton
var host_entries: Array = [] # parallel to host_game_picker items: {random} for new games, {slot} for saved ones
var host_save_label: Label
var save_slot := "" # file slot the running puzzle autosaves into; "" while a client (clients never save)
var pause_save_button: Button
var host_status_label: Label
var join_address_field: LineEdit
var join_status_label: Label
var join_games_list: VBoxContainer
var join_games_status: Label

var lan: LanDiscovery

func _ready() -> void:
	DisplayServer.window_set_title("Emberbound Jigsaw  -  build " + BuildInfo.ID)
	SaveManager.migrate_legacy()
	DisplaySettings.apply_saved()
	_apply_mobile_scale()
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	piece_layer.z_index = 1 # resting pieces' shadows sit at z 0, above the board but under every piece
	if source == null:
		push_error("Bundled puzzle image failed to load: res://assets/emberbound.png")
		return
	manager.piece_changed.connect(_on_piece_changed)
	manager.bank_changed.connect(func(): bank.refresh())
	manager.pieces_joined.connect(_on_pieces_joined)
	manager.puzzle_completed.connect(_on_completed)
	manager.piece_changed.connect(_mark_dirty.unbind(1))
	manager.pieces_joined.connect(_mark_dirty.unbind(2))
	manager.puzzle_completed.connect(_mark_dirty)
	manager.bank_changed.connect(_mark_dirty)
	network = NetworkSession.new()
	add_child(network)
	network.configure(manager, Callable(self, "_puzzle_config"))
	network.peer_joined.connect(_on_peer_joined)
	network.peer_left.connect(_on_peer_left)
	network.connection_established.connect(_on_connection_established)
	network.connection_failed.connect(_on_connection_failed)
	network.server_disconnected.connect(_on_server_disconnected)
	network.full_state_received.connect(_on_full_state_received)
	lan = LanDiscovery.new()
	add_child(lan)
	lan.games_updated.connect(_on_lan_games_updated)
	_build_ui()
	_build_lobby_ui()
	autosave_timer = Timer.new()
	autosave_timer.wait_time = 2.0
	autosave_timer.autostart = true
	autosave_timer.timeout.connect(_on_autosave_tick)
	add_child(autosave_timer)
	get_viewport().size_changed.connect(_on_viewport_resized)
	_show_lobby()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if lobby_overlay != null and lobby_overlay.visible and not lobby_sub_open and not in_game_menu:
			get_tree().quit()
		else:
			_on_escape()
	elif what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Android may kill the app without a clean quit after backgrounding, and focus-out
		# fires more reliably across OEM skins than the pause notification alone.
		if network != null and (network.is_solo() or network.is_host()) and save_dirty:
			_write_save()

# Phones report a large pixel canvas, which shrinks the 1280x800 layout to unreadable
# sizes. Scale the UI so the base layout maps to roughly 1.2 logical units per dp.
func _apply_mobile_scale() -> void:
	if not OS.has_feature("mobile"):
		return
	var screen := Vector2(DisplayServer.window_get_size())
	var dpi := maxf(DisplayServer.screen_get_dpi(), 120)
	var stretch := minf(screen.x / 1280.0, screen.y / 800.0)
	var target_height := clampf(screen.y * 160.0 / dpi * 1.2, 500, 800)
	get_window().content_scale_factor = maxf(1.0, screen.y / (stretch * target_height))

func _draw() -> void:
	draw_rect(Rect2(Vector2(-5000, -5000), Vector2(10000, 10000)), Color("293a3e"), true)
	for x in range(-4800, 5000, 160):
		draw_line(Vector2(x, -5000), Vector2(x, 5000), Color(1, 1, 1, 0.014), 1)
	for y in range(-4800, 5000, 160):
		draw_line(Vector2(-5000, y), Vector2(5000, y), Color(1, 1, 1, 0.014), 1)
	var board := Rect2(-board_size * 0.5, board_size)
	draw_rect(board.grow(17), Color(0.05, 0.08, 0.09, 0.45), true)
	draw_rect(board.grow(7), Color("ab9e83"), true)
	draw_rect(board, Color("637374"), true)
	draw_rect(board, Color("d5c8aa"), false, 3)

func _start_puzzle(new_seed: bool) -> void:
	if new_seed:
		seed_value += 1
		if not network.is_client():
			save_slot = SaveManager.new_slot_id()
		if image_id != "":
			_apply_image(_pick_random_image())
	for child in piece_layer.get_children():
		child.queue_free()
	table_views.clear()
	selected_table_id = -1
	dragging_table_id = -1
	selected_bank_id = -1
	bank_press_id = -1
	_hide_preview()
	_clear_ghost()
	var grid: Vector2i = sizes[size_picker.selected]
	columns = grid.x
	rows = grid.y
	cell = Vector2(board_size.x / columns, board_size.y / rows)
	var generated := PuzzleGenerator.generate(source, columns, rows, seed_value, board_size, rotation_enabled)
	if generated.size() != columns * rows:
		push_error("Puzzle generation failed: expected %d pieces, got %d" % [columns * rows, generated.size()])
		return
	manager.configure(generated, cell, columns, rows)
	if bank.collapsed:
		bank.toggle_collapsed()
	bank.configure(generated, source, seed_value)
	complete_banner.visible = false
	_fit_camera()
	queue_redraw()
	if network.is_host():
		network.broadcast_full_state()
	_mark_dirty()

func _fit_camera() -> void:
	var viewport_size := get_viewport_rect().size
	var available := Vector2(viewport_size.x - 64, viewport_size.y - bank.bank_height - 85)
	var fit := minf(available.x / board_size.x, available.y / board_size.y)
	camera.zoom = Vector2.ONE * fit
	camera.position = Vector2(0, (bank.bank_height - 53) * 0.5 / fit)

func _build_ui() -> void:
	ui_root = Control.new()
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(ui_root)
	var top_bg := ColorRect.new()
	top_bg.color = Color("17252dcc")
	top_bg.anchor_right = 1
	top_bg.offset_bottom = 53
	top_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	ui_root.add_child(top_bg)
	var top := HBoxContainer.new()
	top.position = Vector2(15, 9)
	top.anchor_right = 1
	top.offset_right = -20
	top.offset_bottom = 36
	top.add_theme_constant_override("separation", 9)
	top_bg.add_child(top)
	title_label = Label.new()
	title_label.text = "EMBERBOUND JIGSAW"
	title_label.add_theme_font_size_override("font_size", 19)
	title_label.add_theme_color_override("font_color", Color("f4e5c3"))
	title_label.custom_minimum_size.x = 180
	top.add_child(title_label)
	var size_label := Label.new()
	size_label.text = "PIECES"
	size_label.add_theme_font_size_override("font_size", 12)
	top.add_child(size_label)
	size_picker = OptionButton.new()
	size_picker.focus_mode = Control.FOCUS_NONE
	_fill_size_picker()
	size_picker.item_selected.connect(func(_index: int): _start_puzzle(false))
	top.add_child(size_picker)
	rotation_toggle = CheckButton.new()
	rotation_toggle.text = "Rotation"
	rotation_toggle.button_pressed = rotation_enabled
	rotation_toggle.tooltip_text = "Random quarter-turns. Changing this restarts the puzzle."
	rotation_toggle.focus_mode = Control.FOCUS_NONE
	rotation_toggle.toggled.connect(_set_rotation_enabled)
	top.add_child(rotation_toggle)
	rotation_button = Button.new()
	rotation_button.text = "↻ Rotate (R)"
	rotation_button.visible = rotation_enabled
	rotation_button.pressed.connect(_rotate_selected)
	top.add_child(rotation_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	top_hint = Label.new()
	top_hint.text = "Match touching edges anywhere  •  Drag joined groups  •  Wheel zoom"
	if DisplayServer.is_touchscreen_available():
		top_hint.text = "Pinch to zoom  •  Double-tap to rotate  •  Swipe bank to scroll"
	top_hint.add_theme_color_override("font_color", Color("b8c8c8"))
	top_hint.add_theme_font_size_override("font_size", 12)
	top_hint.visible = get_viewport_rect().size.x >= 1050
	top.add_child(top_hint)
	network_status_label = Label.new()
	network_status_label.text = "SOLO"
	network_status_label.add_theme_font_size_override("font_size", 12)
	network_status_label.add_theme_color_override("font_color", Color("9fd6c8"))
	top.add_child(network_status_label)
	leave_button = Button.new()
	leave_button.text = "Leave"
	leave_button.visible = false
	leave_button.focus_mode = Control.FOCUS_NONE
	leave_button.pressed.connect(_on_leave_pressed)
	top.add_child(leave_button)
	bank = PieceBank.new()
	ui_root.add_child(bank)
	bank.piece_hovered.connect(_on_bank_hovered)
	bank.piece_unhovered.connect(_on_bank_unhovered)
	bank.piece_pressed.connect(_on_bank_pressed)
	bank.action_requested.connect(_on_bank_action)
	preview_panel = Panel.new()
	preview_panel.visible = false
	preview_panel.size = Vector2(278, 258)
	preview_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(preview_panel)
	complete_banner = PanelContainer.new()
	complete_banner.visible = false
	complete_banner.anchor_left = 0.5
	complete_banner.anchor_right = 0.5
	complete_banner.offset_left = -285
	complete_banner.offset_right = 285
	complete_banner.offset_top = 65
	complete_banner.offset_bottom = 121
	ui_root.add_child(complete_banner)
	var complete_row := HBoxContainer.new()
	complete_row.add_theme_constant_override("separation", 12)
	complete_banner.add_child(complete_row)
	complete_label = Label.new()
	complete_label.add_theme_color_override("font_color", Color("f6e0ac"))
	complete_row.add_child(complete_label)
	var restart := Button.new()
	restart.text = "Restart"
	restart.pressed.connect(func(): _start_puzzle(false))
	complete_row.add_child(restart)
	var next := Button.new()
	next.text = "New puzzle"
	next.pressed.connect(func(): _start_puzzle(true))
	complete_row.add_child(next)
	_build_reference()

# The reference window is a non-modal floating panel: laid out manually (not via
# containers) so drag/resize/zoom math has a single source of truth for its geometry,
# and so it keeps whatever position/size/zoom the player left it at across toggles.
func _build_reference() -> void:
	reference_overlay = Control.new()
	reference_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	reference_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reference_overlay.visible = false
	ui_root.add_child(reference_overlay)
	reference_panel = Panel.new()
	reference_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	reference_overlay.add_child(reference_panel)

	reference_title_bar = Control.new()
	reference_title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	reference_panel.add_child(reference_title_bar)
	var title := Label.new()
	title.text = "REFERENCE IMAGE  (drag to move)"
	title.add_theme_font_size_override("font_size", 15)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.offset_left = 10
	reference_title_bar.add_child(title)

	reference_close_button = Button.new()
	reference_close_button.text = "×"
	reference_close_button.tooltip_text = "Close"
	reference_close_button.focus_mode = Control.FOCUS_NONE
	reference_close_button.pressed.connect(func(): reference_overlay.visible = false)
	reference_panel.add_child(reference_close_button)

	reference_image_area = Control.new()
	reference_image_area.clip_contents = true
	reference_image_area.mouse_filter = Control.MOUSE_FILTER_STOP
	reference_panel.add_child(reference_image_area)
	reference_image_view = TextureRect.new()
	reference_image_view.texture = source
	reference_image_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reference_image_area.add_child(reference_image_view)

	reference_grip = ColorRect.new()
	reference_grip.color = Color(1, 1, 1, 0.18)
	reference_grip.mouse_filter = Control.MOUSE_FILTER_STOP
	reference_grip.tooltip_text = "Drag to resize"
	reference_panel.add_child(reference_grip)

	reference_panel.size = Vector2(560, 460)
	_layout_reference()

func _build_lobby_ui() -> void:
	lobby_overlay = Control.new()
	lobby_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lobby_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	lobby_overlay.visible = false
	ui_root.add_child(lobby_overlay)
	var backdrop := TextureRect.new()
	backdrop.texture = SOURCE_IMAGE
	backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.modulate = Color(0.45, 0.5, 0.55)
	lobby_overlay.add_child(backdrop)
	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.05, 0.08, 0.82)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lobby_overlay.add_child(shade)
	var lobby_panel := PanelContainer.new()
	lobby_panel.set_anchors_preset(Control.PRESET_CENTER)
	lobby_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	lobby_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	lobby_panel.custom_minimum_size = Vector2(460, 0)
	lobby_panel.theme = _lobby_theme()
	lobby_overlay.add_child(lobby_panel)
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 34)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	lobby_panel.add_child(margin)
	lobby_stack = VBoxContainer.new()
	lobby_stack.add_theme_constant_override("separation", 12)
	margin.add_child(lobby_stack)
	_build_lobby_root()

func _lobby_box(fill: Color, border: Color, border_width: int = 1, radius: int = 10) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	box.content_margin_left = 16
	box.content_margin_right = 16
	box.content_margin_top = 11
	box.content_margin_bottom = 11
	return box

func _lobby_theme() -> Theme:
	var theme := Theme.new()
	var gold := Color("e0b96a")
	theme.set_stylebox("panel", "PanelContainer", _lobby_box(Color("121c24f2"), gold.darkened(0.25), 2, 16))
	theme.set_stylebox("normal", "Button", _lobby_box(Color("1f3039"), Color("3d5661")))
	theme.set_stylebox("hover", "Button", _lobby_box(Color("2b4452"), gold))
	theme.set_stylebox("pressed", "Button", _lobby_box(Color("16242c"), gold.lightened(0.2)))
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	theme.set_color("font_color", "Button", Color("eef0e6"))
	theme.set_color("font_hover_color", "Button", Color("fff2cf"))
	theme.set_font_size("font_size", "Button", 17)
	theme.set_stylebox("normal", "LineEdit", _lobby_box(Color("0c141b"), Color("3d5661"), 1, 8))
	theme.set_stylebox("focus", "LineEdit", _lobby_box(Color("0c141b"), gold, 1, 8))
	theme.set_stylebox("normal", "OptionButton", _lobby_box(Color("1f3039"), Color("3d5661"), 1, 8))
	theme.set_stylebox("hover", "OptionButton", _lobby_box(Color("2b4452"), gold, 1, 8))
	theme.set_stylebox("pressed", "OptionButton", _lobby_box(Color("16242c"), gold, 1, 8))
	theme.set_color("font_color", "Label", Color("c9d6d6"))
	return theme

func _lobby_heading(text: String, subtitle: String = "") -> void:
	var title := Label.new()
	title.text = text
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color("f4e5c3"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_stack.add_child(title)
	if subtitle != "":
		var sub := Label.new()
		sub.text = subtitle
		sub.add_theme_font_size_override("font_size", 14)
		sub.add_theme_color_override("font_color", Color("8fa6a8"))
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lobby_stack.add_child(sub)
	var rule := ColorRect.new()
	rule.color = Color("e0b96a66")
	rule.custom_minimum_size.y = 2
	lobby_stack.add_child(rule)
	var gap := Control.new()
	gap.custom_minimum_size.y = 4
	lobby_stack.add_child(gap)

func _lobby_button(text: String, detail: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text if detail == "" else "%s\n%s" % [text, detail]
	button.custom_minimum_size.y = 52 if detail == "" else 66
	button.pressed.connect(callback)
	lobby_stack.add_child(button)
	return button

func _lobby_caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color("8fa6a8"))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	lobby_stack.add_child(label)
	return label

func _show_lobby() -> void:
	in_game_menu = false
	_build_lobby_root()
	lobby_overlay.visible = true

func _show_pause_menu() -> void:
	# Drop anything mid-drag so a piece isn't left glued to the cursor behind the menu.
	if dragging_table_id >= 0:
		network.request_release(dragging_table_id)
		_set_cluster_z(dragging_table_id, 0)
		dragging_table_id = -1
	touch_table_id = -1
	bank_press_id = -1
	_clear_ghost()
	_hide_preview()
	in_game_menu = true
	_build_lobby_root()
	lobby_overlay.visible = true

func _on_escape() -> void:
	if reference_overlay.visible:
		reference_overlay.visible = false
	elif lobby_overlay.visible:
		if lobby_sub_open:
			_build_lobby_root()
		elif in_game_menu:
			_hide_lobby()
	else:
		_show_pause_menu()

func _hide_lobby() -> void:
	lobby_overlay.visible = false

func _clear_lobby_stack() -> void:
	for child in lobby_stack.get_children():
		lobby_stack.remove_child(child)
		child.queue_free()

func _build_pause_root() -> void:
	_lobby_heading("PAUSED", "Progress also saves automatically")
	_lobby_button("Resume", "", _hide_lobby)
	pause_save_button = null
	if not network.is_client():
		pause_save_button = _lobby_button("Save Game", "", _on_save_pressed)
	_lobby_button("Settings", "", _build_settings)
	_lobby_button("Main Menu", "", _on_main_menu_pressed)
	if not OS.has_feature("mobile"):
		_lobby_button("Quit Game", "", _on_quit_pressed)

func _on_save_pressed() -> void:
	_write_save()
	if pause_save_button != null:
		pause_save_button.text = "Saved ✓"

func _on_main_menu_pressed() -> void:
	if (network.is_solo() or network.is_host()) and save_dirty:
		_write_save()
	_on_leave_pressed()

func _on_quit_pressed() -> void:
	if (network.is_solo() or network.is_host()) and save_dirty:
		_write_save()
	get_tree().quit()

func _build_settings() -> void:
	_clear_lobby_stack()
	lobby_sub_open = true
	_lobby_heading("SETTINGS", "Display")
	if not DisplaySettings.is_supported():
		_lobby_caption("Window and resolution options are available on the desktop version.")
	else:
		var saved := DisplaySettings.load_settings()
		settings_fullscreen_picker = OptionButton.new()
		settings_fullscreen_picker.add_item("Windowed")
		settings_fullscreen_picker.add_item("Fullscreen")
		settings_fullscreen_picker.select(1 if saved.fullscreen else 0)
		settings_resolution_picker = OptionButton.new()
		var saved_size := Vector2i(saved.width, saved.height)
		var resolutions := DisplaySettings.available_resolutions()
		var best := 0
		for i in range(resolutions.size()):
			settings_resolution_picker.add_item("%d x %d" % [resolutions[i].x, resolutions[i].y])
			if absi(resolutions[i].x * resolutions[i].y - saved_size.x * saved_size.y) < absi(resolutions[best].x * resolutions[best].y - saved_size.x * saved_size.y):
				best = i
		settings_resolution_picker.select(best)
		settings_resolution_picker.disabled = saved.fullscreen
		settings_fullscreen_picker.item_selected.connect(func(_i: int): _apply_display_choice())
		settings_resolution_picker.item_selected.connect(func(_i: int): _apply_display_choice())
		_settings_row("Window", settings_fullscreen_picker)
		_settings_row("Resolution", settings_resolution_picker)
		_lobby_caption("Resolution applies to windowed mode. Fullscreen uses your monitor's native resolution.")
	var back := _lobby_button("Back", "", _build_lobby_root)
	back.custom_minimum_size.y = 46

func _settings_row(label_text: String, picker: OptionButton) -> void:
	var row := HBoxContainer.new()
	lobby_stack.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 120
	row.add_child(label)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(picker)

func _apply_display_choice() -> void:
	var fullscreen := settings_fullscreen_picker.selected == 1
	var resolutions := DisplaySettings.available_resolutions()
	var size: Vector2i = resolutions[clampi(settings_resolution_picker.selected, 0, resolutions.size() - 1)]
	settings_resolution_picker.disabled = fullscreen
	DisplaySettings.save_settings(fullscreen, size)
	DisplaySettings.apply(fullscreen, size)

func _build_lobby_root() -> void:
	_clear_lobby_stack()
	lobby_sub_open = false
	if in_game_menu:
		_build_pause_root()
		return
	_lobby_heading("JIGSAW", "Piece it together. Alone or with friends.")
	var saves := SaveManager.list_saves()
	if not saves.is_empty():
		var latest: Dictionary = saves[0].data
		var slot: String = saves[0].slot
		_lobby_button("Continue", "%s  •  %s" % [_save_title(latest), _save_detail(latest)], func(): _on_load_slot_pressed(slot))
	_lobby_button("New Game", "Start a fresh puzzle", _build_lobby_new)
	_lobby_button("Load Game", "%d saved puzzle%s" % [saves.size(), "" if saves.size() == 1 else "s"] if not saves.is_empty() else "No saved puzzles yet", _build_lobby_load)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	lobby_stack.add_child(row)
	for entry in [["Host Game", _build_lobby_host], ["Join Game", _build_lobby_join]]:
		var button := Button.new()
		button.text = entry[0]
		button.custom_minimum_size.y = 52
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(entry[1])
		row.add_child(button)
	var extras := HBoxContainer.new()
	extras.add_theme_constant_override("separation", 12)
	lobby_stack.add_child(extras)
	var extra_entries := [["Settings", _build_settings]]
	if not OS.has_feature("mobile"):
		extra_entries.append(["Quit", _on_quit_pressed])
	for entry in extra_entries:
		var button := Button.new()
		button.text = entry[0]
		button.custom_minimum_size.y = 46
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(entry[1])
		extras.add_child(button)
	var build_label := _lobby_caption("Build " + BuildInfo.ID)
	build_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

func _build_lobby_new() -> void:
	_clear_lobby_stack()
	lobby_sub_open = true
	_lobby_heading("NEW GAME", "Choose a puzzle")
	_lobby_button("Emberbound", "Classic artwork  •  with reference image", _on_solo_pressed)
	_lobby_button("Random Puzzle", "A surprise picture  •  no reference", _on_random_pressed)
	var back := _lobby_button("Back", "", _build_lobby_root)
	back.custom_minimum_size.y = 46

func _build_lobby_load() -> void:
	_clear_lobby_stack()
	lobby_sub_open = true
	_lobby_heading("LOAD GAME", "Pick up where you left off")
	var saves := SaveManager.list_saves()
	if saves.is_empty():
		_lobby_caption("No saved puzzles yet. Start a new game and it will be saved here automatically.")
	else:
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.custom_minimum_size.y = minf(saves.size() * 74.0, 330.0)
		lobby_stack.add_child(scroll)
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 8)
		scroll.add_child(list)
		for entry in saves:
			var slot: String = entry.slot
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			list.add_child(row)
			var load_button := Button.new()
			load_button.text = "%s\n%s" % [_save_title(entry.data), _save_detail(entry.data)]
			load_button.custom_minimum_size.y = 66
			load_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			load_button.pressed.connect(_on_load_slot_pressed.bind(slot))
			row.add_child(load_button)
			var delete_button := Button.new()
			delete_button.text = "Delete"
			delete_button.custom_minimum_size = Vector2(76, 66)
			delete_button.pressed.connect(_on_delete_slot_pressed.bind(slot, delete_button))
			row.add_child(delete_button)
	var back := _lobby_button("Back", "", _build_lobby_root)
	back.custom_minimum_size.y = 46

# Two-step delete: the first press arms the button, the second removes the save.
func _on_delete_slot_pressed(slot: String, button: Button) -> void:
	if button.text != "Sure?":
		button.text = "Sure?"
		return
	SaveManager.delete_slot(slot)
	_build_lobby_load()

func _on_load_slot_pressed(slot: String) -> void:
	if _load_session(slot):
		_hide_lobby()

func _build_lobby_host() -> void:
	_clear_lobby_stack()
	lobby_sub_open = true
	_lobby_heading("HOST GAME", "Others on your Wi-Fi will see it automatically")
	var port_row := HBoxContainer.new()
	lobby_stack.add_child(port_row)
	var port_label := Label.new()
	port_label.text = "Port"
	port_row.add_child(port_label)
	host_port_field = LineEdit.new()
	host_port_field.text = str(NetworkSession.DEFAULT_PORT)
	host_port_field.custom_minimum_size.x = 100
	port_row.add_child(host_port_field)
	var game_row := VBoxContainer.new()
	lobby_stack.add_child(game_row)
	var game_label := Label.new()
	game_label.text = "Game"
	game_row.add_child(game_label)
	host_game_picker = OptionButton.new()
	host_game_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_game_picker.clip_text = true
	game_row.add_child(host_game_picker)
	host_save_label = _lobby_caption("")
	host_entries = [{"random": false}, {"random": true}]
	host_game_picker.add_item("New: Emberbound")
	host_game_picker.add_item("New: Random Puzzle")
	for entry in SaveManager.list_saves():
		host_entries.append({"slot": entry.slot, "data": entry.data})
		host_game_picker.add_item("Saved: %s  •  %s" % [_save_title(entry.data), _save_detail(entry.data).get_slice("  •  ", 0)])
	host_game_picker.item_selected.connect(_on_host_game_selected)
	# Default to the most recent saved game when there is one.
	host_game_picker.select(2 if host_entries.size() > 2 else 0)
	_on_host_game_selected(host_game_picker.selected)
	var start_button := Button.new()
	start_button.text = "Start Hosting"
	start_button.pressed.connect(_on_start_hosting_pressed)
	lobby_stack.add_child(start_button)
	host_status_label = Label.new()
	host_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	host_status_label.text = "Players on this Wi-Fi see this game automatically. For players elsewhere, forward this port (UDP) on your router and share your DDNS address."
	lobby_stack.add_child(host_status_label)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_build_lobby_root)
	lobby_stack.add_child(back)

func _build_lobby_join() -> void:
	_clear_lobby_stack()
	lobby_sub_open = true
	_lobby_heading("JOIN GAME", "Games found on this network")
	join_games_status = Label.new()
	join_games_status.text = "Searching..."
	join_games_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	lobby_stack.add_child(join_games_status)
	join_games_list = VBoxContainer.new()
	lobby_stack.add_child(join_games_list)
	var divider := Label.new()
	divider.text = "— or enter an address —"
	divider.add_theme_color_override("font_color", Color("8fa6a8"))
	divider.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_stack.add_child(divider)
	join_address_field = LineEdit.new()
	join_address_field.placeholder_text = "yourname.duckdns.org:%d" % NetworkSession.DEFAULT_PORT
	lobby_stack.add_child(join_address_field)
	var connect_button := Button.new()
	connect_button.text = "Connect"
	connect_button.pressed.connect(_on_connect_pressed)
	lobby_stack.add_child(connect_button)
	join_status_label = Label.new()
	join_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	lobby_stack.add_child(join_status_label)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_on_join_back_pressed)
	lobby_stack.add_child(back)
	var discovery_error := lan.start_listening()
	_on_lan_games_updated([])
	if discovery_error != OK:
		join_games_status.text = "Could not search this network (error %d). Try entering the host address below." % discovery_error

func _on_solo_pressed() -> void:
	_hide_lobby()
	_new_session(false)

func _on_random_pressed() -> void:
	_hide_lobby()
	_new_session(true)

func _on_host_game_selected(index: int) -> void:
	var entry: Dictionary = host_entries[index]
	if entry.has("slot"):
		host_save_label.text = "Continues exactly as you left it.  " + _save_detail(entry.data)
	else:
		host_save_label.text = "Starts a brand new puzzle."

func _on_start_hosting_pressed() -> void:
	var port := int(host_port_field.text)
	if port <= 0 or port > 65535:
		host_status_label.text = "Enter a valid port number (1-65535)."
		return
	var err := network.start_host(port)
	if err != OK:
		host_status_label.text = "Could not start hosting (error %d). Is the port already in use?" % err
		return
	lan.start_announcing(port, Callable(self, "_lan_label"))
	_hide_lobby()
	var entry: Dictionary = host_entries[host_game_picker.selected]
	if not entry.has("slot") or not _load_session(entry.slot):
		_new_session(bool(entry.get("random", false)))
	_update_network_status()

func _lan_label() -> String:
	var peer_count := 1 + multiplayer.get_peers().size()
	return "%s (%d online)" % ["Random Puzzle" if image_id != "" else "Emberbound Jigsaw", peer_count]

func _on_connect_pressed() -> void:
	lan.stop()
	var text := join_address_field.text.strip_edges()
	var address := text
	var port := NetworkSession.DEFAULT_PORT
	var split := text.rsplit(":", true, 1)
	if split.size() == 2:
		address = split[0]
		port = int(split[1])
	if address.is_empty() or port <= 0 or port > 65535:
		join_status_label.text = "Enter an address as host:port."
		return
	var err := network.start_client(address, port)
	if err != OK:
		join_status_label.text = "Could not start connection (error %d)." % err
		return
	join_status_label.text = "Connecting..."

func _on_join_back_pressed() -> void:
	lan.stop()
	_build_lobby_root()

func _on_lan_games_updated(games: Array) -> void:
	if join_games_list == null:
		return
	for child in join_games_list.get_children():
		join_games_list.remove_child(child)
		child.queue_free()
	join_games_status.visible = games.is_empty()
	games.sort_custom(func(a, b): return a.label < b.label)
	for game in games:
		var entry := Button.new()
		entry.text = "%s  (%s)" % [game.label, game.address]
		entry.pressed.connect(_on_lan_game_pressed.bind(game.address, game.port))
		join_games_list.add_child(entry)

func _on_lan_game_pressed(address: String, port: int) -> void:
	lan.stop()
	var err := network.start_client(address, port)
	if err != OK:
		join_status_label.text = "Could not start connection (error %d)." % err
		return
	join_status_label.text = "Connecting..."

func _new_session(random_mode: bool) -> void:
	save_slot = SaveManager.new_slot_id()
	if random_mode:
		seed_value = randi_range(1, 1000000)
		_apply_image(_pick_random_image())
	else:
		_apply_image("")
	_start_puzzle(false)
	_write_save() # list it under Load Game straight away

# Loads a saved puzzle into this session; false if the file is missing, damaged, or names artwork this build lacks.
func _load_session(slot: String) -> bool:
	var saved := SaveManager.load_state(SaveManager.slot_path(slot))
	var saved_image := str(saved.get("image_id", ""))
	if saved.is_empty() or (saved_image != "" and not RANDOM_IMAGES.has(saved_image)):
		return false
	save_slot = slot
	_restore_puzzle(saved)
	return true

func _save_title(saved: Dictionary) -> String:
	var saved_image := str(saved.get("image_id", ""))
	return "Emberbound" if saved_image == "" else "Random  •  " + saved_image.capitalize()

func _save_detail(saved: Dictionary) -> String:
	var placed := 0
	for snap in saved.pieces:
		if snap.on_table:
			placed += 1
	var seconds := int(saved.get("elapsed_ms", 0)) / 1000
	var detail := "%d of %d placed  •  %d:%02d played" % [placed, saved.pieces.size(), seconds / 60, seconds % 60]
	var stamp := int(saved.get("saved_at", 0))
	if stamp > 0:
		var local := Time.get_datetime_dict_from_unix_time(stamp + int(Time.get_time_zone_from_system().bias) * 60)
		var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
		var hour12: int = (local.hour + 11) % 12 + 1
		detail += "  •  %s %d, %d:%02d %s" % [months[local.month - 1], local.day, hour12, local.minute, "AM" if local.hour < 12 else "PM"]
	return detail

# Never repeats the image currently on the table, so "New puzzle" is always a visible change.
func _pick_random_image() -> String:
	var ids := RANDOM_IMAGES.keys()
	var options := ids.filter(func(id): return id != image_id)
	if options.is_empty():
		options = ids
	return options[randi() % options.size()]

func _fill_size_picker() -> void:
	size_picker.clear()
	for grid in sizes:
		size_picker.add_item(str(grid.x * grid.y))
	size_picker.select(sizes.size() - 1)

# Switches artwork/board/grid options; Random mode has no reference image, so it is hidden there.
func _apply_image(id: String) -> void:
	image_id = id
	var random_mode := id != ""
	source = RANDOM_IMAGES[id] if random_mode else SOURCE_IMAGE
	board_size = source.get_size()
	sizes = RANDOM_SIZES if random_mode else SIZES
	_fill_size_picker()
	title_label.text = "RANDOM PUZZLE" if random_mode else "EMBERBOUND JIGSAW"
	reference_image_view.texture = source
	reference_overlay.visible = false
	bank.buttons["reference"].visible = not random_mode
	reference_zoom = 1.0
	_update_reference_image_layout()

func _on_leave_pressed() -> void:
	if network.is_client():
		save_dirty = false # the host's puzzle must never be written to this player's own save
	lan.stop()
	network.stop()
	_update_network_status()
	_show_lobby()

func _on_peer_joined(_id: int) -> void:
	_update_network_status()

func _on_peer_left(_id: int) -> void:
	_update_network_status()

func _on_connection_established() -> void:
	_update_network_status()

func _on_connection_failed(reason: String) -> void:
	if join_status_label != null:
		join_status_label.text = "%s — check the address/port and that the host's router is forwarding UDP." % reason

func _on_server_disconnected() -> void:
	save_dirty = false
	_apply_role_restrictions()
	_show_lobby()
	if join_status_label != null:
		join_status_label.text = "Disconnected from host."

func _on_full_state_received(config: Dictionary, snapshots: Array) -> void:
	save_slot = "" # the host owns this puzzle's save, never this client
	var saved := config.duplicate()
	saved["pieces"] = snapshots
	_hide_lobby()
	_restore_puzzle(saved)
	_update_network_status()

func _update_network_status() -> void:
	if network.is_host():
		network_status_label.text = "HOSTING (%d)" % multiplayer.get_peers().size()
		leave_button.visible = true
	elif network.is_client():
		network_status_label.text = "CONNECTED"
		leave_button.visible = true
	else:
		network_status_label.text = "SOLO"
		leave_button.visible = false
	_apply_role_restrictions()

func _apply_role_restrictions() -> void:
	var editable := not network.is_client()
	size_picker.disabled = not editable
	rotation_toggle.disabled = not editable

func _puzzle_config() -> Dictionary:
	return {
		"seed_value": seed_value, "columns": columns, "rows": rows,
		"rotation_enabled": rotation_enabled, "image_id": image_id,
		"elapsed_ms": Time.get_ticks_msec() - manager.started_at
	}

func _restore_puzzle(saved: Dictionary) -> void:
	for child in piece_layer.get_children():
		child.queue_free()
	table_views.clear()
	selected_table_id = -1
	dragging_table_id = -1
	selected_bank_id = -1
	bank_press_id = -1
	_hide_preview()
	_clear_ghost()
	var saved_image := str(saved.get("image_id", ""))
	if saved_image != "" and not RANDOM_IMAGES.has(saved_image):
		push_error("Puzzle restore failed: unknown image '%s'" % saved_image)
		return
	_apply_image(saved_image)
	seed_value = int(saved.seed_value)
	columns = int(saved.columns)
	rows = int(saved.rows)
	rotation_enabled = bool(saved.rotation_enabled)
	rotation_toggle.button_pressed = rotation_enabled
	rotation_button.visible = rotation_enabled
	cell = Vector2(board_size.x / columns, board_size.y / rows)
	var size_index := sizes.find(Vector2i(columns, rows))
	if size_index >= 0:
		size_picker.select(size_index)
	var generated := PuzzleGenerator.generate(source, columns, rows, seed_value, board_size, rotation_enabled)
	if generated.size() != columns * rows:
		push_error("Puzzle restore failed: expected %d pieces, got %d" % [columns * rows, generated.size()])
		return
	manager.configure(generated, cell, columns, rows)
	manager.apply_snapshots(saved.pieces) # emits piece_changed for every piece; _on_piece_changed creates each on-table view reactively
	manager.started_at = Time.get_ticks_msec() - int(saved.get("elapsed_ms", 0))
	if bank.collapsed:
		bank.toggle_collapsed()
	bank.configure(generated, source, seed_value)
	complete_banner.visible = manager.completion_announced
	if manager.completion_announced:
		var seconds := manager.elapsed_seconds()
		complete_label.text = "Puzzle Complete  •  %02d:%02d" % [seconds / 60, seconds % 60]
	_apply_role_restrictions()
	_fit_camera()
	queue_redraw()

func _mark_dirty() -> void:
	save_dirty = true
	last_change_msec = Time.get_ticks_msec()

func _on_autosave_tick() -> void:
	if not save_dirty or not (network.is_solo() or network.is_host()):
		return
	var now := Time.get_ticks_msec()
	if now - last_change_msec >= 1500 or now - last_saved_msec >= 15000:
		_write_save()

func _write_save() -> void:
	if save_slot == "":
		return
	var piece_snapshots := []
	for piece in manager.pieces:
		var snap := piece.snapshot()
		snap.owner_peer_id = 0
		piece_snapshots.append(snap)
	var data := _puzzle_config()
	data["pieces"] = piece_snapshots
	SaveManager.save(data, SaveManager.slot_path(save_slot))
	save_dirty = false
	last_saved_msec = Time.get_ticks_msec()

func _on_viewport_resized() -> void:
	_layout_reference()
	# Android settles its immersive window size after launch; refit so the board starts fully visible.
	if OS.has_feature("mobile"):
		_fit_camera()
	top_hint.visible = get_viewport_rect().size.x >= 1050
	if preview_panel.visible:
		preview_panel.position.x = clampf(preview_panel.position.x, 8, get_viewport_rect().size.x - preview_panel.size.x - 8)

const REFERENCE_TITLE_HEIGHT := 32.0
const REFERENCE_GRIP_SIZE := 18.0

# Keeps the floating window's size/position inside the viewport without resetting
# where the player left it, then re-lays-out its children from that size.
func _layout_reference() -> void:
	if reference_panel == null:
		return
	var viewport_size := get_viewport_rect().size
	var max_size := Vector2(maxf(280, viewport_size.x - 24), maxf(240, viewport_size.y - 24))
	reference_panel.size = Vector2(minf(reference_panel.size.x, max_size.x), minf(reference_panel.size.y, max_size.y))
	if not reference_positioned:
		reference_panel.position = ((viewport_size - reference_panel.size) * 0.5).max(Vector2(12, 60))
		reference_positioned = true
	reference_panel.position = Vector2(
		clampf(reference_panel.position.x, 12, maxf(12, viewport_size.x - reference_panel.size.x - 12)),
		clampf(reference_panel.position.y, 60, maxf(60, viewport_size.y - reference_panel.size.y - 12))
	)
	_layout_reference_window()

func _layout_reference_window() -> void:
	var size := reference_panel.size
	reference_title_bar.position = Vector2.ZERO
	reference_title_bar.size = Vector2(size.x, REFERENCE_TITLE_HEIGHT)
	reference_close_button.size = Vector2(26, 26)
	reference_close_button.position = Vector2(size.x - 32, 3)
	reference_image_area.position = Vector2(6, REFERENCE_TITLE_HEIGHT + 4)
	reference_image_area.size = Vector2(size.x - 12, size.y - REFERENCE_TITLE_HEIGHT - 12)
	reference_grip.position = Vector2(size.x - REFERENCE_GRIP_SIZE - 3, size.y - REFERENCE_GRIP_SIZE - 3)
	reference_grip.size = Vector2(REFERENCE_GRIP_SIZE, REFERENCE_GRIP_SIZE)
	_update_reference_image_layout()
	_clamp_reference_pan()

func _update_reference_image_layout() -> void:
	if reference_image_area == null or source == null:
		return
	var area_size := reference_image_area.size
	var tex_size := source.get_size()
	if area_size.x <= 0 or area_size.y <= 0 or tex_size.x <= 0 or tex_size.y <= 0:
		return
	var fit := minf(area_size.x / tex_size.x, area_size.y / tex_size.y)
	reference_image_view.size = tex_size * fit * reference_zoom

func _clamp_reference_pan() -> void:
	var area_size := reference_image_area.size
	var display_size := reference_image_view.size
	var pos := reference_image_view.position
	if display_size.x <= area_size.x:
		pos.x = (area_size.x - display_size.x) * 0.5
	else:
		pos.x = clampf(pos.x, area_size.x - display_size.x, 0.0)
	if display_size.y <= area_size.y:
		pos.y = (area_size.y - display_size.y) * 0.5
	else:
		pos.y = clampf(pos.y, area_size.y - display_size.y, 0.0)
	reference_image_view.position = pos

func _pan_reference_image(relative: Vector2) -> void:
	reference_image_view.position += relative
	_clamp_reference_pan()

# Keeps the point under the cursor fixed on screen while the zoom level changes,
# the same trick _zoom_at uses for the main board camera.
func _zoom_reference(screen_position: Vector2, multiplier: float) -> void:
	var area_pos := reference_image_area.get_global_rect().position
	var old_size := reference_image_view.size
	var fraction := (screen_position - area_pos - reference_image_view.position) / old_size
	reference_zoom = clampf(reference_zoom * multiplier, 1.0, 4.0)
	_update_reference_image_layout()
	reference_image_view.position = screen_position - area_pos - fraction * reference_image_view.size
	_clamp_reference_pan()

func _reference_window_rect() -> Rect2:
	return reference_panel.get_global_rect()

func _reference_title_rect() -> Rect2:
	return reference_title_bar.get_global_rect()

func _reference_image_rect() -> Rect2:
	return reference_image_area.get_global_rect()

func _reference_grip_rect() -> Rect2:
	return reference_grip.get_global_rect()

# Handles press/release/wheel for the reference window; returns true if the event was
# consumed (so board interaction underneath is skipped) even when it wasn't a drag/resize/
# pan start -- e.g. a click on blank panel padding shouldn't also pick up a piece.
func _handle_reference_mouse_button(event: InputEventMouseButton) -> bool:
	if not reference_overlay.visible:
		return false
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if event.pressed and _reference_image_rect().has_point(event.position):
			_zoom_reference(event.position, 1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15)
			return true
		return _reference_window_rect().has_point(event.position)
	if event.button_index != MOUSE_BUTTON_LEFT:
		return _reference_window_rect().has_point(event.position)
	if not event.pressed:
		var was_active := reference_dragging or reference_resizing or reference_panning
		reference_dragging = false
		reference_resizing = false
		reference_panning = false
		return was_active or _reference_window_rect().has_point(event.position)
	if _reference_grip_rect().has_point(event.position):
		reference_resizing = true
		reference_resize_start_size = reference_panel.size
		reference_resize_start_mouse = event.position
		return true
	if _reference_title_rect().has_point(event.position):
		reference_dragging = true
		return true
	if _reference_image_rect().has_point(event.position):
		reference_panning = true
		return true
	return _reference_window_rect().has_point(event.position)

func _handle_reference_touch_press(position: Vector2) -> bool:
	if _reference_grip_rect().has_point(position):
		reference_resizing = true
		reference_resize_start_size = reference_panel.size
		reference_resize_start_mouse = position
		return true
	if _reference_title_rect().has_point(position):
		reference_dragging = true
		return true
	if _reference_image_rect().has_point(position):
		reference_panning = true
		return true
	return _reference_window_rect().has_point(position)

func _on_bank_action(action: String) -> void:
	if network.is_client() and action in ["spread", "reset", "new"]:
		return
	if action.begins_with("filter:"):
		bank.set_filter(action.trim_prefix("filter:"))
	elif action == "assign_tray":
		if selected_bank_id >= 0 and manager.move_piece_to_tray(selected_bank_id, 1):
			bank.refresh()
	elif action == "spread":
		_spread_table_pieces()
	elif action == "reset":
		_start_puzzle(false)
	elif action == "new":
		_start_puzzle(true)
	elif action == "reference":
		if image_id != "":
			return
		reference_overlay.visible = true
		_hide_preview()
	elif action == "collapse":
		bank.toggle_collapsed()
		_hide_preview()

func _on_bank_hovered(piece_id: int, screen_position: Vector2) -> void:
	_show_preview(piece_id, screen_position)

func _on_bank_unhovered(piece_id: int) -> void:
	if selected_bank_id != piece_id or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_hide_preview()

func _on_bank_pressed(piece_id: int, screen_position: Vector2) -> void:
	selected_bank_id = piece_id
	bank.set_selected(piece_id)
	bank_press_id = piece_id
	bank_press_screen = screen_position
	bank_dragging = false
	_show_preview(piece_id, screen_position)

func _show_preview(piece_id: int, screen_position: Vector2) -> void:
	var piece := manager.get_piece(piece_id)
	if piece == null:
		return
	if preview_view != null:
		preview_view.queue_free()
	preview_view = PIECE_SCENE.instantiate()
	preview_panel.add_child(preview_view)
	preview_view.setup(piece, source, piece.piece_size)
	var factor := minf(170.0 / piece.piece_size.x, 170.0 / piece.piece_size.y)
	preview_view.place_centered(Vector2(139, 121), factor)
	_position_preview(piece.is_on_table, screen_position)
	preview_panel.visible = true
	preview_panel.move_to_front()

func _position_preview(on_table: bool, screen_position: Vector2) -> void:
	var width := get_viewport_rect().size.x
	if on_table:
		# Hovering a piece on the board: float the enlarged view beside the cursor instead of above the bank.
		var x := screen_position.x + 32
		if x + 278 > width - 8:
			x = screen_position.x - 32 - 278
		var max_y := maxf(60.0, bank.position.y - 266.0)
		preview_panel.position = Vector2(clampf(x, 8, width - 286), clampf(screen_position.y - 129, 60, max_y))
	else:
		preview_panel.position = Vector2(clampf(screen_position.x - 139, 8, width - 286), bank.position.y - 270)

func _update_table_hover(screen_position: Vector2) -> void:
	var piece_id := -1
	var blocked := lobby_overlay.visible or (reference_overlay.visible and _reference_window_rect().has_point(screen_position))
	if not blocked and _is_table_screen(screen_position):
		piece_id = _pick_table_piece(_screen_to_world(screen_position))
	if piece_id < 0:
		if hover_table_id >= 0:
			_hide_preview()
		return
	if piece_id != hover_table_id:
		_show_preview(piece_id, screen_position)
		hover_table_id = piece_id
	elif preview_panel.visible:
		_position_preview(true, screen_position)

func _hide_preview() -> void:
	hover_table_id = -1
	if preview_panel:
		preview_panel.visible = false
	if preview_view:
		preview_view.queue_free()
		preview_view = null

func _start_bank_drag(screen_position: Vector2) -> void:
	bank_dragging = true
	_hide_preview()
	drag_ghost = PIECE_SCENE.instantiate()
	ui_root.add_child(drag_ghost)
	var piece_size := manager.get_piece(bank_press_id).piece_size
	drag_ghost.setup(manager.get_piece(bank_press_id), source, piece_size)
	drag_ghost.modulate.a = 0.86
	_update_ghost(screen_position)

func _update_ghost(screen_position: Vector2) -> void:
	if drag_ghost == null:
		return
	var over_table := _is_table_screen(screen_position)
	var piece_size := manager.get_piece(bank_press_id).piece_size
	var factor := camera.zoom.x if over_table else minf(85.0 / piece_size.x, 85.0 / piece_size.y)
	drag_ghost.place_centered(screen_position, factor)

func _clear_ghost() -> void:
	if drag_ghost:
		drag_ghost.queue_free()
		drag_ghost = null
	bank_dragging = false

func _is_table_screen(screen_position: Vector2) -> bool:
	return screen_position.y > 53 and screen_position.y < get_viewport_rect().size.y - bank.bank_height

func _screen_to_world(screen_position: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_position

func _zoom_at(screen_position: Vector2, multiplier: float) -> void:
	var before := _screen_to_world(screen_position)
	var value := clampf(camera.zoom.x * multiplier, 0.15, 3.0)
	camera.zoom = Vector2.ONE * value
	var after := _screen_to_world(screen_position)
	camera.position += before - after

func _input(event: InputEvent) -> void:
	# Touch is handled directly; mouse events emulated from touch exist only so GUI buttons respond.
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_on_escape()
			return
		elif event.keycode == KEY_R and rotation_enabled and not lobby_overlay.visible:
			_rotate_selected()
	if lobby_overlay.visible:
		return
	if event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_touch_drag(event)

func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if _handle_reference_mouse_button(event):
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed and _is_table_screen(event.position):
		_zoom_at(event.position, 1.12)
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed and _is_table_screen(event.position):
		_zoom_at(event.position, 1.0 / 1.12)
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		mouse_panning = event.pressed and _is_table_screen(event.position)
		return
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and rotation_enabled and _is_table_screen(event.position):
		var hit := _pick_table_piece(_screen_to_world(event.position))
		if hit >= 0:
			_select_table_piece(hit)
			_rotate_selected()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if not event.pressed:
		resizing_bank = false
		if bank_press_id >= 0:
			if bank_dragging and _is_table_screen(event.position):
				_place_bank_piece(bank_press_id, event.position)
			bank_press_id = -1
			_clear_ghost()
		if dragging_table_id >= 0:
			network.request_release(dragging_table_id)
			_set_cluster_z(dragging_table_id, 0)
			_select_table_piece(dragging_table_id)
			dragging_table_id = -1
		mouse_panning = false
		return
	if absf(event.position.x - get_viewport_rect().size.x * 0.5) < 42 and absf(event.position.y - bank.position.y) < 13 and not bank.collapsed:
		resizing_bank = true
		return
	if not _is_table_screen(event.position):
		return
	if Input.is_action_pressed("pan_table"):
		mouse_panning = true
		return
	if selected_bank_id >= 0:
		_place_bank_piece(selected_bank_id, event.position)
		return
	var world := _screen_to_world(event.position)
	var picked := _pick_table_piece(world)
	_select_table_piece(picked)
	if picked >= 0 and network.request_pickup(picked):
		dragging_table_id = picked
		drag_offset = world - manager.get_piece(picked).current_position
		_bring_cluster_forward(picked)
	elif picked < 0:
		mouse_panning = true # left-dragging empty table moves the camera

func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if reference_dragging:
		reference_panel.position += event.relative
		_layout_reference()
		return
	if reference_resizing:
		var new_size: Vector2 = reference_resize_start_size + (event.position - reference_resize_start_mouse)
		reference_panel.size = Vector2(maxf(280, new_size.x), maxf(240, new_size.y))
		_layout_reference()
		return
	if reference_panning:
		_pan_reference_image(event.relative)
		return
	if resizing_bank:
		bank.set_height(get_viewport_rect().size.y - event.position.y)
		return
	if bank_press_id >= 0:
		if not bank_dragging and event.position.distance_to(bank_press_screen) > 8:
			_start_bank_drag(event.position)
		if bank_dragging:
			_update_ghost(event.position)
		return
	if mouse_panning:
		camera.position -= event.relative / camera.zoom.x
		_hide_preview()
	elif dragging_table_id >= 0:
		network.request_move(dragging_table_id, _screen_to_world(event.position) - drag_offset)
		_hide_preview()
	else:
		_update_table_hover(event.position)

func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if reference_overlay.visible and fingers.is_empty() and _handle_reference_touch_press(event.position):
			reference_touch_index = event.index
			fingers[event.index] = event.position
			return
		fingers[event.index] = event.position
		if fingers.size() == 2:
			pinch_distance = _finger_distance()
			touch_panning = true
			return
		var from_grip := event.position - Vector2(get_viewport_rect().size.x * 0.5, bank.position.y)
		if absf(from_grip.x) < 60 and from_grip.y > -20 and from_grip.y < 10 and not bank.collapsed:
			resizing_bank = true
			return
		if not _is_table_screen(event.position):
			return
		if selected_bank_id >= 0:
			_place_bank_piece(selected_bank_id, event.position)
			return
		var world := _screen_to_world(event.position)
		var picked := _pick_table_piece(world)
		_select_table_piece(picked)
		if event.double_tap and picked >= 0 and rotation_enabled:
			_rotate_selected()
			return
		if picked >= 0 and network.request_pickup(picked):
			touch_table_id = picked
			drag_offset = world - manager.get_piece(picked).current_position
			_bring_cluster_forward(picked)
		else:
			touch_panning = true
		touch_last = event.position
	else:
		fingers.erase(event.index)
		if event.index == reference_touch_index:
			reference_dragging = false
			reference_resizing = false
			reference_panning = false
			reference_touch_index = -1
		resizing_bank = false
		bank_scrolling = false
		if bank_press_id >= 0:
			if bank_dragging and _is_table_screen(event.position):
				_place_bank_piece(bank_press_id, event.position)
			bank_press_id = -1
			_clear_ghost()
		if touch_table_id >= 0:
			network.request_release(touch_table_id)
			_set_cluster_z(touch_table_id, 0)
			_select_table_piece(touch_table_id)
			touch_table_id = -1
		if fingers.is_empty():
			touch_panning = false
			pinch_distance = 0

func _handle_touch_drag(event: InputEventScreenDrag) -> void:
	var previous: Vector2 = fingers.get(event.index, event.position - event.relative)
	fingers[event.index] = event.position
	if event.index == reference_touch_index:
		if reference_dragging:
			reference_panel.position += event.relative
			_layout_reference()
		elif reference_resizing:
			var new_size: Vector2 = reference_resize_start_size + (event.position - reference_resize_start_mouse)
			reference_panel.size = Vector2(maxf(280, new_size.x), maxf(240, new_size.y))
			_layout_reference()
		elif reference_panning:
			_pan_reference_image(event.relative)
		return
	if resizing_bank:
		bank.set_height(get_viewport_rect().size.y - event.position.y)
		return
	if bank_press_id >= 0:
		if bank_scrolling:
			bank.scroll.scroll_horizontal -= int(event.relative.x)
			return
		if not bank_dragging and event.position.distance_to(bank_press_screen) > 8:
			# A sideways swipe that stays in the bank scrolls it; anything else pulls the piece out.
			var delta := event.position - bank_press_screen
			if not _is_table_screen(event.position) and absf(delta.x) > absf(delta.y):
				bank_scrolling = true
				selected_bank_id = -1
				bank.set_selected(-1)
				_hide_preview()
				bank.scroll.scroll_horizontal -= int(delta.x)
				return
			_start_bank_drag(event.position)
		if bank_dragging:
			_update_ghost(event.position)
		return
	if fingers.size() >= 2:
		var midpoint := _finger_midpoint()
		var distance := _finger_distance()
		if pinch_distance > 10:
			_zoom_at(midpoint, distance / pinch_distance)
		pinch_distance = distance
		camera.position -= (event.position - previous) * 0.5 / camera.zoom.x
	elif touch_table_id >= 0:
		network.request_move(touch_table_id, _screen_to_world(event.position) - drag_offset)
	elif touch_panning and _is_table_screen(event.position):
		camera.position -= event.relative / camera.zoom.x

func _finger_distance() -> float:
	var keys := fingers.keys()
	if keys.size() < 2:
		return 0
	return (fingers[keys[0]] as Vector2).distance_to(fingers[keys[1]])

func _finger_midpoint() -> Vector2:
	var keys := fingers.keys()
	return ((fingers[keys[0]] as Vector2) + (fingers[keys[1]] as Vector2)) * 0.5

func _pick_table_piece(world: Vector2) -> int:
	var children := piece_layer.get_children()
	for i in range(children.size() - 1, -1, -1):
		var view := children[i] as PuzzlePieceView
		if view != null and view.hit_test(world):
			return view.data.piece_id
	return -1

func _select_table_piece(piece_id: int) -> void:
	for view in table_views.values():
		view.set_selected(false)
	selected_table_id = piece_id
	if piece_id >= 0:
		for member_id in manager.cluster_members(piece_id):
			if table_views.has(member_id):
				table_views[member_id].set_selected(true)

func _bring_cluster_forward(piece_id: int) -> void:
	for member_id in manager.cluster_members(piece_id):
		if table_views.has(member_id):
			table_views[member_id].move_to_front()
			table_views[member_id].z_index = 10

func _set_cluster_z(piece_id: int, value: int) -> void:
	for member_id in manager.cluster_members(piece_id):
		if table_views.has(member_id):
			table_views[member_id].z_index = value

func _place_bank_piece(piece_id: int, screen_position: Vector2) -> void:
	var position := _screen_to_world(screen_position) - manager.get_piece(piece_id).piece_size * 0.5
	if not network.request_place_from_bank(piece_id, position):
		return
	# request_place_from_bank synchronously emits piece_changed, which _on_piece_changed
	# already used to create and position the view -- creating another one here would
	# leave a duplicate, orphaned copy behind on the board.
	selected_bank_id = -1
	bank.set_selected(-1)
	_hide_preview()
	_select_table_piece(piece_id)
	network.request_release(piece_id)
	_select_table_piece(piece_id)

func _on_piece_changed(piece_id: int) -> void:
	var piece := manager.get_piece(piece_id)
	if piece == null or not piece.is_on_table:
		return
	# A piece placed/moved by a remote peer has no local view yet; create it reactively.
	if not table_views.has(piece_id):
		var new_view: PuzzlePieceView = PIECE_SCENE.instantiate()
		piece_layer.add_child(new_view)
		new_view.table_mode = true
		new_view.manager = manager
		new_view.setup(piece, source, piece.piece_size)
		table_views[piece_id] = new_view
	table_views[piece_id].place_centered(piece.current_position + piece.piece_size * 0.5)
	table_views[piece_id].refresh_seams()
	# Keep the hover popup in step with a piece that was just turned (by this player or a remote one).
	if piece_id == hover_table_id and preview_view != null and not is_equal_approx(preview_view.rotation_degrees, float(piece.current_rotation)):
		_show_preview(piece_id, get_viewport().get_mouse_position())

func _on_pieces_joined(_cluster_id: int, member_ids: Array) -> void:
	bank.update_counts()
	for member_id in member_ids:
		if table_views.has(member_id):
			var view: PuzzlePieceView = table_views[member_id]
			view.modulate = Color(1.18, 1.10, 0.85)
			create_tween().tween_property(view, "modulate", Color.WHITE, 0.28)

func _rotate_selected() -> void:
	if rotation_enabled and selected_table_id >= 0:
		network.request_rotate(selected_table_id)

func _spread_table_pieces() -> void:
	var group_ids := manager.clusters.keys()
	if group_ids.is_empty():
		return
	group_ids.sort()
	var origin := Vector2(board_size.x * 0.62, -board_size.y * 0.42)
	var cursor := origin
	var row_height := 0.0
	var available_width := board_size.x * 1.7
	var gap := minf(cell.x, cell.y) * 0.72
	for group_id in group_ids:
		var members: Array = manager.clusters[group_id]
		var first: PuzzlePieceState = manager.pieces[members[0]]
		var bounds := Rect2(first.current_position + first.piece_size * 0.5, Vector2.ZERO)
		for member_id in members:
			var member: PuzzlePieceState = manager.pieces[member_id]
			var member_center := member.piece_size * 0.5
			for point in member.outline:
				var world_point := member.current_position + member_center + (point - member_center).rotated(deg_to_rad(member.current_rotation))
				bounds = bounds.expand(world_point)
		if cursor.x > origin.x and cursor.x + bounds.size.x > origin.x + available_width:
			cursor = Vector2(origin.x, cursor.y + row_height)
			row_height = 0
		network.request_move(first.piece_id, first.current_position + cursor - bounds.position)
		cursor.x += bounds.size.x + gap
		row_height = maxf(row_height, bounds.size.y + gap)

func _on_completed() -> void:
	_select_table_piece(-1)
	bank.toggle_collapsed() if not bank.collapsed else null
	var seconds := manager.elapsed_seconds()
	complete_label.text = "Puzzle Complete  •  %02d:%02d" % [seconds / 60, seconds % 60]
	complete_banner.visible = true

func _set_rotation_enabled(value: bool) -> void:
	rotation_enabled = value
	rotation_button.visible = value
	_start_puzzle(false)
