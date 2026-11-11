extends IndustrialModelViewer3D
class_name IndustrialQRModelInstance3D

const XR_SURFACE_PLACEMENT := preload("res://scripts/xr/xr_surface_placement.gd")


func set_from_qr_marker(
	model_data: Dictionary,
	marker_transform: Transform3D,
	global_spawn_offset: Vector3,
	camera: Camera3D
) -> void:
	set_model_data(model_data)
	place_viewer_from_marker(self, model_data, marker_transform, global_spawn_offset, camera)


static func place_viewer_from_marker(
	viewer: Node3D,
	model_data: Dictionary,
	marker_transform: Transform3D,
	global_spawn_offset: Vector3,
	camera: Camera3D
) -> void:
	var marker_surface_point: Vector3 = marker_transform.origin + get_qr_spawn_offset(model_data, global_spawn_offset)
	viewer.global_position = XR_SURFACE_PLACEMENT.get_node_root_from_surface_point(viewer, marker_surface_point)
	XR_SURFACE_PLACEMENT.orient_node_to_camera_yaw(viewer, camera)

	var yaw_degrees: float = float(model_data.get("qr_spawn_yaw_deg", 0.0))
	if not is_zero_approx(yaw_degrees):
		viewer.rotate_y(deg_to_rad(yaw_degrees))


static func get_qr_spawn_offset(model_data: Dictionary, global_spawn_offset: Vector3) -> Vector3:
	var offset_value: Variant = model_data.get("qr_spawn_offset", global_spawn_offset)
	if offset_value is Vector3:
		return offset_value as Vector3
	if offset_value is Array:
		var offset_array: Array = offset_value as Array
		if offset_array.size() >= 3:
			return Vector3(float(offset_array[0]), float(offset_array[1]), float(offset_array[2]))

	return global_spawn_offset
