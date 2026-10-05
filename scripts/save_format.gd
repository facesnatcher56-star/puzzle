class_name SaveFormat
extends RefCounted

# Display text for saved puzzles and collection entries.

const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

static func _local_time(stamp: int) -> Dictionary:
	return Time.get_datetime_dict_from_unix_time(stamp + int(Time.get_time_zone_from_system().bias) * 60)

static func format_stamp(stamp: int) -> String:
	var local := _local_time(stamp)
	var hour12: int = (local.hour + 11) % 12 + 1
	return "%s %d, %d  %d:%02d %s" % [MONTHS[local.month - 1], local.day, local.year, hour12, local.minute, "AM" if local.hour < 12 else "PM"]

static func format_time(milliseconds: int) -> String:
	var seconds := milliseconds / 1000
	if seconds >= 3600:
		return "%d:%02d:%02d" % [seconds / 3600, (seconds / 60) % 60, seconds % 60]
	return "%d:%02d" % [seconds / 60, seconds % 60]

static func title(saved: Dictionary) -> String:
	var saved_image := str(saved.get("image_id", ""))
	return "Emberbound" if saved_image == "" else "Random  •  " + saved_image.capitalize()

static func detail(saved: Dictionary) -> String:
	var placed := 0
	for snap in saved.pieces:
		if snap.on_table:
			placed += 1
	var seconds := int(saved.get("elapsed_ms", 0)) / 1000
	var text := "%d of %d placed  •  %d:%02d played" % [placed, saved.pieces.size(), seconds / 60, seconds % 60]
	var stamp := int(saved.get("saved_at", 0))
	if stamp > 0:
		var local := _local_time(stamp)
		var hour12: int = (local.hour + 11) % 12 + 1
		text += "  •  %s %d, %d:%02d %s" % [MONTHS[local.month - 1], local.day, hour12, local.minute, "AM" if local.hour < 12 else "PM"]
	return text
