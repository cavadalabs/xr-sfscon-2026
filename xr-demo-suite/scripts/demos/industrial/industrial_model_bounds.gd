class_name IndustrialModelBounds
extends Node

var bounds_cache: Dictionary = {}


func get_cached_bounds(model_data: Dictionary, model_path: String, anchor: Node3D, root_node: Node) -> AABB:
	var configured_bounds := _get_configured_bounds(model_data)
	if configured_bounds.size != Vector3.ZERO:
		return configured_bounds

	var ignore_names := _get_bounds_ignore_names(model_data)
	var cache_key := _get_bounds_cache_key(model_data, model_path, ignore_names)
	if bounds_cache.has(cache_key):
		return bounds_cache[cache_key] as AABB

	var bounds: AABB = _calculate_bounds(anchor, root_node, ignore_names)
	if bounds.size != Vector3.ZERO:
		bounds_cache[cache_key] = bounds
	return bounds


func _get_bounds_cache_key(model_data: Dictionary, model_path: String, ignore_names: PackedStringArray) -> String:
	var model_id := str(model_data.get("id", model_path))
	if model_id == "":
		model_id = model_path
	return "%s|%s" % [model_id, ",".join(ignore_names)]


func _get_bounds_ignore_names(model_data: Dictionary) -> PackedStringArray:
	var ignore_names := PackedStringArray()
	var ignore_value: Variant = model_data.get("bounds_ignore_contains", [])
	if ignore_value is Array:
		var ignore_array: Array = ignore_value as Array
		for item in ignore_array:
			var item_text: String = str(item).to_lower()
			if item_text != "":
				ignore_names.append(item_text)
	elif ignore_value is String:
		var single_item: String = str(ignore_value).to_lower()
		if single_item != "":
			ignore_names.append(single_item)

	return ignore_names


func _get_configured_bounds(model_data: Dictionary) -> AABB:
	var position_value: Variant = model_data.get("bounds_position", [])
	var size_value: Variant = model_data.get("bounds_size", [])
	if not position_value is Array or not size_value is Array:
		return AABB()

	var bounds_position := _array_to_vector3(position_value as Array)
	var bounds_size := _array_to_vector3(size_value as Array)
	if bounds_size == Vector3.ZERO:
		return AABB()

	return AABB(bounds_position, bounds_size)


func _array_to_vector3(values: Array) -> Vector3:
	if values.size() < 3:
		return Vector3.ZERO

	return Vector3(
		float(values[0]),
		float(values[1]),
		float(values[2])
	)


func _calculate_bounds(anchor: Node3D, root_node: Node, ignore_names: PackedStringArray) -> AABB:
	var has_bounds := false
	var bounds := AABB()
	var mesh_nodes: Array[Node] = root_node.find_children("*", "MeshInstance3D", true, false)
	for mesh_node in mesh_nodes:
		var mesh_instance: MeshInstance3D = mesh_node as MeshInstance3D
		if mesh_instance.mesh == null or _should_ignore_mesh(mesh_instance, anchor, ignore_names):
			continue

		var mesh_bounds: AABB = _mesh_bounds_in_anchor_space(anchor, mesh_instance)
		bounds = mesh_bounds if not has_bounds else bounds.merge(mesh_bounds)
		has_bounds = true

	return bounds if has_bounds else AABB()


func _should_ignore_mesh(mesh_instance: MeshInstance3D, anchor: Node3D, ignore_names: PackedStringArray) -> bool:
	if ignore_names.is_empty():
		return false

	var current_node: Node = mesh_instance
	while current_node != null and current_node != anchor:
		var node_name: String = current_node.name.to_lower()
		for fragment in ignore_names:
			if fragment != "" and node_name.contains(fragment):
				return true
		current_node = current_node.get_parent()

	return false


func _mesh_bounds_in_anchor_space(anchor: Node3D, mesh_instance: MeshInstance3D) -> AABB:
	var to_anchor: Transform3D = anchor.global_transform.affine_inverse() * mesh_instance.global_transform
	return to_anchor * mesh_instance.mesh.get_aabb()
