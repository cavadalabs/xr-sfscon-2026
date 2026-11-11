class_name RoomDataSource
extends Node

@export_file("*.json") var room_data_path := ""
@export var room_city_filter := "bolzano"
@export_range(1, 8, 1) var max_visible_rooms := 2


func load_rooms() -> Array:
	var loaded_rooms = ApiClient.load_json_file(room_data_path)
	if not loaded_rooms is Array:
		return []

	return _filter_rooms(loaded_rooms)


func _filter_rooms(source_rooms: Array) -> Array:
	var filtered_rooms: Array = []
	var city_filter := room_city_filter.to_lower()

	for room in source_rooms:
		if room is Dictionary and str(room.get("city", "")).to_lower() == city_filter:
			filtered_rooms.append(room)

	return filtered_rooms.slice(0, max_visible_rooms)
