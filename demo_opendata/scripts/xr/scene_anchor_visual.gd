extends StaticBody3D

@onready var label: Label3D = $SemanticLabel
var anchor: XRAnchor3D
var surface_layer := 1 << 23
var tracked_seconds := 0.0
var has_located_pose := false
var located_pose := Transform3D.IDENTITY


func _ready() -> void:
	collision_layer = 0
	set_physics_process(false)


func setup_scene(spatial_entity: Object) -> void:
	var semantic_labels := _get_semantic_labels(spatial_entity)
	for semantic in semantic_labels:
		if semantic.to_upper() == "FLOOR":
			add_to_group("xr_room_floors")
		if "WALL" in semantic.to_upper():
			surface_layer |= XRRoomPlacementBody3D.WALL_LAYER
			add_to_group("xr_room_walls")
	if not semantic_labels.is_empty():
		label.text = semantic_labels[0]

	var collision_shape := _create_entity_node(spatial_entity, "create_collision_shape")
	if collision_shape != null:
		if collision_shape is CollisionShape3D and collision_shape.shape is ConcavePolygonShape3D:
			collision_shape.shape.backface_collision = true
		collision_shape.set_deferred("disabled", false)
		add_child.call_deferred(collision_shape)
	anchor = get_parent() as XRAnchor3D
	if anchor != null:
		# Keep the last located transform during short tracking gaps. An unlocated
		# XRAnchor may otherwise leave a wall collider at the world origin.
		top_level = true
		set_physics_process(true)
	else:
		collision_layer = surface_layer # Desktop fixtures have no XR tracker.


func _physics_process(delta: float) -> void:
	var xr := XRServer.primary_interface
	update_tracking(anchor != null and anchor.get_has_tracking_data(), delta, xr == null or XRSurfacePlacement.is_head_tracked())


func update_tracking(tracked: bool, delta: float, world_tracked := true) -> void:
	if not world_tracked:
		collision_layer = 0
		return
	var tracking_frame := XRServer.get_world_origin() * XRServer.get_reference_frame()
	if tracked:
		tracked_seconds += delta
		if tracked_seconds >= 0.15:
			located_pose = tracking_frame.affine_inverse() * (anchor.global_transform if anchor != null else global_transform)
			has_located_pose = true
	else:
		tracked_seconds = 0.0
	# Walls are static. Losing an individual anchor must not open a hole in the
	# room. Keep its located pose, rebased when the user's reference frame changes.
	if has_located_pose:
		global_transform = tracking_frame * located_pose
	collision_layer = surface_layer if has_located_pose else 0


func _get_semantic_labels(spatial_entity: Object) -> PackedStringArray:
	var result := PackedStringArray()
	if spatial_entity == null or not spatial_entity.has_method("get_semantic_labels"):
		return result

	var labels_value: Variant = spatial_entity.call("get_semantic_labels")
	if labels_value is PackedStringArray:
		return labels_value as PackedStringArray
	if labels_value is Array:
		for item in labels_value:
			result.append(str(item))

	return result


func _create_entity_node(spatial_entity: Object, method_name: String) -> Node:
	if spatial_entity == null or not spatial_entity.has_method(method_name):
		return null

	var node_value: Variant = spatial_entity.call(method_name)
	return node_value as Node if node_value is Node else null
