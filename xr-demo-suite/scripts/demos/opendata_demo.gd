extends Node3D

signal back_requested

@onready var layout_controller: Node = $TechnicalNodes/OpenDataLayoutController
@onready var noi_map: NoiMap3D = $NoiMap
@onready var data_panel: DataPanel3D = $DataPanel
@onready var room_data_source: RoomDataSource = $TechnicalNodes/RoomDataSource
@onready var open_data_hub_client: OpenDataHubClient = $TechnicalNodes/OpenDataHubClient

var rooms: Array = []
var selected_room_id := ""


func _ready() -> void:
	_load_rooms()


func _on_layout_back_requested() -> void:
	open_data_hub_client.stop_polling()
	back_requested.emit()


func _load_rooms() -> void:
	rooms = room_data_source.load_rooms()
	_refresh_room_views()

	if not rooms.is_empty():
		_on_room_selected(rooms[0])

	open_data_hub_client.start_polling(rooms)


func _on_room_selected(room_data: Dictionary) -> void:
	selected_room_id = str(room_data.get("id", ""))

	noi_map.set_selected_room_id(selected_room_id)
	data_panel.set_room_data(room_data)

	var context_provider := get_tree().get_first_node_in_group("xr_context_provider") as XRContextProvider
	if context_provider != null:
		context_provider.set_selected_room(room_data)


func _on_live_measurements_updated(updates: Dictionary) -> void:
	for index in range(rooms.size()):
		var room: Dictionary = (rooms[index] as Dictionary).duplicate(true)
		var station_code: String = str(room.get("station_code", ""))
		room.merge({"temperature": null, "humidity": null, "co2": null,
			"measurements": {}, "status": "unavailable", "last_updated": ""}, true)
		room.merge(updates.get(station_code, {}), true)
		rooms[index] = room

	_refresh_room_views()
	_refresh_selected_room()


func _refresh_room_views() -> void:
	noi_map.set_rooms(rooms)


func _refresh_selected_room() -> void:
	for room in rooms:
		if room is Dictionary and str(room.get("id", "")) == selected_room_id:
			_on_room_selected(room)
			return
