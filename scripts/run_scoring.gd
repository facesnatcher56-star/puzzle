class_name RunScoring
extends RefCounted

# The run's scoring. Only the solo game or host turns PuzzleManager events into rewards. Clients apply the host's
# serialized state and event; piece snapshots never grant rewards.
#
# What is shared and what is personal: the Score, the anchored-corners milestone and the awarded pieces belong to
# the whole group. Charge, stored Power Charges and the streak belong to each player: every award goes to the
# player whose action caused it (PuzzleManager.acting_player -- whoever let go of the piece, or whoever's power set
# a chain off), builds only that player's Charge and streak, and is multiplied by that player's own streak. Nobody
# else's play adds to or breaks them. Personal state is not saved for joining players: a player who connects
# starts with nothing, and it is dropped when they leave. The host (and a solo player) is player key 0 and keeps
# their personal state in the save, as before.
#
# The streak: a piece that is solo and has never been dropped within snapping distance of another piece, and
# that the player then lets go of where it joins, is a first-try placement. Each one extends the streak, and the
# streak multiplies every score and Charge award, exponentially (STREAK_BASE ^ streak, up to STREAK_CAP). Pieces
# can be rotated and dropped in the open as often as you like without costing anything. The streak ends -- it is
# never subtracted from, and nothing decays with time -- only when such a piece is dropped near another piece
# and does not join. Joins made by powers, by clusters, or by pieces that already had an attempt neither extend
# nor end it.
signal state_changed
signal awarded(event: Dictionary)
signal tier_rose(tier: int)
signal anchors_completed(player: int)

enum Tier { NORMAL, WARM, HOT, ON_FIRE }

const STREAK_BASE := 1.12 # each first-try placement grows the streak's raw bonus by this factor...
const STREAK_REWARD_SCALE := 3.0 # ...and the bonus part of the multiplier (everything above x1) is paid at this many times (+200%)
const STREAK_CAP := 60.0 # the multiplier never goes above this
const TIER_STREAKS := [0, 3, 6, 10] # the streak at which each tier starts (the tier drives the flame, sounds and Charge)
const CHARGE_GAIN_SCALE := 1.3 # 30% more meter gain, rounded once after all multipliers.
const CHARGE_MULTIPLIERS := [1.0, 1.3, 1.6, 2.05] # the tiers' Charge bonus (above x1) is also tripled

const HOST_KEY := 0 # the host and a solo player share this key; everyone else is keyed by their peer id

# One player's own buildup.
class Ledger extends RefCounted:
	var charge := 0
	var power_charges := 0
	var streak := 0
	var best_streak := 0

	func to_dict() -> Dictionary:
		return {"charge": charge, "power_charges": power_charges, "streak": streak, "best_streak": best_streak}

	func load_dict(data: Dictionary) -> void:
		charge = clampi(int(data.get("charge", 0)), 0, 99)
		power_charges = maxi(0, int(data.get("power_charges", 0)))
		streak = maxi(0, int(data.get("streak", 0)))
		best_streak = maxi(streak, int(data.get("best_streak", 0)))

var manager: PuzzleManager
var network: NetworkSession
var score := 0 # shared
var revision := 0
var anchors_rewarded := false # shared
var _ledgers := {} # player key -> Ledger
var _awarded_ids := {}
var _legacy_anchors_unset := false
var _candidate := -1 # the solo piece whose first-try drop is being resolved...
var _candidate_key := HOST_KEY # ...and the player who dropped it
var _candidate_counted := false

# The local player's own values (what the HUD and the ability bar show).
var charge: int:
	get: return ledger(local_key()).charge
	set(value): ledger(local_key()).charge = value
var power_charges: int:
	get: return ledger(local_key()).power_charges
	set(value): ledger(local_key()).power_charges = value
var streak: int:
	get: return ledger(local_key()).streak
	set(value): ledger(local_key()).streak = value
var best_streak: int:
	get: return ledger(local_key()).best_streak
	set(value): ledger(local_key()).best_streak = value

# The scoring key of a player id: the host and a solo player are 0, every other player is their peer id.
static func key_for(player_id: int) -> int:
	return HOST_KEY if player_id <= 1 else player_id

func local_key() -> int:
	return key_for(network.local_player_id()) if network != null else HOST_KEY

func ledger(key: int) -> Ledger:
	if not _ledgers.has(key):
		_ledgers[key] = Ledger.new()
	return _ledgers[key]

func setup(p_manager: PuzzleManager, p_network: NetworkSession) -> void:
	manager = p_manager
	network = p_network
	manager.main_puzzle_connected.connect(_on_main_connected)
	manager.loose_puzzle_connected.connect(_on_loose_connected)
	manager.first_try_started.connect(_on_first_try_started)
	manager.first_try_ended.connect(_on_first_try_ended)
	network.scoring_sync_received.connect(_on_remote_sync)
	network.peer_left.connect(_on_peer_left)

# A player who leaves takes their buildup with them.
func _on_peer_left(peer_id: int) -> void:
	if _ledgers.erase(key_for(peer_id)):
		state_changed.emit()

func reset() -> void:
	score = 0
	_ledgers.clear()
	_candidate = -1
	_candidate_counted = false
	revision = 0
	anchors_rewarded = false
	_legacy_anchors_unset = false
	_awarded_ids.clear()
	state_changed.emit()

func tier(key: int = -1) -> int:
	return tier_for(ledger(local_key() if key < 0 else key).streak)

static func tier_for(streak_length: int) -> int:
	for i in range(TIER_STREAKS.size() - 1, 0, -1):
		if streak_length >= TIER_STREAKS[i]:
			return i
	return Tier.NORMAL

# The score and Charge multiplier of a streak: exponential, so a long unbroken run is worth a great deal.
static func streak_multiplier(streak_length: int) -> float:
	return minf(1.0 + STREAK_REWARD_SCALE * (pow(STREAK_BASE, maxi(0, streak_length)) - 1.0), STREAK_CAP)

func multiplier(key: int = -1) -> float:
	return streak_multiplier(ledger(local_key() if key < 0 else key).streak)

static func format_multiplier(value: float) -> String:
	return "%.2f" % value if value < 10.0 else "%.1f" % value

static func tier_name(value: int) -> String:
	return ["NORMAL", "WARM", "HOT", "ON FIRE"][clampi(value, 0, 3)]

static func cluster_bonus(count: int) -> int:
	if count >= 11:
		return 1500
	if count >= 7:
		return 750
	if count >= 4:
		return 300
	if count >= 2:
		return 100
	return 0

static func base_charge(count: int) -> int:
	if count >= 11:
		# The 11-piece award starts at 35. Very large jackpots keep growing slowly, so a
		# 100+ piece cluster can produce multiple stored charges in one event.
		return 35 + int((count - 11) / 5) * 5
	if count >= 7:
		return 25
	if count >= 4:
		return 15
	if count >= 2:
		return 8
	return 5

func _on_main_connected(piece_ids: Array, source: int) -> void:
	if network.is_client():
		return
	award_connection(piece_ids, source)

func _on_loose_connected(piece_count: int, member_ids: Array, source: int) -> void:
	if network.is_client():
		return
	_grant(piece_count, source, member_ids, "LOOSE")

func award_connection(piece_ids: Array, source: int) -> Dictionary:
	if network.is_client():
		return {}
	var fresh := []
	for id in piece_ids:
		if id is int and id >= 0 and id < manager.pieces.size() and manager.is_in_main_puzzle(id) and not _awarded_ids.has(id):
			fresh.append(id)
			_awarded_ids[id] = true
	if fresh.is_empty():
		return {}
	return _grant(fresh.size(), source, fresh, "MAIN")

func _on_first_try_started(piece_id: int) -> void:
	if network.is_client():
		return
	_candidate = piece_id
	_candidate_key = key_for(manager.acting_player)
	_candidate_counted = false

# The drop is resolved. If the piece was dropped near another piece and did not join, the streak ends there.
func _on_first_try_ended(_piece_id: int, missed: bool) -> void:
	if network.is_client():
		return
	var was_counted := _candidate_counted
	var owner := ledger(_candidate_key)
	_candidate = -1
	_candidate_counted = false
	if missed and not was_counted and owner.streak > 0:
		owner.streak = 0
		revision += 1
		state_changed.emit()
		network.announce_scoring(to_sync_dict(), {})

func _grant(count: int, source: int, piece_ids: Array, kind: String) -> Dictionary:
	var key := key_for(manager.acting_player) # the player this award belongs to
	var mine := ledger(key)
	var previous_tier := tier_for(mine.streak)
	# a first-try placement extends the player's streak before it is paid, so it earns the longer streak's multiplier
	var first_try := _candidate >= 0 and not _candidate_counted and _candidate_key == key and piece_ids.has(_candidate)
	if first_try:
		_candidate_counted = true
		mine.streak += 1
		mine.best_streak = maxi(mine.best_streak, mine.streak)
	var current_tier := tier_for(mine.streak)
	var multiplier_now := streak_multiplier(mine.streak)
	var score_gain := roundi(float(count * 100 + cluster_bonus(count)) * multiplier_now)
	var efficiency := 0.5 if source == PuzzleManager.ConnectionSource.POWER else 1.0
	var charge_gain := roundi(float(base_charge(count)) * CHARGE_MULTIPLIERS[current_tier] * efficiency * CHARGE_GAIN_SCALE)
	score += score_gain
	var gained_charges := _add_charge(mine, charge_gain)
	var completed_anchors := kind == "MAIN" and not anchors_rewarded and manager.anchored_corner_count() == 4
	if completed_anchors:
		anchors_rewarded = true
		mine.power_charges += 1 # to the player who anchored the last corner
	revision += 1
	var event := {
		"piece_ids": piece_ids, "piece_count": count, "source": source, "kind": kind, "player": key,
		"score_gain": score_gain, "charge_gain": charge_gain, "charges_gained": gained_charges,
		"combo_before": previous_tier, "combo_after": current_tier, "anchors_completed": completed_anchors,
		"first_try": first_try, "streak": mine.streak, "multiplier": multiplier_now
	}
	state_changed.emit()
	awarded.emit(event)
	if completed_anchors:
		anchors_completed.emit(key)
	if current_tier > previous_tier and key == local_key():
		tier_rose.emit(current_tier)
	network.announce_scoring(to_sync_dict(), event)
	return event

# Spends one of the player's stored Power Charges (the local player's if none is named). Host and solo only.
func spend_power_charge(player_id: int = -1) -> bool:
	var mine := ledger(local_key() if player_id < 0 else key_for(player_id))
	if network.is_client() or mine.power_charges <= 0:
		return false
	mine.power_charges -= 1
	revision += 1
	state_changed.emit()
	network.announce_scoring(to_sync_dict(), {})
	return true

func reconcile_legacy_anchors() -> void:
	if _legacy_anchors_unset and manager.anchored_corner_count() == 4:
		anchors_rewarded = true
	_legacy_anchors_unset = false

func _add_charge(mine: Ledger, amount: int) -> int:
	var total := mine.charge + maxi(0, amount)
	var gained := int(total / 100)
	mine.power_charges += gained
	mine.charge = total % 100
	return gained

func _on_remote_sync(state: Dictionary, event: Dictionary) -> void:
	if not network.is_client() or int(state.get("revision", -1)) <= revision:
		return
	_apply_shared(state)
	# only this player's own buildup is taken from the host's picture; it starts empty if the host has none for them
	var mine := local_key()
	var ledgers = state.get("ledgers", {})
	var own = ledgers.get(mine, ledgers.get(str(mine), {})) if ledgers is Dictionary else {}
	_ledgers.clear()
	ledger(mine).load_dict(own if own is Dictionary else {})
	state_changed.emit()
	if not event.is_empty():
		awarded.emit(event)
		if bool(event.get("anchors_completed", false)):
			anchors_completed.emit(int(event.get("player", HOST_KEY)))
		if int(event.get("player", HOST_KEY)) == mine and int(event.get("combo_after", 0)) > int(event.get("combo_before", 0)):
			tier_rose.emit(int(event.combo_after))

# What is saved: the shared state plus the host's (or solo player's) own buildup, at the top level as before.
func to_dict() -> Dictionary:
	var data := _shared_dict()
	data.merge(ledger(HOST_KEY).to_dict())
	return data

# What the host sends after a change: the shared state plus every player's buildup (each client uses only its own).
func to_sync_dict() -> Dictionary:
	var data := _shared_dict()
	var ledgers := {}
	for key in _ledgers:
		ledgers[key] = _ledgers[key].to_dict()
	data["ledgers"] = ledgers
	return data

func _shared_dict() -> Dictionary:
	var ids := _awarded_ids.keys()
	ids.sort()
	return {"score": score, "revision": revision, "awarded_ids": ids, "anchors_rewarded": anchors_rewarded}

# Loads a save or a host's puzzle config. `adopt_host_ledger` is false for a joining player: the buildup in a host's
# config is the host's, not theirs.
func from_dict(data: Dictionary, adopt_host_ledger: bool = true) -> void:
	_apply_shared(data)
	if adopt_host_ledger:
		_ledgers.clear()
		ledger(HOST_KEY).load_dict(data)
	else:
		_ledgers.clear()
	state_changed.emit()

func _apply_shared(data: Dictionary) -> void:
	score = maxi(0, int(data.get("score", 0)))
	revision = maxi(0, int(data.get("revision", 0)))
	anchors_rewarded = bool(data.get("anchors_rewarded", false))
	_legacy_anchors_unset = not data.has("anchors_rewarded")
	_awarded_ids.clear()
	var ids = data.get("awarded_ids", [])
	if ids is Array:
		for id in ids:
			var value := int(id)
			if value >= 0 and value < manager.pieces.size():
				_awarded_ids[value] = true
