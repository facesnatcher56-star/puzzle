class_name EdgePulseController
extends Node

# A short search aid. The host selects edge IDs and spends the shared charge;
# clients only display the host's selection.
signal revealed(piece_ids: Array)

const DURATION := 9.0

var manager: PuzzleManager
var scoring: RunScoring
var network: NetworkSession
var board: PuzzleBoard
var bank: PieceBank
var _timer: Timer

func setup(p_manager: PuzzleManager, p_scoring: RunScoring, p_network: NetworkSession, p_board: PuzzleBoard, p_bank: PieceBank) -> void:
	manager = p_manager
	scoring = p_scoring
	network = p_network
	board = p_board
	bank = p_bank
	network.edge_pulse_requested.connect(activate)
	network.edge_pulse_received.connect(_show)

func _ready() -> void:
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = DURATION
	_timer.timeout.connect(clear)
	add_child(_timer)

func activate() -> bool:
	if network.is_client():
		network.request_edge_pulse()
		return false
	var ids := manager.edge_pulse_targets()
	if ids.is_empty() or not scoring.spend_power_charge():
		return false
	_show(ids)
	network.announce_edge_pulse(ids)
	return true

func _show(ids: Array) -> void:
	board.set_pulse_highlight(ids)
	bank.set_pulse_highlight(ids)
	bank.set_filter("EDGES")
	bank.call_deferred("reveal_first_pulse_item")
	revealed.emit(ids)
	_timer.start()

func clear() -> void:
	if _timer != null:
		_timer.stop()
	board.set_pulse_highlight([])
	bank.set_pulse_highlight([])
