class_name IndustrialQRMarkerManager
extends Node3D

signal qr_marker_detected(payload: String, marker_transform: Transform3D, tracker_name: StringName)

@export var enabled := true
@export var emit_updates := false
@export var debug_log := false
@export_range(0.0, 5.0, 0.1) var reacquire_poll_seconds := 0.6
@export var pose_names: PackedStringArray = PackedStringArray(["default", "root"])

var tracked_payloads: Dictionary = {}
var poll_accumulator := 0.0


func _ready() -> void:
	if not enabled:
		return

	_connect_xr_server_signals()
	call_deferred("_process_existing_trackers")
	set_process(reacquire_poll_seconds > 0.0)


func _exit_tree() -> void:
	_disconnect_xr_server_signals()
	tracked_payloads.clear()


func _process(delta: float) -> void:
	poll_accumulator += delta
	if poll_accumulator < reacquire_poll_seconds:
		return

	poll_accumulator = 0.0
	_process_existing_trackers(true)


func force_reacquire(clear_cache := true) -> void:
	if clear_cache:
		tracked_payloads.clear()
	poll_accumulator = 0.0
	_process_existing_trackers(false)


func _connect_xr_server_signals() -> void:
	if not XRServer.tracker_added.is_connected(_on_tracker_added):
		XRServer.tracker_added.connect(_on_tracker_added)
	if not XRServer.tracker_updated.is_connected(_on_tracker_updated):
		XRServer.tracker_updated.connect(_on_tracker_updated)
	if not XRServer.tracker_removed.is_connected(_on_tracker_removed):
		XRServer.tracker_removed.connect(_on_tracker_removed)


func _disconnect_xr_server_signals() -> void:
	if XRServer.tracker_added.is_connected(_on_tracker_added):
		XRServer.tracker_added.disconnect(_on_tracker_added)
	if XRServer.tracker_updated.is_connected(_on_tracker_updated):
		XRServer.tracker_updated.disconnect(_on_tracker_updated)
	if XRServer.tracker_removed.is_connected(_on_tracker_removed):
		XRServer.tracker_removed.disconnect(_on_tracker_removed)


func _process_existing_trackers(is_update := false) -> void:
	var trackers: Dictionary = XRServer.get_trackers(XRServer.TRACKER_ANCHOR)
	for tracker_name in trackers.keys():
		_process_tracker(StringName(tracker_name), is_update)


func _on_tracker_added(tracker_name: StringName, tracker_type: int) -> void:
	if tracker_type & XRServer.TRACKER_ANCHOR == 0:
		return
	_process_tracker(tracker_name, false)


func _on_tracker_updated(tracker_name: StringName, tracker_type: int) -> void:
	if tracker_type & XRServer.TRACKER_ANCHOR == 0:
		return
	_process_tracker(tracker_name, true)


func _on_tracker_removed(tracker_name: StringName, tracker_type: int) -> void:
	if tracker_type & XRServer.TRACKER_ANCHOR == 0:
		return

	tracked_payloads.erase(tracker_name)


func _process_tracker(tracker_name: StringName, is_update: bool) -> void:
	if not enabled:
		return
	if is_update and not emit_updates and tracked_payloads.has(tracker_name):
		return

	var marker_tracker: OpenXRMarkerTracker = XRServer.get_tracker(tracker_name) as OpenXRMarkerTracker
	if marker_tracker == null:
		return
	if marker_tracker.marker_type != OpenXRSpatialComponentMarkerList.MARKER_TYPE_QRCODE:
		return

	var payload: String = _get_qr_payload(marker_tracker)
	if payload == "":
		return

	var marker_transforms: Array[Transform3D] = []
	if not _get_marker_transform(marker_tracker, marker_transforms):
		return
	var marker_transform: Transform3D = marker_transforms[0]

	tracked_payloads[tracker_name] = payload
	if debug_log:
		print("QR marker detected: ", payload)
	qr_marker_detected.emit(payload, marker_transform, tracker_name)


func _get_qr_payload(marker_tracker: OpenXRMarkerTracker) -> String:
	var data: Variant = marker_tracker.get_marker_data()
	if data is String:
		return str(data).strip_edges()
	if data is PackedByteArray:
		return (data as PackedByteArray).get_string_from_utf8().strip_edges()

	return ""


func _get_marker_transform(marker_tracker: OpenXRMarkerTracker, result: Array[Transform3D]) -> bool:
	result.clear()
	for pose_name in pose_names:
		var pose_key := StringName(pose_name)
		if not marker_tracker.has_pose(pose_key):
			continue

		var pose: XRPose = marker_tracker.get_pose(pose_key)
		if pose != null and pose.has_tracking_data:
			result.append(pose.get_adjusted_transform())
			return true

	return false
