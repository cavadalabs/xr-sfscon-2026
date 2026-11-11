class_name RuntimeMaterials
extends RefCounted


static func duplicate_for_mesh(mesh_instance: MeshInstance3D) -> StandardMaterial3D:
	if mesh_instance == null:
		return StandardMaterial3D.new()

	var source_material: StandardMaterial3D = mesh_instance.material_override as StandardMaterial3D
	if source_material == null:
		source_material = mesh_instance.get_surface_override_material(0) as StandardMaterial3D

	var runtime_material: StandardMaterial3D
	if source_material != null:
		runtime_material = source_material.duplicate() as StandardMaterial3D
	else:
		runtime_material = StandardMaterial3D.new()

	mesh_instance.material_override = runtime_material
	return runtime_material


static func cached_duplicate_for_mesh(mesh_instance: MeshInstance3D, cache: Dictionary) -> StandardMaterial3D:
	if mesh_instance == null:
		return StandardMaterial3D.new()

	var cache_key := mesh_instance.get_instance_id()
	if cache.has(cache_key) and cache[cache_key] is StandardMaterial3D:
		return cache[cache_key] as StandardMaterial3D

	var runtime_material := duplicate_for_mesh(mesh_instance)
	cache[cache_key] = runtime_material
	return runtime_material
