class_name IndustrialQRController
extends Node3D

signal info_viewer_selected(viewer: IndustrialModelViewer3D)

@export var qr_mode_enabled := true
@export var qr_spawn_multiple_models := true
@export var qr_reposition_existing := false
@export var auto_anchor_placed_models := true
@export_range(0, 10000, 100) var qr_detection_cooldown_msec := 1800
@export var qr_spawn_global_offset := Vector3(0.0, 0.04, 0.0)
@export var qr_reacquire_delays := PackedFloat32Array([0.2, 1.0, 2.5])
@export_group("Scene References")
@export var catalog_node_path: NodePath
@export var info_panel_node_path: NodePath
@export var primary_model_viewer_node_path: NodePath

@onready var qr_marker_manager: IndustrialQRMarkerManager = get_node_or_null("QRMarkerManager") as IndustrialQRMarkerManager
@onready var qr_model_registry = get_node_or_null("QRModelRegistry")
@onready var industrial_catalog: IndustrialCatalog = get_node_or_null(catalog_node_path) as IndustrialCatalog
@onready var info_panel: InfoPanel3D = get_node_or_null(info_panel_node_path) as InfoPanel3D
@onready var primary_model_viewer: IndustrialModelViewer3D = get_node_or_null(primary_model_viewer_node_path) as IndustrialModelViewer3D

var catalog_is_ready := false
var pending_qr_event: Dictionary = {}
var qr_anchored_keys: Dictionary = {}
var qr_last_detection_msec: Dictionary = {}


func _ready() -> void:
	_connect_marker_manager()


func set_catalog_ready() -> bool:
	catalog_is_ready = true
	var handled_pending_qr: bool = _process_pending_qr_event()
	_schedule_qr_reacquire()
	return handled_pending_qr or not qr_last_detection_msec.is_empty()


func _connect_marker_manager() -> void:
	if qr_marker_manager == null:
		return

	if not qr_marker_manager.qr_marker_detected.is_connected(_on_qr_marker_detected):
		qr_marker_manager.qr_marker_detected.connect(_on_qr_marker_detected)


func _on_qr_marker_detected(payload: String, marker_transform: Transform3D, tracker_name: StringName) -> void:
	if not qr_mode_enabled:
		return

	if not catalog_is_ready:
		pending_qr_event = {
			"payload": payload,
			"marker_transform": marker_transform,
			"tracker_name": tracker_name,
		}
		return

	_apply_qr_marker(payload, marker_transform, tracker_name)


func _schedule_qr_reacquire() -> void:
	if not qr_mode_enabled:
		return
	if qr_marker_manager == null:
		return

	qr_marker_manager.force_reacquire()
	for delay in qr_reacquire_delays:
		_reacquire_qr_after_delay(float(delay))


func _reacquire_qr_after_delay(delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	if not is_inside_tree():
		return
	if qr_marker_manager != null:
		qr_marker_manager.force_reacquire()


func _process_pending_qr_event() -> bool:
	if pending_qr_event.is_empty():
		return false

	var payload: String = str(pending_qr_event.get("payload", ""))
	var marker_transform_value: Variant = pending_qr_event.get("marker_transform", Transform3D.IDENTITY)
	var tracker_name_value: Variant = pending_qr_event.get("tracker_name", StringName())
	pending_qr_event.clear()

	if marker_transform_value is Transform3D:
		_apply_qr_marker(payload, marker_transform_value as Transform3D, StringName(tracker_name_value))
		return true

	return false


func _apply_qr_marker(payload: String, marker_transform: Transform3D, tracker_name: StringName) -> void:
	if industrial_catalog == null:
		return
	if marker_transform == Transform3D.IDENTITY:
		if qr_marker_manager != null:
			qr_marker_manager.force_reacquire()
		return

	var model_data: Dictionary = industrial_catalog.find_model_by_qr_payload(payload)
	if model_data.is_empty():
		return

	var model_id: String = str(model_data.get("id", ""))
	if model_id == "":
		return

	var qr_key: String = _get_qr_instance_key(payload, tracker_name)
	if not qr_reposition_existing and qr_model_registry.has_instance(qr_key):
		return
	if _is_qr_detection_on_cooldown(qr_key):
		return

	qr_last_detection_msec[qr_key] = Time.get_ticks_msec()
	_show_qr_model_info(model_data)

	if qr_spawn_multiple_models:
		var qr_viewer: IndustrialModelViewer3D = _get_or_create_qr_model_viewer(qr_key)
		if qr_viewer == null:
			return
		_set_and_place_qr_viewer(qr_viewer, model_data, marker_transform, qr_key, payload, tracker_name)
		return

	if primary_model_viewer == null:
		return
	_set_and_place_qr_viewer(primary_model_viewer, model_data, marker_transform, qr_key, payload, tracker_name)


func _set_and_place_qr_viewer(
	viewer: IndustrialModelViewer3D,
	model_data: Dictionary,
	marker_transform: Transform3D,
	qr_key: String,
	payload: String,
	tracker_name: StringName
) -> void:
	if viewer is IndustrialQRModelInstance3D:
		(viewer as IndustrialQRModelInstance3D).set_from_qr_marker(
			model_data,
			marker_transform,
			qr_spawn_global_offset,
			get_viewport().get_camera_3d()
		)
	else:
		viewer.set_model_data(model_data)
		IndustrialQRModelInstance3D.place_viewer_from_marker(
			viewer,
			model_data,
			marker_transform,
			qr_spawn_global_offset,
			get_viewport().get_camera_3d()
		)

	if bool(model_data.get("qr_anchor_on_detect", true)):
		_create_qr_model_spatial_anchor(qr_key, model_data, payload, tracker_name, viewer)


func _get_or_create_qr_model_viewer(qr_key: String) -> IndustrialModelViewer3D:
	if qr_model_registry == null:
		push_error("IndustrialQRController requires a QRModelRegistry child node.")
		return null

	var viewer: IndustrialModelViewer3D = qr_model_registry.get_or_create_model_viewer(qr_key)
	if viewer != null:
		if not viewer.has_meta("info_connected"):
			viewer.set_meta("info_connected", true)
			viewer.hotspot_selected.connect(func(info: Dictionary):
				info_panel.set_content(str(info.get("title", "Componente")), str(info.get("body", "")))
				info_viewer_selected.emit(viewer))
		info_viewer_selected.emit(viewer)
	return viewer


func _show_qr_model_info(model_data: Dictionary) -> void:
	if industrial_catalog == null:
		return

	var title: String = str(model_data.get("title", "Catalog item"))
	if info_panel != null:
		info_panel.set_content_values(title, industrial_catalog.get_model_info_values(model_data))

	var context_provider := get_tree().get_first_node_in_group("xr_context_provider") as XRContextProvider
	if context_provider != null:
		context_provider.set_selected_model(model_data)


func _create_qr_model_spatial_anchor(qr_key: String, model_data: Dictionary, payload: String, tracker_name: StringName, viewer: IndustrialModelViewer3D) -> void:
	if not auto_anchor_placed_models:
		return
	if qr_anchored_keys.has(qr_key):
		return

	var scene_services := get_tree().get_first_node_in_group("xr_scene_services") as XRRoot3D
	if scene_services == null:
		return

	var model_id: String = str(model_data.get("id", ""))
	scene_services.create_spatial_anchor(
		viewer.global_transform,
		{
			"type": "industrial_model_qr",
			"model_id": model_id,
			"title": str(model_data.get("title", model_id)),
			"qr_payload": payload,
			"qr_tracker": str(tracker_name),
			"created_at": Time.get_datetime_string_from_system(true),
		}
	)
	qr_anchored_keys[qr_key] = true


func _is_qr_detection_on_cooldown(qr_key: String) -> bool:
	var last_detection: int = int(qr_last_detection_msec.get(qr_key, 0))
	return last_detection > 0 and Time.get_ticks_msec() - last_detection < qr_detection_cooldown_msec


func _get_qr_instance_key(payload: String, tracker_name: StringName) -> String:
	var tracker_text: String = str(tracker_name)
	if tracker_text != "":
		return tracker_text

	return payload.strip_edges().to_lower()
