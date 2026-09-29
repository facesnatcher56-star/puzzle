extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("LAN DISCOVERY TEST FAILED: " + message)

func _poll_until(predicate: Callable, timeout_seconds: float, message: String) -> bool:
	var waited := 0.0
	while waited < timeout_seconds:
		if predicate.call():
			return true
		await create_timer(0.1).timeout
		waited += 0.1
	_check(false, "%s (timed out after %.1fs)" % [message, timeout_seconds])
	return false

func _run() -> void:
	var host_lan := LanDiscovery.new()
	root.add_child(host_lan)
	var client_lan := LanDiscovery.new()
	root.add_child(client_lan)
	# A lambda captures outer locals by value, so reassigning a captured var from
	# inside the signal handler wouldn't be visible here -- mutate a shared
	# container instead.
	var state := {"games": []}
	client_lan.games_updated.connect(func(games: Array): state.games = games.filter(func(game): return game.port == 43217))

	host_lan.start_announcing(43217, func(): return "Test Puzzle")
	_check(client_lan.start_listening() == OK, "discovery socket opens")

	await _poll_until(func(): return state.games.size() == 1, 10.0, "client discovers the announcing host")
	if state.games.size() == 1:
		var found: Dictionary = state.games[0]
		_check(found.label == "Test Puzzle", "discovered game reports the host's label")
		_check(found.port == 43217, "discovered game reports the host's game port")
		_check(not found.address.is_empty(), "discovered game reports a source address")

	host_lan.stop()
	await _poll_until(func(): return state.games.is_empty(), 8.0, "stale entry is pruned once the host stops announcing")

	client_lan.stop()
	if failures == 0:
		print("LAN DISCOVERY TEST PASSED: host announces, client discovers and label/port match, stale entries expire")
	quit(0 if failures == 0 else 1)
