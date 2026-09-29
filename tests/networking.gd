extends SceneTree

# Runs a host and a client NetworkSession in the same process against 127.0.0.1, using
# a distinct MultiplayerAPI per subtree (SceneTree.set_multiplayer) so both peers can be
# polled by one SceneTree. This validates protocol/plumbing correctness only -- it can't
# exercise the real port-forward/DDNS path, which needs a one-time manual two-machine
# test after router/DDNS setup. Loopback ENet timing can be flaky under headless CI, so
# every assertion polls with a generous frame timeout rather than asserting on one frame.
#
# NOTE: this is the most version-sensitive test in the suite (SceneMultiplayer /
# SceneTree.set_multiplayer usage). If it fails to even connect on your Godot install,
# check those two calls against your exact 4.7.x docs before assuming the protocol itself
# is broken -- smoke.gd's ownership assertions already cover PuzzleManager in isolation.

var failures := 0
var _client_got_full_state := false

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("NETWORKING TEST FAILED: " + message)

func _poll_until(predicate: Callable, timeout_frames: int, message: String) -> bool:
	for i in range(timeout_frames):
		if predicate.call():
			return true
		await process_frame
	_check(false, "%s (timed out after %d frames)" % [message, timeout_frames])
	return false

func _run() -> void:
	var port := 39217
	var source: Texture2D = load("res://assets/emberbound.png")
	var board_size := Vector2(1122, 1402)
	var cell := Vector2(board_size.x / 2, board_size.y / 2)
	var seed_value := 5

	var host_root := Node.new()
	root.add_child(host_root)
	set_multiplayer(SceneMultiplayer.new(), host_root.get_path())
	var host_manager := PuzzleManager.new()
	host_manager.configure(PuzzleGenerator.generate(source, 2, 2, seed_value, board_size), cell, 2, 2)
	var host_network := NetworkSession.new()
	# RPCs address nodes by path relative to each peer's own multiplayer root, so
	# the two ends of this exchange must share the exact same node name here --
	# otherwise the engine's default "@NetworkSession@N" auto-naming (N is a
	# global, monotonically increasing counter) gives host and client different
	# names and every RPC fails with "Node not found".
	host_network.name = "Session"
	host_root.add_child(host_network)
	host_network.configure(host_manager, func(): return {"seed_value": seed_value, "columns": 2, "rows": 2, "rotation_enabled": false, "elapsed_ms": 0})

	var client_root := Node.new()
	root.add_child(client_root)
	set_multiplayer(SceneMultiplayer.new(), client_root.get_path())
	var client_manager := PuzzleManager.new()
	client_manager.configure(PuzzleGenerator.generate(source, 2, 2, seed_value, board_size), cell, 2, 2)
	var client_network := NetworkSession.new()
	client_network.name = "Session"
	client_root.add_child(client_network)
	client_network.configure(client_manager, func(): return {})
	client_network.full_state_received.connect(func(_config, _snapshots): _client_got_full_state = true)

	_check(host_network.start_host(port) == OK, "host starts listening")
	await process_frame
	_check(client_network.start_client("127.0.0.1", port) == OK, "client starts connecting")

	await _poll_until(func(): return _client_got_full_state, 240, "client receives the initial full sync")
	if not _client_got_full_state:
		quit(1)
		return

	var client_id := client_network.local_player_id()
	_check(client_id != 1, "the client is assigned a peer id distinct from the host")

	_check(client_network.request_place_from_bank(0, Vector2(100, 100)), "client places a piece")
	await _poll_until(func(): return host_manager.get_piece(0).is_on_table, 120, "host learns about the client's placement")

	_check(client_network.request_pickup(0), "client picks up its own placed piece")
	await _poll_until(func(): return host_manager.get_piece(0).owner_peer_id == client_id, 120, "host records the client as the piece's owner")

	client_network.request_move(0, Vector2(250, 175))
	await _poll_until(func(): return host_manager.get_piece(0).current_position.distance_to(Vector2(250, 175)) < 1.0, 180, "host receives the client's move")

	# Return value means "snapped into a neighbor" (see PuzzleManager.request_release), not
	# "release succeeded" -- this piece was dropped at an arbitrary, non-matching spot.
	client_network.request_release(0)
	await _poll_until(func(): return host_manager.get_piece(0).owner_peer_id == 0, 120, "host clears ownership after release")

	_check(client_network.request_pickup(0), "client re-picks the piece before disconnecting")
	await _poll_until(func(): return host_manager.get_piece(0).owner_peer_id == client_id, 120, "host confirms the pre-disconnect pickup")
	client_network.stop()
	await _poll_until(func(): return host_manager.get_piece(0).owner_peer_id == 0, 180, "host releases pieces held by a peer that disconnected")

	if failures == 0:
		print("NETWORKING TEST PASSED: host/client full sync, pickup/move/release protocol, disconnect cleanup")
	quit(0 if failures == 0 else 1)
