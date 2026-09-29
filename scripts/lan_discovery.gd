class_name LanDiscovery
extends Node

# Lets a host announce itself on the local network so a client can tap to join
# instead of typing an address. This is a separate, connectionless UDP broadcast
# on its own port -- distinct from the actual ENet game port -- so it works
# before any peer connection exists. It only reaches devices on the same LAN;
# players on a different network still need the manual address/DDNS path.

signal games_updated(games: Array)

const DISCOVERY_PORT := 8911
const BROADCAST_INTERVAL := 1.5
const STALE_AFTER := 4.0
const APP_ID := "emberbound-jigsaw"

var _announce_peer: PacketPeerUDP
var _listen_peer: PacketPeerUDP
var _timer: Timer
var _discovered := {} # session_id (String) -> {address, port, label, last_seen}
var _label_provider: Callable
var _game_port := 0
var _session_id := 0

func start_announcing(game_port: int, label_provider: Callable) -> void:
	stop()
	_game_port = game_port
	_label_provider = label_provider
	# A machine with more than one active network interface (VPN, virtual
	# adapters, etc.) can have a single broadcast arrive at a listener more
	# than once, via different local paths, and even report a different -- or
	# blank -- source address each time. A random per-session id lets the
	# listener recognize those as one host rather than showing duplicates.
	_session_id = randi()
	_announce_peer = PacketPeerUDP.new()
	_announce_peer.set_broadcast_enabled(true)
	_timer = Timer.new()
	_timer.wait_time = BROADCAST_INTERVAL
	_timer.timeout.connect(_broadcast)
	add_child(_timer)
	_timer.start()
	_broadcast()

func start_listening() -> Error:
	stop()
	_listen_peer = PacketPeerUDP.new()
	var err := _listen_peer.bind(DISCOVERY_PORT)
	if err != OK:
		stop()
		return err
	_timer = Timer.new()
	_timer.wait_time = 0.25
	_timer.timeout.connect(_poll)
	add_child(_timer)
	_timer.start()
	return OK

func stop() -> void:
	if _timer != null:
		_timer.stop()
		_timer.queue_free()
		_timer = null
	if _announce_peer != null:
		_announce_peer.close()
		_announce_peer = null
	if _listen_peer != null:
		_listen_peer.close()
		_listen_peer = null
	_discovered.clear()

func _broadcast() -> void:
	var payload := {"proto": 1, "app": APP_ID, "session_id": _session_id, "label": _label_provider.call(), "port": _game_port}
	_announce_peer.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_announce_peer.put_packet(JSON.stringify(payload).to_utf8_buffer())

func _poll() -> void:
	var changed := false
	while _listen_peer.get_available_packet_count() > 0:
		var raw := _listen_peer.get_packet().get_string_from_utf8()
		var address := _listen_peer.get_packet_ip()
		var parsed = JSON.parse_string(raw)
		if typeof(parsed) != TYPE_DICTIONARY or parsed.get("app") != APP_ID or address.is_empty():
			continue
		var key := str(parsed.get("session_id", "%s:%d" % [address, int(parsed.get("port", 0))]))
		_discovered[key] = {
			"address": address, "port": int(parsed.get("port", 0)),
			"label": str(parsed.get("label", "Puzzle Game")),
			"last_seen": Time.get_ticks_msec() / 1000.0,
		}
		changed = true
	var now := Time.get_ticks_msec() / 1000.0
	for key in _discovered.keys().duplicate():
		if now - _discovered[key].last_seen > STALE_AFTER:
			_discovered.erase(key)
			changed = true
	if changed:
		games_updated.emit(_discovered.values())
