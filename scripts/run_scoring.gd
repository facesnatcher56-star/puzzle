class_name RunScoring
extends RefCounted

# One shared run ledger. Only the solo game or host turns PuzzleManager events into rewards.
# Clients apply the host's serialized state and event; piece snapshots never grant rewards.
signal state_changed
signal awarded(event: Dictionary)
signal tier_rose(tier: int)
signal anchors_completed

enum Tier { NORMAL, WARM, HOT, ON_FIRE }

const SCORE_MULTIPLIERS := [1.0, 1.25, 1.5, 2.0]
const CHARGE_MULTIPLIERS := [1.0, 1.1, 1.2, 1.35]

var manager: PuzzleManager
var network: NetworkSession
var score := 0
var charge := 0
var power_charges := 0
var combo_progress := 0
var revision := 0
var anchors_rewarded := false
var _awarded_ids := {}
var _legacy_anchors_unset := false

func setup(p_manager: PuzzleManager, p_network: NetworkSession) -> void:
	manager = p_manager
	network = p_network
	manager.main_puzzle_connected.connect(_on_main_connected)
	manager.loose_puzzle_connected.connect(_on_loose_connected)
	manager.failed_connection_attempt.connect(_on_failed_attempt)
	network.scoring_sync_received.connect(_on_remote_sync)

func reset() -> void:
	score = 0
	charge = 0
	power_charges = 0
	combo_progress = 0
	revision = 0
	anchors_rewarded = false
	_legacy_anchors_unset = false
	_awarded_ids.clear()
	state_changed.emit()

func tier() -> int:
	if combo_progress >= 10:
		return Tier.ON_FIRE
	if combo_progress >= 6:
		return Tier.HOT
	if combo_progress >= 3:
		return Tier.WARM
	return Tier.NORMAL

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

static func combo_gain(count: int) -> int:
	if count >= 7:
		return 4
	if count >= 4:
		return 3
	if count >= 2:
		return 2
	return 1

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

func _grant(count: int, source: int, piece_ids: Array, kind: String) -> Dictionary:
	var previous_tier := tier()
	var score_gain := roundi(float(count * 100 + cluster_bonus(count)) * SCORE_MULTIPLIERS[previous_tier])
	var efficiency := 0.5 if source == PuzzleManager.ConnectionSource.POWER else 1.0
	var charge_gain := roundi(float(base_charge(count)) * CHARGE_MULTIPLIERS[previous_tier] * efficiency)
	score += score_gain
	var gained_charges := _add_charge(charge_gain)
	combo_progress += combo_gain(count)
	var completed_anchors := kind == "MAIN" and not anchors_rewarded and manager.anchored_corner_count() == 4
	if completed_anchors:
		anchors_rewarded = true
		power_charges += 1
	revision += 1
	var event := {
		"piece_ids": piece_ids, "piece_count": count, "source": source, "kind": kind,
		"score_gain": score_gain, "charge_gain": charge_gain, "charges_gained": gained_charges,
		"combo_before": previous_tier, "combo_after": tier(), "anchors_completed": completed_anchors
	}
	state_changed.emit()
	awarded.emit(event)
	if completed_anchors:
		anchors_completed.emit()
	if tier() > previous_tier:
		tier_rose.emit(tier())
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

func _on_failed_attempt() -> void:
	if network.is_client() or combo_progress == 0:
		return
	combo_progress -= 1
	revision += 1
	state_changed.emit()
	network.announce_scoring(to_dict(), {})

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
		"combo_progress": combo_progress, "revision": revision, "awarded_ids": ids,
		"anchors_rewarded": anchors_rewarded}

func from_dict(data: Dictionary) -> void:
	score = maxi(0, int(data.get("score", 0)))
	charge = clampi(int(data.get("charge", 0)), 0, 99)
	power_charges = maxi(0, int(data.get("power_charges", 0)))
	combo_progress = maxi(0, int(data.get("combo_progress", 0)))
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
