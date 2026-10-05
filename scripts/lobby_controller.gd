class_name LobbyController
extends Control

# Every menu screen: the main menu, New Game, Load Game, Collection, Host, Join, Settings and the in-game
# pause menu (the same overlay, shown over a running puzzle). It builds the screens and turns button presses
# into calls on the session and network; the screen owner is told about the two things it must act on
# itself through signals.

# "Main Menu" was pressed on the pause menu: save, stop any network session and return to the main menu.
signal main_menu_requested
# A game was hosted from the Host screen (the network status display needs refreshing).
signal hosting_started

var session: PuzzleSession
var network: NetworkSession
var lan: LanDiscovery
var sfx: Sfx

var stack: VBoxContainer
var sub_open := false # a screen below the root (New Game, Settings, ...) is showing
var in_game_menu := false # the overlay doubles as the Esc/pause menu while a puzzle is open

var _settings_fullscreen_picker: OptionButton
var _settings_resolution_picker: OptionButton
var _host_port_field: LineEdit
var _host_game_picker: OptionButton
var _host_entries: Array = [] # parallel to the picker's items: {random} for new games, {slot, data} for saved ones
var _host_save_label: Label
var _host_status_label: Label
var _pause_save_button: Button
var _join_address_field: LineEdit
var _join_status_label: Label
var _join_games_list: VBoxContainer
var _join_games_status: Label

func setup(p_session: PuzzleSession, p_network: NetworkSession, p_lan: LanDiscovery, p_sfx: Sfx) -> void:
	session = p_session
	network = p_network
	lan = p_lan
	sfx = p_sfx

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var backdrop := TextureRect.new()
	backdrop.texture = PuzzleCatalog.SOURCE_IMAGE
	backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.modulate = Color(0.45, 0.5, 0.55)
	add_child(backdrop)
	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.05, 0.08, 0.82)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(460, 0)
	panel.theme = _theme()
	add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 34)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(margin)
	stack = VBoxContainer.new()
	stack.add_theme_constant_override("separation", 12)
	margin.add_child(stack)
	_build_root()

# --- public interface ---

func is_open() -> bool:
	return visible

# True on the top-level main menu (where the Android back button should quit).
func is_at_main_menu_root() -> bool:
	return visible and not sub_open and not in_game_menu

func show_main_menu() -> void:
	in_game_menu = false
	_build_root()
	visible = true

func show_pause_menu() -> void:
	in_game_menu = true
	_build_root()
	visible = true

func hide_menu() -> void:
	visible = false

# Escape / back: one level up, or close the pause menu.
func handle_escape() -> void:
	if sub_open:
		_build_root()
	elif in_game_menu:
		hide_menu()

func show_collection() -> void:
	_build_collection()

func show_settings() -> void:
	_build_settings()

# Text shown under the Join screen's connect button (connection failures, disconnects).
func set_join_status(text: String) -> void:
	if _join_status_label != null:
		_join_status_label.text = text

func on_lan_games_updated(games: Array) -> void:
	if _join_games_list == null:
		return
	for child in _join_games_list.get_children():
		_join_games_list.remove_child(child)
		child.queue_free()
	_join_games_status.visible = games.is_empty()
	games.sort_custom(func(a, b): return a.label < b.label)
	for game in games:
		var entry := Button.new()
		entry.text = "%s  (%s)" % [game.label, game.address]
		entry.pressed.connect(_on_lan_game_pressed.bind(game.address, game.port))
		_join_games_list.add_child(entry)

# --- styling and building blocks ---

func _box(fill: Color, border: Color, border_width: int = 1, radius: int = 10) -> StyleBoxFlat:
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

func _theme() -> Theme:
	var theme := Theme.new()
	var gold := Color("e0b96a")
	theme.set_stylebox("panel", "PanelContainer", UiStyle.panel(10.0))
	theme.set_stylebox("normal", "Button", UiStyle.button())
	theme.set_stylebox("hover", "Button", UiStyle.button(true))
	theme.set_stylebox("pressed", "Button", UiStyle.button(false, true))
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	theme.set_color("font_color", "Button", Color("eef0e6"))
	theme.set_color("font_hover_color", "Button", Color("fff2cf"))
	theme.set_font_size("font_size", "Button", 17)
	theme.set_stylebox("normal", "LineEdit", _box(Color("0c141b"), Color("3d5661"), 1, 8))
	theme.set_stylebox("focus", "LineEdit", _box(Color("0c141b"), gold, 1, 8))
	theme.set_stylebox("normal", "OptionButton", _box(Color("1f3039"), Color("3d5661"), 1, 8))
	theme.set_stylebox("hover", "OptionButton", _box(Color("2b4452"), gold, 1, 8))
	theme.set_stylebox("pressed", "OptionButton", _box(Color("16242c"), gold, 1, 8))
	theme.set_color("font_color", "Label", Color("c9d6d6"))
	return theme

func _heading(text: String, subtitle: String = "") -> void:
	var title := Label.new()
	title.text = text
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color("f4e5c3"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(title)
	if subtitle != "":
		var sub := Label.new()
		sub.text = subtitle
		sub.add_theme_font_size_override("font_size", 14)
		sub.add_theme_color_override("font_color", Color("8fa6a8"))
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stack.add_child(sub)
	var rule := ColorRect.new()
	rule.color = Color("e0b96a66")
	rule.custom_minimum_size.y = 2
	stack.add_child(rule)
	var gap := Control.new()
	gap.custom_minimum_size.y = 4
	stack.add_child(gap)

func _button(text: String, detail: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text if detail == "" else "%s\n%s" % [text, detail]
	button.custom_minimum_size.y = 52 if detail == "" else 66
	button.pressed.connect(callback)
	stack.add_child(button)
	return button

func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color("8fa6a8"))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	stack.add_child(label)
	return label

func _back_button() -> Button:
	var back := _button("Back", "", _build_root)
	back.custom_minimum_size.y = 46
	return back

func _clear() -> void:
	for child in stack.get_children():
		stack.remove_child(child)
		child.queue_free()

# Starts a screen: clears the stack and records whether it is a sub-screen.
func _begin_screen(is_sub: bool) -> void:
	_clear()
	sub_open = is_sub

# --- main menu and pause menu ---

func _build_root() -> void:
	_begin_screen(false)
	if in_game_menu:
		_build_pause_root()
		return
	_heading("JIGSAW", "Piece it together. Alone or with friends.")
	var saves := PuzzleSession.active_saves()
	if not saves.is_empty():
		var latest: Dictionary = saves[0].data
		var slot: String = saves[0].slot
		_button("Continue", "%s  •  %s" % [SaveFormat.title(latest), SaveFormat.detail(latest)], func(): _on_load_slot_pressed(slot))
	_button("New Game", "Start a fresh puzzle", _build_new_game)
	_button("Load Game", "%d saved puzzle%s" % [saves.size(), "" if saves.size() == 1 else "s"] if not saves.is_empty() else "No saved puzzles yet", _build_load)
	var finished := Collection.load_all().size()
	_button("Collection", "%d completed puzzle%s" % [finished, "" if finished == 1 else "s"] if finished > 0 else "Finished puzzles and stats appear here", _build_collection)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	stack.add_child(row)
	for entry in [["Host Game", _build_host], ["Join Game", _build_join]]:
		var button := Button.new()
		button.text = entry[0]
		button.custom_minimum_size.y = 52
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(entry[1])
		row.add_child(button)
	var extras := HBoxContainer.new()
	extras.add_theme_constant_override("separation", 12)
	stack.add_child(extras)
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
	var build_label := _caption("Build " + BuildInfo.ID)
	build_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

func _build_pause_root() -> void:
	_heading("PAUSED", "Progress also saves automatically")
	_button("Resume", "", hide_menu)
	_pause_save_button = null
	if not network.is_client():
		_pause_save_button = _button("Save Game", "", _on_save_pressed)
	if not network.is_client():
		var grid: Vector2i = session.sizes[session.size_index]
		_button("Piece Count", "%d pieces" % (grid.x * grid.y), _build_piece_count)
	_button("Settings", "", _build_settings)
	_button("Main Menu", "", func(): main_menu_requested.emit())
	if not OS.has_feature("mobile"):
		_button("Quit Game", "", _on_quit_pressed)

# Changing the piece count starts the same picture over at the new size, so it is a choice made here, off the
# live screen, not a control that sits in the HUD.
func _build_piece_count() -> void:
	_begin_screen(true)
	_heading("PIECE COUNT", "Starts this puzzle over at the new size")
	for i in range(session.sizes.size()):
		var grid: Vector2i = session.sizes[i]
		var current := i == session.size_index
		var button := _button("%d pieces" % (grid.x * grid.y), "Current size" if current else "%d × %d" % [grid.x, grid.y], func():
			session.size_index = i
			hide_menu()
			session.start_puzzle(false))
		if current:
			button.modulate = Color("f3dba4")
	_back_button()

func _on_save_pressed() -> void:
	session.write_save()
	if _pause_save_button != null:
		_pause_save_button.text = "Saved ✓"

func _on_quit_pressed() -> void:
	session.flush_save()
	get_tree().quit()

# --- new game, load game, collection ---

func _build_new_game() -> void:
	_begin_screen(true)
	_heading("NEW GAME", "Choose a puzzle")
	_button("Emberbound", "Classic artwork  •  with reference image", func(): _start_new(false))
	var random_detail := "A surprise picture  •  no reference"
	if PuzzleSession.fresh_random_images().is_empty():
		random_detail = "Every picture is finished or started  •  pictures may repeat"
	_button("Random Puzzle", random_detail, func(): _start_new(true))
	_button("Generated Puzzle", "A brand-new picture made for you  •  choose a theme", _build_theme_picker)
	_back_button()

# Generated pictures: pick a theme (or let the game choose). Every theme is cut and played exactly like a Random Puzzle.
func _build_theme_picker() -> void:
	_begin_screen(true)
	_heading("GENERATED PUZZLE", "A picture made just for this puzzle")
	_button("Surprise Me", "A different theme each time", func(): _start_generated(ProceduralImage.ANY))
	for theme in ProceduralImage.THEMES:
		_button(theme.name, theme.blurb, _start_generated.bind(theme.id))
	var back := _button("Back", "", _build_new_game)
	back.custom_minimum_size.y = 46

func _start_generated(theme: String) -> void:
	hide_menu()
	session.new_generated_session(theme)

func _start_new(random_mode: bool) -> void:
	hide_menu()
	session.new_session(random_mode)

func _build_load() -> void:
	_begin_screen(true)
	_heading("LOAD GAME", "Pick up where you left off")
	var saves := PuzzleSession.active_saves()
	if saves.is_empty():
		_caption("No saved puzzles yet. Start a new game and it will be saved here automatically.")
	else:
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.custom_minimum_size.y = minf(saves.size() * 74.0, 330.0)
		stack.add_child(scroll)
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
			load_button.text = "%s\n%s" % [SaveFormat.title(entry.data), SaveFormat.detail(entry.data)]
			load_button.custom_minimum_size.y = 66
			load_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			load_button.pressed.connect(_on_load_slot_pressed.bind(slot))
			row.add_child(load_button)
			var delete_button := Button.new()
			delete_button.text = "Delete"
			delete_button.custom_minimum_size = Vector2(76, 66)
			delete_button.pressed.connect(_on_delete_slot_pressed.bind(slot, delete_button))
			row.add_child(delete_button)
	_back_button()

# Two-step delete: the first press arms the button, the second removes the save.
func _on_delete_slot_pressed(slot: String, button: Button) -> void:
	if button.text != "Sure?":
		button.text = "Sure?"
		return
	SaveManager.delete_slot(slot)
	_build_load()

func _on_load_slot_pressed(slot: String) -> void:
	if session.load_session(slot):
		hide_menu()

func _build_collection() -> void:
	_begin_screen(true)
	var entries := Collection.load_all()
	var totals := Collection.totals(entries)
	_heading("COLLECTION", "Every puzzle you've finished")
	if entries.is_empty():
		_caption("Nothing here yet. Finish a puzzle and it is saved to your Collection with its time and stats.")
	else:
		var summary := _caption("%d completed  •  %d pieces placed  •  %s total  •  %d of %d pictures" % [totals.count, totals.pieces, SaveFormat.format_time(totals.time_ms), totals.pictures, PuzzleCatalog.RANDOM_IMAGES.size() + 1])
		summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var best := Collection.best_times(entries)
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.custom_minimum_size = Vector2(520, minf(entries.size() * 98.0, 340.0))
		stack.add_child(scroll)
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 8)
		scroll.add_child(list)
		for entry in entries:
			list.add_child(_collection_card(entry, best))
		_caption("★ marks your fastest time for that picture and piece count.")
	_back_button()

func _collection_card(entry: Dictionary, best: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _box(Color("1a2831"), Color("2f444e"), 1, 10))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	card.add_child(row)
	var thumb := TextureRect.new()
	thumb.texture = PuzzleCatalog.thumbnail_for(str(entry.get("image_id", "")), int(entry.get("seed_value", 0)))
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb.custom_minimum_size = Vector2(104, 78)
	thumb.clip_contents = true
	row.add_child(thumb)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(text)
	var title := Label.new()
	title.text = SaveFormat.title(entry)
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color("f4e5c3"))
	text.add_child(title)
	var is_best: bool = int(entry.get("time_ms", 0)) > 0 and int(entry.get("time_ms", 0)) == int(best.get(Collection.bucket(entry), -1))
	var stats := Label.new()
	stats.text = "%d pieces%s" % [int(entry.pieces), "  •  online" if entry.get("online", false) else ""]
	stats.add_theme_font_size_override("font_size", 13)
	text.add_child(stats)
	var result := Label.new()
	result.text = "%s%s  •  %s" % ["★ " if is_best else "", SaveFormat.format_time(int(entry.get("time_ms", 0))), SaveFormat.format_stamp(int(entry.get("completed_at", 0)))]
	result.add_theme_font_size_override("font_size", 13)
	result.add_theme_color_override("font_color", Color("e0b96a") if is_best else Color("9fb4b6"))
	text.add_child(result)
	return card

# --- hosting and joining ---

func _build_host() -> void:
	_begin_screen(true)
	_heading("HOST GAME", "Others on your Wi-Fi will see it automatically")
	var port_row := HBoxContainer.new()
	stack.add_child(port_row)
	var port_label := Label.new()
	port_label.text = "Port"
	port_row.add_child(port_label)
	_host_port_field = LineEdit.new()
	_host_port_field.text = str(NetworkSession.DEFAULT_PORT)
	_host_port_field.custom_minimum_size.x = 100
	port_row.add_child(_host_port_field)
	var game_row := VBoxContainer.new()
	stack.add_child(game_row)
	var game_label := Label.new()
	game_label.text = "Game"
	game_row.add_child(game_label)
	_host_game_picker = OptionButton.new()
	_host_game_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_game_picker.clip_text = true
	game_row.add_child(_host_game_picker)
	_host_save_label = _caption("")
	_host_entries = [{"random": false}, {"random": true}, {"generated": ProceduralImage.ANY}]
	_host_game_picker.add_item("New: Emberbound")
	_host_game_picker.add_item("New: Random Puzzle")
	_host_game_picker.add_item("New: Generated Puzzle")
	for entry in PuzzleSession.active_saves():
		_host_entries.append({"slot": entry.slot, "data": entry.data})
		_host_game_picker.add_item("Saved: %s  •  %s" % [SaveFormat.title(entry.data), SaveFormat.detail(entry.data).get_slice("  •  ", 0)])
	_host_game_picker.item_selected.connect(_on_host_game_selected)
	# Default to the most recent saved game when there is one.
	_host_game_picker.select(3 if _host_entries.size() > 3 else 0)
	_on_host_game_selected(_host_game_picker.selected)
	var start_button := Button.new()
	start_button.text = "Start Hosting"
	start_button.pressed.connect(_on_start_hosting_pressed)
	stack.add_child(start_button)
	_host_status_label = Label.new()
	_host_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_host_status_label.text = "Players on this Wi-Fi see this game automatically. For players elsewhere, forward this port (UDP) on your router and share your DDNS address."
	stack.add_child(_host_status_label)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_build_root)
	stack.add_child(back)

func _on_host_game_selected(index: int) -> void:
	var entry: Dictionary = _host_entries[index]
	if entry.has("slot"):
		_host_save_label.text = "Continues exactly as you left it.  " + SaveFormat.detail(entry.data)
	else:
		_host_save_label.text = "Starts a brand new puzzle."

func _on_start_hosting_pressed() -> void:
	var port := int(_host_port_field.text)
	if port <= 0 or port > 65535:
		_host_status_label.text = "Enter a valid port number (1-65535)."
		return
	var err := network.start_host(port)
	if err != OK:
		_host_status_label.text = "Could not start hosting (error %d). Is the port already in use?" % err
		return
	lan.start_announcing(port, Callable(self, "_lan_label"))
	hide_menu()
	var entry: Dictionary = _host_entries[_host_game_picker.selected]
	if not entry.has("slot") or not session.load_session(entry.slot):
		if entry.has("generated"):
			session.new_generated_session(str(entry.generated))
		else:
			session.new_session(bool(entry.get("random", false)))
	hosting_started.emit()

func _lan_label() -> String:
	var peer_count := 1 + multiplayer.get_peers().size()
	var name := "Emberbound Jigsaw"
	if PuzzleCatalog.is_generated(session.image_id):
		name = "Generated Puzzle"
	elif session.image_id != "":
		name = "Random Puzzle"
	return "%s (%d online)" % [name, peer_count]

func _build_join() -> void:
	_begin_screen(true)
	_heading("JOIN GAME", "Games found on this network")
	_join_games_status = Label.new()
	_join_games_status.text = "Searching..."
	_join_games_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	stack.add_child(_join_games_status)
	_join_games_list = VBoxContainer.new()
	stack.add_child(_join_games_list)
	var divider := Label.new()
	divider.text = "— or enter an address —"
	divider.add_theme_color_override("font_color", Color("8fa6a8"))
	divider.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(divider)
	_join_address_field = LineEdit.new()
	_join_address_field.placeholder_text = "yourname.duckdns.org:%d" % NetworkSession.DEFAULT_PORT
	stack.add_child(_join_address_field)
	var connect_button := Button.new()
	connect_button.text = "Connect"
	connect_button.pressed.connect(_on_connect_pressed)
	stack.add_child(connect_button)
	_join_status_label = Label.new()
	_join_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	stack.add_child(_join_status_label)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_on_join_back_pressed)
	stack.add_child(back)
	var discovery_error := lan.start_listening()
	on_lan_games_updated([])
	if discovery_error != OK:
		_join_games_status.text = "Could not search this network (error %d). Try entering the host address below." % discovery_error

func _on_connect_pressed() -> void:
	lan.stop()
	var text := _join_address_field.text.strip_edges()
	var address := text
	var port := NetworkSession.DEFAULT_PORT
	var split := text.rsplit(":", true, 1)
	if split.size() == 2:
		address = split[0]
		port = int(split[1])
	if address.is_empty() or port <= 0 or port > 65535:
		_join_status_label.text = "Enter an address as host:port."
		return
	_connect_to(address, port)

func _on_lan_game_pressed(address: String, port: int) -> void:
	lan.stop()
	_connect_to(address, port)

func _connect_to(address: String, port: int) -> void:
	var err := network.start_client(address, port)
	if err != OK:
		_join_status_label.text = "Could not start connection (error %d)." % err
		return
	_join_status_label.text = "Connecting..."

func _on_join_back_pressed() -> void:
	lan.stop()
	_build_root()

# --- settings ---

func _build_settings() -> void:
	_begin_screen(true)
	_heading("SETTINGS", "Display")
	if not DisplaySettings.is_supported():
		_caption("Window and resolution options are available on the desktop version.")
	else:
		var saved := DisplaySettings.load_settings()
		_settings_fullscreen_picker = OptionButton.new()
		_settings_fullscreen_picker.add_item("Windowed")
		_settings_fullscreen_picker.add_item("Fullscreen")
		_settings_fullscreen_picker.select(1 if saved.fullscreen else 0)
		_settings_resolution_picker = OptionButton.new()
		var saved_size := Vector2i(saved.width, saved.height)
		var resolutions := DisplaySettings.available_resolutions()
		var best := 0
		for i in range(resolutions.size()):
			_settings_resolution_picker.add_item("%d x %d" % [resolutions[i].x, resolutions[i].y])
			if absi(resolutions[i].x * resolutions[i].y - saved_size.x * saved_size.y) < absi(resolutions[best].x * resolutions[best].y - saved_size.x * saved_size.y):
				best = i
		_settings_resolution_picker.select(best)
		_settings_resolution_picker.disabled = saved.fullscreen
		_settings_fullscreen_picker.item_selected.connect(func(_i: int): _apply_display_choice())
		_settings_resolution_picker.item_selected.connect(func(_i: int): _apply_display_choice())
		_settings_row("Window", _settings_fullscreen_picker)
		_settings_row("Resolution", _settings_resolution_picker)
		_caption("Resolution applies to windowed mode. Fullscreen uses your monitor's native resolution.")
	var volume := HSlider.new()
	volume.min_value = 0
	volume.max_value = 100
	volume.step = 1
	volume.value = DisplaySettings.load_volume() * 100.0
	volume.custom_minimum_size = Vector2(200, 28)
	volume.value_changed.connect(func(value: float):
		DisplaySettings.apply_volume(value / 100.0)
		DisplaySettings.save_volume(value / 100.0))
	volume.drag_ended.connect(func(_changed: bool): sfx.snap(12))
	_settings_row("Sound", volume)
	if OS.has_feature("mobile"):
		var vibration := CheckButton.new()
		vibration.text = "On"
		vibration.button_pressed = DisplaySettings.vibration_enabled
		vibration.toggled.connect(func(on: bool): DisplaySettings.save_vibration(on))
		_settings_row("Vibration", vibration)
	_back_button()

func _settings_row(label_text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	stack.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 120
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)

func _apply_display_choice() -> void:
	var fullscreen := _settings_fullscreen_picker.selected == 1
	var resolutions := DisplaySettings.available_resolutions()
	var size: Vector2i = resolutions[clampi(_settings_resolution_picker.selected, 0, resolutions.size() - 1)]
	_settings_resolution_picker.disabled = fullscreen
	DisplaySettings.save_settings(fullscreen, size)
	DisplaySettings.apply(fullscreen, size)
