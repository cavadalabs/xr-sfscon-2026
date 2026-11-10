extends Node3D

const CARD_SCENE := preload("res://scenes/data_card.tscn")

@onready var data_source: DataSource = %DataSource
@onready var dataset_title: Label3D = %DatasetTitle
@onready var source_label: Label3D = %SourceLabel
@onready var card_slots: Node3D = %CardSlots
@onready var detail_name: Label3D = %DetailName
@onready var detail_value: Label3D = %DetailValue
@onready var detail_status: Label3D = %DetailStatus
@onready var detail_description: Label3D = %DetailDescription
@onready var data_request: HTTPRequest = %DataRequest
@onready var xr_ray: RayCast3D = %XRRay
@onready var xr_pointer: MeshInstance3D = %XRPointer

var cards: Array[Node] = []


func _ready() -> void:
	_try_start_xr()
	dataset_title.text = data_source.dataset_title
	getData()
	
func _on_timer_timeout() -> void:
	# Refresh data
	
	getData()
	pass # Replace with function body.
	
func getData() -> void:
	print('getData '+data_source.api_url)
	if data_source.use_live_data and data_request.request(data_source.api_url) == OK:
		return
	print('fallback')
	_show_fallback()	

func _on_data_request_completed(
		result: int,
		response_code: int,
		_headers: PackedStringArray,
		body: PackedByteArray,
) -> void:
	var items: Array[Dictionary] = []
	if result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300:
		items = data_source.items_from_api(body)

	if items.is_empty():
		_show_fallback()
	else:
		_show_items(items, false)


func _show_fallback() -> void:
	if data_source.use_live_data:
		push_warning("Live data is unavailable or invalid; using the local sample.")
	_show_items(data_source.load_fallback(), true)


func _show_items(items: Array[Dictionary], using_fallback: bool) -> void:
	for card in cards:
		card.queue_free()
	cards.clear()

	if using_fallback:
		source_label.text = "OFFLINE · LOCAL FALLBACK" if data_source.use_live_data else "LOCAL · SAMPLE"
		source_label.modulate = Color("f2b84b")
	else:
		source_label.text = "LIVE · OPEN DATA HUB"
		source_label.modulate = Color("57d68d")

	var slots := card_slots.get_children()
	for index in mini(items.size(), slots.size()):
		var card := CARD_SCENE.instantiate() as DataCard
		slots[index].add_child(card)
		card.configure(items[index])
		card.selected.connect(_show_details)
		cards.append(card)

	if items.size() > slots.size():
		push_warning("Only the first %d items fit in the dashboard." % slots.size())
	if items.is_empty():
		_show_empty_details()
	else:
		_show_details(items[0])


func _show_details(item: Dictionary) -> void:
	detail_name.text = str(item.get("name", "Unnamed item"))
	detail_value.text = "%s %s · maximum %s" % [
		str(item.get("value", 0)),
		str(item.get("unit", "")),
		str(item.get("capacity", 0)),
	]
	detail_status.text = str(item.get("status", "unknown")).to_upper()
	detail_description.text = str(item.get("description", "No description available."))


func _show_empty_details() -> void:
	source_label.text = "NO DATA"
	detail_name.text = "Nothing to show"
	detail_value.text = ""
	detail_status.text = ""
	detail_description.text = "Check the internet connection and data/fallback_parking.json."


func _try_start_xr() -> void:
	var openxr := XRServer.find_interface("OpenXR")
	if openxr == null or not openxr.is_initialized():
		return

	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in openxr.get_supported_environment_blend_modes():
		openxr.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
	else:
		push_warning("OpenXR is running, but alpha-blend passthrough is unavailable.")

	get_viewport().transparent_bg = true
	get_viewport().use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	xr_ray.enabled = true
	xr_pointer.visible = true


func _on_right_hand_button_pressed(action_name: String) -> void:
	# OpenXR emits "select" for a right-hand pinch (or a controller click fallback).
	if action_name != "select" or not xr_ray.is_colliding():
		return

	var collider := xr_ray.get_collider() as Node
	if collider != null and collider.get_parent().has_method("select"):
		collider.get_parent().call("select")
