extends Node2D

# The composition root. It builds the controllers, owns the screen furniture (top bar, piece bank, completion
# banner) and the shared services (network, LAN discovery, sound, effects), and connects them together.
# The game logic lives in the controllers:
#   PuzzleSession          the running puzzle: picture, grid, generation, restoring, saving
#   PuzzleBoard            the pieces on the table (views, selection, stacking, finder glow)
#   PuzzleInputController  mouse/touch/keyboard gestures, the bank, the hover popup
#   LobbyController        the main menu, load/collection/host/join/settings and the pause menu
#   ReferenceWindow        the floating reference picture
#   CompletionController   snap/lock celebrations, the finale and the Collection entry
#   PowerController        the Lightning and Magnet zones: charging, the queue they take turns in, strikes and
#                          pulls (PowerView draws them)
#   ClusterSurgeController the player's first spendable power (ClusterSurgeView draws it)
#   GameHud                the thin top strip: score, combo, Charge, stored Power Charges, objective and notices
#   AbilityBar             the numbered power slots above the piece bank

@onready var camera: Camera2D = $Camera2D
@onready var board: PuzzleBoard = $Pieces
@onready var ui_layer: CanvasLayer = $UI

var manager := PuzzleManager.new()
var network: NetworkSession
var lan: LanDiscovery
var sfx: Sfx
var fx: BoardFx

var session: PuzzleSession
var input_controller: PuzzleInputController
var lobby: LobbyController
var reference: ReferenceWindow
var completion: CompletionController
var powers: PowerController
var power_view: PowerView
var surge: ClusterSurgeController
var surge_view: ClusterSurgeView
var hud: GameHud
var ability_bar: AbilityBar

var board_glow := 0.0 # golden frame glow during the finale

# screen furniture
var ui_root: Control
var bank: PieceBank
var complete_banner: PanelContainer
var complete_label: Label

func _ready() -> void:
	DisplayServer.window_set_title("Emberbound Jigsaw  -  build " + BuildInfo.ID)
	SaveManager.migrate_legacy()
	DisplaySettings.apply_saved()
	DisplaySettings.apply_volume(DisplaySettings.load_volume())
	DisplaySettings.vibration_enabled = DisplaySettings.load_vibration()
	_apply_mobile_scale()
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if PuzzleCatalog.SOURCE_IMAGE == null:
		push_error("Bundled puzzle image failed to load: res://assets/emberbound.png")
		return
	_create_services()
	_create_controllers()
	_build_screen()
	_connect_signals()
	get_viewport().size_changed.connect(_on_viewport_resized)
	lobby.show_main_menu()

func _create_services() -> void:
	sfx = Sfx.new()
	add_child(sfx)
	fx = BoardFx.new()
	fx.z_index = 50
	add_child(fx)
	network = NetworkSession.new()
	add_child(network)
	lan = LanDiscovery.new()
	add_child(lan)

func _create_controllers() -> void:
	session = PuzzleSession.new()
	session.setup(manager, network)
	add_child(session)
	network.configure(manager, Callable(session, "puzzle_config"))
	board.setup(manager, session, network)
	reference = ReferenceWindow.new(session.source)
	completion = CompletionController.new()
	completion.manager = manager
	completion.session = session
	completion.board = board
	completion.network = network
	completion.camera = camera
	completion.sfx = sfx
	completion.fx = fx
	completion.set_board_glow = Callable(self, "set_board_glow")
	add_child(completion)
	powers = PowerController.new()
	powers.setup(session, manager, network)
	add_child(powers)
	power_view = PowerView.new()
	power_view.setup(session, manager, board, powers, fx, sfx)
	add_child(power_view)
	surge = ClusterSurgeController.new()
	surge.setup(session, manager, network, session.scoring)
	add_child(surge)
	surge_view = ClusterSurgeView.new()
	surge_view.setup(manager, board, surge, fx, sfx)
	add_child(surge_view)
	input_controller = PuzzleInputController.new()
	input_controller.manager = manager
	input_controller.network = network
	input_controller.session = session
	input_controller.board = board
	input_controller.camera = camera
	input_controller.reference = reference
	input_controller.completion = completion
	input_controller.sfx = sfx
	add_child(input_controller)
	lobby = LobbyController.new()
	lobby.setup(session, network, lan, sfx)

func _connect_signals() -> void:
	# the table
	manager.piece_changed.connect(board.on_piece_changed)
	manager.piece_changed.connect(input_controller.on_piece_changed)
	manager.piece_changed.connect(completion.on_piece_changed)
	manager.bank_changed.connect(func(): bank.sync())
	manager.pieces_joined.connect(_on_pieces_joined)
	manager.group_locked.connect(completion.on_group_locked)
	manager.puzzle_completed.connect(completion.on_completed)
	session.scoring.awarded.connect(completion.on_scoring_awarded)
	session.scoring.tier_rose.connect(completion.on_scoring_tier_rose)
	# the session
	session.puzzle_resetting.connect(_on_puzzle_resetting)
	session.image_changed.connect(_on_image_changed)
	session.puzzle_started.connect(_on_puzzle_started)
	session.puzzle_restored.connect(_on_puzzle_restored)
	# the network
	network.peer_joined.connect(func(_id: int): _update_network_status())
	network.peer_left.connect(func(_id: int): _update_network_status())
	network.connection_established.connect(_update_network_status)
	network.connection_failed.connect(_on_connection_failed)
	network.server_disconnected.connect(_on_server_disconnected)
	network.full_state_received.connect(_on_full_state_received)
	lan.games_updated.connect(lobby.on_lan_games_updated)
	# the menus
	lobby.main_menu_requested.connect(_on_main_menu_requested)
	lobby.hosting_started.connect(_update_network_status)

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

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if lobby != null and lobby.is_at_main_menu_root():
			get_tree().quit()
		else:
			_on_escape()
	elif what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Android may kill the app without a clean quit after backgrounding, and focus-out
		# fires more reliably across OEM skins than the pause notification alone.
		if session != null:
			session.flush_save()

func _input(event: InputEvent) -> void:
	# Touch is handled directly; mouse events emulated from touch exist only so GUI buttons respond.
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_on_escape()
		return
	if lobby.is_open():
		return
	input_controller.handle_input(event)

# Escape: cancel power targeting, close the reference window, step back through a menu, or open the pause menu.
func _on_escape() -> void:
	if ability_bar.cancel_targeting():
		return
	if reference.is_open():
		reference.close()
	elif lobby.is_open():
		lobby.handle_escape()
	else:
		_open_pause_menu()

func _open_pause_menu() -> void:
	input_controller.release_for_menu()
	lobby.show_pause_menu()

# --- drawing the board ---

func _draw() -> void:
	draw_rect(Rect2(Vector2(-5000, -5000), Vector2(10000, 10000)), Color("293a3e"), true)
	for x in range(-4800, 5000, 160):
		draw_line(Vector2(x, -5000), Vector2(x, 5000), Color(1, 1, 1, 0.014), 1)
	for y in range(-4800, 5000, 160):
		draw_line(Vector2(-5000, y), Vector2(5000, y), Color(1, 1, 1, 0.014), 1)
	var board_size := session.board_size
	var frame := Rect2(-board_size * 0.5, board_size)
	draw_rect(frame.grow(17), Color(0.05, 0.08, 0.09, 0.45), true)
	draw_rect(frame.grow(7), Color("ab9e83"), true)
	draw_rect(frame, Color("637374"), true)
	draw_rect(frame, Color("d5c8aa"), false, 3)
	if board_glow > 0.01:
		draw_rect(frame.grow(12), Color(1.0, 0.86, 0.45, 0.5 * board_glow), false, 10)
		draw_rect(frame.grow(26), Color(1.0, 0.86, 0.45, 0.18 * board_glow), false, 22)

func set_board_glow(value: float) -> void:
	board_glow = value
	queue_redraw()

# The table is what is left between the thin top strip and the ability bar and piece bank along the bottom.
func fit_camera() -> void:
	var viewport_size := get_viewport_rect().size
	var board_size := session.board_size
	var bottom := bank.bank_height + AbilityBar.HEIGHT
	var available := Vector2(viewport_size.x - 64, viewport_size.y - bottom - GameHud.TABLE_TOP - 14)
	var fit := minf(available.x / board_size.x, available.y / board_size.y)
	camera.zoom = Vector2.ONE * fit
	camera.position = Vector2(0, (bottom - GameHud.TABLE_TOP) * 0.5 / fit)

func _on_viewport_resized() -> void:
	reference.relayout()
	# Android settles its immersive window size after launch; refit so the board starts fully visible.
	if OS.has_feature("mobile"):
		fit_camera()
	input_controller.on_viewport_resized()

# --- building the screen furniture ---

func _build_screen() -> void:
	ui_root = Control.new()
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(ui_root)
	bank = PieceBank.new()
	ui_root.add_child(bank)
	input_controller.attach_ui(ui_root, bank)
	hud = GameHud.new()
	hud.setup(session.scoring, manager, session)
	hud.menu_requested.connect(_open_pause_menu)
	ui_root.add_child(hud)
	_build_ability_bar()
	_build_complete_banner()
	completion.bank = bank
	completion.banner = complete_banner
	completion.banner_label = complete_label
	ui_root.add_child(reference)
	ui_root.add_child(lobby) # last, so menus draw above everything else

# The power slots just above the bank, wired to the controller that carries each power out.
func _build_ability_bar() -> void:
	ability_bar = AbilityBar.new()
	ability_bar.selection = func(): return board.selected_id
	ability_bar.can_use = func(_ability: String, piece_id: int): return surge.can_use(piece_id, network.local_player_id())
	ability_bar.ability_requested.connect(func(ability: String, piece_id: int):
		if ability == "cluster_surge":
			surge.request(piece_id))
	ability_bar.preview_changed.connect(func(_ability: String, piece_id: int): surge_view.set_preview(piece_id))
	ability_bar.rotate_requested.connect(input_controller.rotate_selected)
	ui_root.add_child(ability_bar)
	input_controller.ability_bar = ability_bar
	session.scoring.state_changed.connect(func(): ability_bar.set_power_charges(session.scoring.power_charges))
	bank.resized.connect(func(): ability_bar.reposition(bank.bank_height))
	ability_bar.reposition(bank.bank_height)

func _build_complete_banner() -> void:
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
	restart.pressed.connect(func(): session.start_puzzle(false))
	complete_row.add_child(restart)
	var next := Button.new()
	next.text = "New puzzle"
	next.pressed.connect(func(): session.start_puzzle(true))
	complete_row.add_child(next)

# --- reacting to the session ---

func _on_puzzle_resetting() -> void:
	ability_bar.cancel_targeting()
	surge_view.set_preview(-1)
	board.clear()
	completion.reset()
	input_controller.reset()

func _on_image_changed(id: String) -> void:
	reference.set_image(session.source)
	bank.set_tool_enabled("reference", id == "") # Random mode has no reference picture

func _on_puzzle_started(pieces: Array) -> void:
	if bank.collapsed:
		bank.toggle_collapsed()
	bank.configure(pieces, session.source, session.seed_value)
	complete_banner.visible = false
	fit_camera()
	queue_redraw()

func _on_puzzle_restored(pieces: Array) -> void:
	completion.remember_cluster_sizes()
	if bank.collapsed:
		bank.toggle_collapsed()
	bank.configure(pieces, session.source, session.seed_value)
	complete_banner.visible = manager.completion_announced
	if manager.completion_announced:
		var seconds := manager.elapsed_seconds()
		complete_label.text = "Puzzle Complete  •  %02d:%02d" % [seconds / 60, seconds % 60]
	_update_network_status()
	fit_camera()
	queue_redraw()

func _on_pieces_joined(cluster_id: int, member_ids: Array) -> void:
	bank.update_counts()
	board.restack()
	board.refresh_type_highlight()
	completion.on_pieces_joined(cluster_id, member_ids)

# --- network and menus ---

func leave_to_menu() -> void:
	if network.is_client():
		session.save_dirty = false # the host's puzzle must never be written to this player's own save
	lan.stop()
	network.stop()
	_update_network_status()
	lobby.show_main_menu()

func _on_main_menu_requested() -> void:
	session.flush_save()
	leave_to_menu()

func _on_connection_failed(reason: String) -> void:
	lobby.set_join_status("%s — check the address/port and that the host's router is forwarding UDP." % reason)

func _on_server_disconnected() -> void:
	session.save_dirty = false
	_update_network_status()
	lobby.show_main_menu()
	lobby.set_join_status("Disconnected from host.")

func _on_full_state_received(config: Dictionary, snapshots: Array) -> void:
	lobby.hide_menu()
	session.restore_from_host(config, snapshots)
	_update_network_status()

func _update_network_status() -> void:
	if network.is_host():
		hud.set_network_status("HOSTING (%d)" % multiplayer.get_peers().size())
	elif network.is_client():
		hud.set_network_status("CONNECTED")
	else:
		hud.set_network_status("")
	# Only the host (or a solo player) may reshape the puzzle.
	for action in ["spread", "reset", "new"]:
		bank.set_tool_enabled(action, not network.is_client())
