class_name RunScoring
extends RefCounted

# One shared run ledger. Only the solo game or host turns PuzzleManager events into rewards.
# Clients apply the host's serialized state and event; piece snapshots never grant rewards.
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
signal anchors_completed

enum Tier { NORMAL, WARM, HOT, ON_FIRE }

const STREAK_BASE := 1.12 # each first-try placement multiplies the next awards by this much more...
const STREAK_CAP := 20.0 # ...up to this
const TIER_STREAKS := [0, 3, 6, 10] # the streak at which each tier starts (the tier drives the flame, sounds and Charge)
const CHARGE_MULTIPLIERS := [1.0, 1.1, 1.2, 1.35]

var manager: PuzzleManager
var network: NetworkSession
var score := 0
var charge := 0
var power_charges := 0
var streak := 0
var best_streak := 0
var revision := 0
var anchors_rewarded := false
var _awarded_ids := {}
var _legacy_anchors_unset := false
var _candidate := -1 # the solo piece whose first-try drop is being resolved
var _candidate_counted := false

func setup(p_manager: PuzzleManager, p_network: NetworkSession) -> void:
	manager = p_manager
	network = p_network
	manager.main_puzzle_connected.connect(_on_main_connected)
	manager.loose_puzzle_connected.connect(_on_loose_connected)
	manager.first_try_started.connect(_on_first_try_started)
	manager.first_try_ended.connect(_on_first_try_ended)
	network.scoring_sync_received.connect(_on_remote_sync)

func reset() -> void:
	score = 0
	charge = 0
	power_charges = 0
	streak = 0
	best_streak = 0
	_candidate = -1
	_candidate_counted = false
	revision = 0
	anchors_rewarded = false
	_legacy_anchors_unset = false
	_awarded_ids.clear()
	state_changed.emit()

func tier() -> int:
	return tier_for(streak)

static func tier_for(streak_length: int) -> int:
	for i in range(TIER_STREAKS.size() - 1, 0, -1):
		if streak_length >= TIER_STREAKS[i]:
			return i
	return Tier.NORMAL

# The score and Charge multiplier of a streak: exponential, so a long unbroken run is worth a great deal.
static func streak_multiplier(streak_length: int) -> float:
	return minf(pow(STREAK_BASE, maxi(0, streak_length)), STREAK_CAP)

func multiplier() -> float:
	return streak_multiplier(streak)

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
	_candidate_counted = false

# The drop is resolved. If the piece was dropped near another piece and did not join, the streak ends there.
func _on_first_try_ended(_piece_id: int, missed: bool) -> void:
	if network.is_client():
		return
	var was_counted := _candidate_counted
	_candidate = -1
	_candidate_counted = false
	if missed and not was_counted and streak > 0:
		streak = 0
		revision += 1
		state_changed.emit()
		network.announce_scoring(to_dict(), {})

func _grant(count: int, source: int, piece_ids: Array, kind: String) -> Dictionary:
	var previous_tier := tier()
	# a first-try placement extends the streak before it is paid, so it earns the longer streak's multiplier
	var first_try := _candidate >= 0 and not _candidate_counted and piece_ids.has(_candidate)
	if first_try:
		_candidate_counted = true
		streak += 1
		best_streak = maxi(best_streak, streak)
	var current_tier := tier()
	var multiplier_now := multiplier()
	var score_gain := roundi(float(count * 100 + cluster_bonus(count)) * multiplier_now)
	var efficiency := 0.5 if source == PuzzleManager.ConnectionSource.POWER else 1.0
	var charge_gain := roundi(float(base_charge(count)) * CHARGE_MULTIPLIERS[current_tier] * efficiency)
	score += score_gain
	var gained_charges := _add_charge(charge_gain)
	var completed_anchors := kind == "MAIN" and not anchors_rewarded and manager.anchored_corner_count() == 4
	if completed_anchors:
		anchors_rewarded = true
		power_charges += 1
	revision += 1
	var event := {
		"piece_ids": piece_ids, "piece_count": count, "source": source, "kind": kind,
		"score_gain": score_gain, "charge_gain": charge_gain, "charges_gained": gained_charges,
		"combo_before": previous_tier, "combo_after": current_tier, "anchors_completed": completed_anchors,
		"first_try": first_try, "streak": streak, "multiplier": multiplier_now
	}
	state_changed.emit()
	awarded.emit(event)
	if completed_anchors:
		anchors_completed.emit()
	if current_tier > previous_tier:
		tier_rose.emit(current_tier)
	network.announce_scoring(to_dict(), event)
	return event

func spend_power_charge() -> bool:
	if network.is_client() or power_charges <= 0:
		return false
	power_charges -= 1
	revision += 1
	state_changed.emit()
	network.announce_scoring(to_dict(), {})
	return true

func reconcile_legacy_anchors() -> void:
	if _legacy_anchors_unset and manager.anchored_corner_count() == 4:
		anchors_rewarded = true
	_legacy_anchors_unset = false

func _add_charge(amount: int) -> int:
	var total := charge + maxi(0, amount)
	var gained := int(total / 100)
	power_charges += gained
	charge = total % 100
	return gained

func _on_remote_sync(state: Dictionary, event: Dictionary) -> void:
	if not network.is_client() or int(state.get("revision", -1)) <= revision:
		return
	from_dict(state)
	if not event.is_empty():
		awarded.emit(event)
		if bool(event.get("anchors_completed", false)):
			anchors_completed.emit()
		if int(event.get("combo_after", 0)) > int(event.get("combo_before", 0)):
			tier_rose.emit(int(event.combo_after))

func to_dict() -> Dictionary:
	var ids := _awarded_ids.keys()
	ids.sort()
	return {"score": score, "charge": charge, "power_charges": power_charges,
		"streak": streak, "best_streak": best_streak, "revision": revision, "awarded_ids": ids,
		"anchors_rewarded": anchors_rewarded}

func from_dict(data: Dictionary) -> void:
	score = maxi(0, int(data.get("score", 0)))
	charge = clampi(int(data.get("charge", 0)), 0, 99)
	power_charges = maxi(0, int(data.get("power_charges", 0)))
	streak = maxi(0, int(data.get("streak", 0)))
	best_streak = maxi(streak, int(data.get("best_streak", 0)))
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
	state_changed.emit()
