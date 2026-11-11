class_name XRSurfacePlacement
extends RefCounted


static func get_source_transform(source_node: Node3D, camera: Camera3D, fallback_position := Vector3(0.0, 1.4, 0.0)) -> Transform3D:
	if source_node != null and is_instance_valid(source_node):
		var ray := source_node.get_node_or_null("FunctionPointer/RayCast") as Node3D
		if ray != null:
			return ray.global_transform
		return source_node.global_transform
	if camera != null:
		return camera.global_transform
	return Transform3D(Basis.IDENTITY, fallback_position)


## True while the headset is spatially tracked. Do NOT use
## XRInterface.get_tracking_status(): the OpenXR module never updates that
## value (tracking_state is never assigned), so it never reports
## XR_NORMAL_TRACKING on Quest. The head tracker's pose is the reliable
## signal.
static func is_head_tracked() -> bool:
	var head := XRServer.get_tracker("head") as XRPositionalTracker
	if head == null or not head.has_pose("default"):
		return false
	var pose := head.get_pose("default")
	return pose != null and pose.has_tracking_data


static func pointer_hand(pointer: Node) -> String:
	var node := pointer
	while node != null:
		if node.is_in_group("left_hand_controller"):
			return "left"
		node = node.get_parent()
	return "right"


static func drag_depth(initial_depth: float, initial_reach: float, reach: float, gain := 3.0) -> float:
	return clampf(initial_depth + (reach - initial_reach) * gain, 0.15, 4.5)


static func get_target_point(
	world: World3D,
	source_transform: Transform3D,
	collision_layer: int,
	min_distance: float,
	max_distance: float,
	default_distance: float,
	floor_y: float,
	surface_min_up_dot: float
) -> Vector3:
	var ray_origin: Vector3 = source_transform.origin
	var ray_direction: Vector3 = (-source_transform.basis.z).normalized()
	var surface_hit: Variant = raycast_surface(
		world,
		ray_origin,
		ray_direction,
		collision_layer,
		min_distance,
		max_distance,
		surface_min_up_dot
	)
	if surface_hit is Dictionary:
		var hit: Dictionary = surface_hit as Dictionary
		var point_value: Variant = hit.get("point", null)
		if point_value is Vector3:
			return point_value as Vector3
	elif surface_hit is Vector3:
		return surface_hit as Vector3

	return get_floor_fallback_target_point(
		ray_origin,
		ray_direction,
		floor_y,
		min_distance,
		max_distance,
		default_distance
	)


static func get_target_info(
	world: World3D,
	source_transform: Transform3D,
	collision_layer: int,
	min_distance: float,
	max_distance: float,
	default_distance: float,
	floor_y: float,
	surface_min_up_dot: float
) -> Dictionary:
	var ray_origin: Vector3 = source_transform.origin
	var ray_direction: Vector3 = (-source_transform.basis.z).normalized()
	var surface_hit: Variant = raycast_surface(
		world,
		ray_origin,
		ray_direction,
		collision_layer,
		min_distance,
		max_distance,
		surface_min_up_dot
	)
	if surface_hit is Dictionary:
		var hit: Dictionary = surface_hit as Dictionary
		var point_value: Variant = hit.get("point", Vector3.ZERO)
		var normal_value: Variant = hit.get("normal", Vector3.UP)
		var surface_point: Vector3 = point_value if point_value is Vector3 else Vector3.ZERO
		var surface_normal: Vector3 = Vector3.UP
		if normal_value is Vector3:
			surface_normal = (normal_value as Vector3).normalized()
		return {
			"point": surface_point,
			"has_surface": true,
			"normal": surface_normal,
			"surface_kind": classify_surface(surface_normal, surface_point, floor_y),
			"is_room_wall": bool(hit.get("is_room_wall", false)),
		}
	elif surface_hit is Vector3:
		var legacy_point: Vector3 = surface_hit as Vector3
		return {
			"point": legacy_point,
			"has_surface": true,
			"normal": Vector3.UP,
			"surface_kind": classify_surface(Vector3.UP, legacy_point, floor_y),
		}

	var fallback_point: Vector3 = get_floor_fallback_target_point(
		ray_origin,
		ray_direction,
		floor_y,
		min_distance,
		max_distance,
		default_distance
	)

	return {
		"point": fallback_point,
		"has_surface": false,
		"normal": Vector3.UP,
		"surface_kind": "fallback",
	}


static func raycast_surface(
	world: World3D,
	ray_origin: Vector3,
	ray_direction: Vector3,
	collision_layer: int,
	min_distance: float,
	max_distance: float,
	surface_min_up_dot: float
) -> Variant:
	if world == null or ray_direction.length() <= 0.001:
		return null

	var ray_end: Vector3 = ray_origin + ray_direction.normalized() * max_distance
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end, collision_layer)
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null

	var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
	var hit_normal: Vector3 = hit.get("normal", Vector3.UP)
	var hit_distance: float = ray_origin.distance_to(hit_position)
	if hit_distance < min_distance or hit_distance > max_distance:
		return null
	if surface_min_up_dot > 0.0 and hit_normal.normalized().dot(Vector3.UP) < surface_min_up_dot:
		return null

	return {
		"point": hit_position,
		"normal": hit_normal.normalized(),
		"distance": hit_distance,
		"is_room_wall": hit.collider is CollisionObject3D and bool(hit.collider.collision_layer & XRRoomPlacementBody3D.WALL_LAYER),
	}


static func classify_surface(surface_normal: Vector3, surface_point: Vector3, floor_y: float) -> String:
	var normal: Vector3 = surface_normal.normalized()
	var up_dot: float = normal.dot(Vector3.UP)
	if up_dot >= 0.82:
		if absf(surface_point.y - floor_y) <= 0.18:
			return "floor"
		return "table"
	if absf(up_dot) <= 0.25:
		return "wall"
	return "surface"


static func get_floor_fallback_target_point(
	ray_origin: Vector3,
	ray_direction: Vector3,
	floor_y: float,
	min_distance: float,
	max_distance: float,
	default_distance: float
) -> Vector3:
	var target_distance: float = max_distance if ray_origin.y > floor_y else default_distance
	if ray_direction.y < -0.001:
		target_distance = (floor_y - ray_origin.y) / ray_direction.y

	target_distance = clampf(target_distance, min_distance, max_distance)
	var raw_target: Vector3 = ray_origin + ray_direction * target_distance
	return Vector3(raw_target.x, floor_y, raw_target.z)


static func orient_node_to_camera_yaw(node: Node3D, camera: Camera3D) -> void:
	if node == null or camera == null:
		return

	var to_camera: Vector3 = camera.global_position - node.global_position
	to_camera.y = 0.0
	if to_camera.length() <= 0.001:
		return

	var current_scale: Vector3 = node.global_transform.basis.get_scale()
	var readable_basis: Basis = Basis.looking_at(-to_camera.normalized(), Vector3.UP).scaled(current_scale)
	node.global_transform = Transform3D(readable_basis, node.global_position)


static func orient_node_to_surface_normal(node: Node3D, surface_normal: Vector3, camera: Camera3D) -> void:
	if node == null or surface_normal.length() <= 0.001:
		return

	var normal: Vector3 = surface_normal.normalized()
	normal.y = 0.0
	if normal.length() <= 0.001:
		orient_node_to_camera_yaw(node, camera)
		return

	var current_scale: Vector3 = node.global_transform.basis.get_scale()
	var readable_basis: Basis = Basis.looking_at(-normal.normalized(), Vector3.UP).scaled(current_scale)
	node.global_transform = Transform3D(readable_basis, node.global_position)


static func snap_height(surface_point: Vector3, snap_step: float) -> Vector3:
	if snap_step <= 0.0:
		return surface_point

	return Vector3(
		surface_point.x,
		roundf(surface_point.y / snap_step) * snap_step,
		surface_point.z
	)


static func get_node_root_from_surface_point(
	node: Node3D,
	surface_point: Vector3,
	floor_property_name := "model_floor_y",
	default_floor_offset := -0.43
) -> Vector3:
	var floor_offset := default_floor_offset
	if node != null:
		var floor_offset_value: Variant = node.get(floor_property_name)
		if floor_offset_value is float or floor_offset_value is int:
			floor_offset = float(floor_offset_value)

	return Vector3(surface_point.x, surface_point.y - floor_offset, surface_point.z)
