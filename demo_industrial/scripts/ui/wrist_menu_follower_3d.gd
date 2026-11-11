extends Node
class_name WristMenuFollower3D

@export_group("Scene References")
@export var menu_node_path: NodePath
@export var wrist_pose_node_path: NodePath
@export var fallback_pose_node_path: NodePath

@export_group("Pose")
@export var wrist_offset := Vector3(0.02, 0.14, -0.08)
@export var fallback_offset := Vector3(-0.42, -0.12, -0.85)
@export var menu_scale := 0.34
@export_range(0.01, 1.0, 0.01) var position_smoothing := 0.16
@export_range(0.01, 1.0, 0.01) var rotation_smoothing := 0.12

@export_group("XR Input")
@export var wrist_tracker_path := "/user/hand_tracker/left"
@export_range(0.0, 0.2, 0.005) var wrist_tracking_poll_interval_seconds := 0.05
@export var controller_open_buttons: PackedStringArray = PackedStringArray(["by_button", "menu_button"])

var menu: WristMenu3D
var wrist_pose: Node3D
var fallback_pose: Node3D
var wrist_anchor: Node3D
var wrist_controller: XRController3D
var has_smoothed_transform := false
var smoothed_position := Vector3.ZERO
var smoothed_rotation := Quaternion.IDENTITY
var wrist_tracking_poll_accumulator := 0.0
var is_wrist_tracking_cached := false


func _ready() -> void:
	_resolve_scene_nodes()
	_bind_xr_nodes()
	if menu != null:
		menu.top_level = true


func _process(delta: float) -> void:
	if menu == null or not is_instance_valid(menu):
		return

	if wrist_anchor == null or not is_instance_valid(wrist_anchor):
		_bind_xr_nodes()

	if _has_wrist_tracking(delta):
		_update_wrist_transform(delta)
	elif not has_smoothed_transform:
		_update_fallback_transform(delta)


func _resolve_scene_nodes() -> void:
	menu = _get_node_from_path(menu_node_path) as WristMenu3D
	wrist_pose = _get_node_from_path(wrist_pose_node_path) as Node3D
	fallback_pose = _get_node_from_path(fallback_pose_node_path) as Node3D


func _get_node_from_path(node_path: NodePath) -> Node:
	if String(node_path).is_empty():
		return null

	return get_node_or_null(node_path)


func _bind_xr_nodes() -> void:
	wrist_anchor = get_tree().get_first_node_in_group("left_wrist_anchor") as Node3D
	var next_controller := get_tree().get_first_node_in_group("left_hand_controller") as XRController3D
	if next_controller == null:
		return

	wrist_controller = next_controller
	var callback := Callable(self, "_on_wrist_controller_button_pressed")
	if not wrist_controller.button_pressed.is_connected(callback):
		wrist_controller.button_pressed.connect(callback)


func _on_wrist_controller_button_pressed(button_name: String) -> void:
	if button_name not in controller_open_buttons:
		return
	if menu != null:
		menu.set_open(true)


func _update_wrist_transform(delta: float) -> void:
	var wrist_basis: Basis = wrist_anchor.global_transform.basis.orthonormalized()
	var offset := _get_wrist_offset()
	var target_position := wrist_anchor.global_position
	target_position += wrist_basis.x * offset.x
	target_position += Vector3.UP * offset.y
	target_position += wrist_basis.z * offset.z

	var camera := get_viewport().get_camera_3d()
	if camera != null:
		var camera_direction := camera.global_position - target_position
		if camera_direction.length() > 0.001:
			_apply_smoothed_transform(target_position, Basis.looking_at(-camera_direction.normalized(), Vector3.UP), delta)
			return

	_apply_smoothed_transform(target_position, wrist_basis, delta)


func _update_fallback_transform(delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var target_position: Vector3 = camera.global_transform * _get_fallback_offset()
	var camera_direction := camera.global_position - target_position
	if camera_direction.length() <= 0.001:
		return

	_apply_smoothed_transform(target_position, Basis.looking_at(-camera_direction.normalized(), Vector3.UP), delta)


func _has_wrist_tracking(delta: float) -> bool:
	if wrist_anchor == null or not is_instance_valid(wrist_anchor):
		is_wrist_tracking_cached = false
		return false

	wrist_tracking_poll_accumulator += delta
	if wrist_tracking_poll_interval_seconds <= 0.0 or wrist_tracking_poll_accumulator >= wrist_tracking_poll_interval_seconds:
		wrist_tracking_poll_accumulator = 0.0
		var tracker := XRServer.get_tracker(wrist_tracker_path) as XRHandTracker
		is_wrist_tracking_cached = tracker != null and tracker.has_tracking_data

	return is_wrist_tracking_cached


func _apply_smoothed_transform(target_position: Vector3, target_basis: Basis, delta: float) -> void:
	var target_rotation := target_basis.orthonormalized().get_rotation_quaternion()
	if not has_smoothed_transform:
		smoothed_position = target_position
		smoothed_rotation = target_rotation
		has_smoothed_transform = true
	else:
		var position_alpha := _frame_smoothing(position_smoothing, delta)
		var rotation_alpha := _frame_smoothing(rotation_smoothing, delta)
		smoothed_position = smoothed_position.lerp(target_position, position_alpha)
		smoothed_rotation = smoothed_rotation.slerp(target_rotation, rotation_alpha)

	menu.global_transform = Transform3D(Basis(smoothed_rotation).scaled(Vector3.ONE * _get_menu_scale()), smoothed_position)


func _frame_smoothing(value: float, delta: float) -> float:
	var clamped_value := clampf(value, 0.0, 1.0)
	return clampf(1.0 - pow(1.0 - clamped_value, delta * 60.0), 0.0, 1.0)


func _get_wrist_offset() -> Vector3:
	return wrist_pose.position if wrist_pose != null else wrist_offset


func _get_fallback_offset() -> Vector3:
	return fallback_pose.position if fallback_pose != null else fallback_offset


func _get_menu_scale() -> float:
	if wrist_pose == null:
		return menu_scale

	return maxf(wrist_pose.scale.x, 0.001)
