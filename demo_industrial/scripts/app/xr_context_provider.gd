class_name XRContextProvider
extends Node

var active_demo_id := ""
var selected_model: Dictionary = {}
var selected_room: Dictionary = {}


func set_active_demo(demo_id: String) -> void:
	active_demo_id = demo_id


func set_selected_model(model_data: Dictionary) -> void:
	selected_room.clear()
	selected_model = model_data.duplicate(true)


func set_selected_room(room_data: Dictionary) -> void:
	selected_model.clear()
	selected_room = room_data.duplicate(true)


func selection_label() -> String:
	if not selected_model.is_empty():
		return str(selected_model.get("title", selected_model.get("id", "Prodotto")))
	if not selected_room.is_empty():
		return str(selected_room.get("name", "Ambiente"))
	return ""


func clear_demo_context() -> void:
	active_demo_id = ""
	selected_model.clear()
	selected_room.clear()


func build_context(extra: Dictionary = {}) -> Dictionary:
	var context := {
		"active_demo_id": active_demo_id,
		"selected_model": selected_model,
		"selected_room": selected_room,
		"runtime_time": _build_time_context(),
	}
	context.merge(extra, true)
	if context.selected_room is Dictionary and not context.selected_room.is_empty():
		OpenDataHubClient.expire_measurements(context.selected_room)
	return context


func _build_time_context() -> Dictionary:
	var local_datetime: Dictionary = Time.get_datetime_dict_from_system(false)
	var utc_datetime: Dictionary = Time.get_datetime_dict_from_system(true)
	var timezone: Dictionary = Time.get_time_zone_from_system()
	return {
		"unix": int(Time.get_unix_time_from_system()),
		"local_datetime": _format_datetime(local_datetime),
		"utc_datetime": _format_datetime(utc_datetime),
		"timezone": timezone,
	}


func _format_datetime(datetime: Dictionary) -> String:
	return "%04d-%02d-%02d %02d:%02d:%02d" % [
		int(datetime.get("year", 0)),
		int(datetime.get("month", 0)),
		int(datetime.get("day", 0)),
		int(datetime.get("hour", 0)),
		int(datetime.get("minute", 0)),
		int(datetime.get("second", 0)),
	]
