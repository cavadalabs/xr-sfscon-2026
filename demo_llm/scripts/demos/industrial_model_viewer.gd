extends Node3D
class_name IndustrialModelViewer3D

signal model_loading_started(model_title: String)
signal model_loading_finished(success: bool)
signal hotspot_selected(info: Dictionary)

@export_group("Model Display")
@export var target_model_size := 1.15
@export var model_floor_y := -0.43
@export var reset_rotation_on_model_change := true
@export_range(0.5, 1.8, 0.05) var display_scale_multiplier := 1.0
@export_range(0.05, 0.25, 0.01) var display_scale_step := 0.12

@export_group("Interaction")
@export_range(0.0, 0.35, 0.01) var ray_hit_bounds_margin := 0.12

@onready var model_anchor: Node3D = $ModelAnchor
@onready var current_model_container: Node3D = $ModelAnchor/CurrentModel
@onready var model_bounds: IndustrialModelBounds = $IndustrialModelBounds
@onready var model_animator: IndustrialModelAnimator = $IndustrialModelAnimator
@onready var model_label: IndustrialModelLabel3D = $IndustrialModelLabel3D
@onready var model_loader: IndustrialModelLoader = $IndustrialModelLoader

var current_model_data: Dictionary = {}
var current_model_path := ""
var model_yaw := 0.0
var current_model_bounds_anchor := AABB()
var fallback_model_title := ""
var ghost_materials: Dictionary = {}
var hotspots: Array[IndustrialHotspot] = []
const HOTSPOT_SCENE := preload("res://scenes/demos/industrial/IndustrialHotspot.tscn")
var ghost_enabled := false
var ghost_valid := true
var ghost_material := StandardMaterial3D.new()


func _ready() -> void:
	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if fallback_model_title == "":
		fallback_model_title = model_label.get_text()


func _process(_delta: float) -> void:
	var show := is_visible_in_tree() and not ghost_enabled
	var camera := get_viewport().get_camera_3d()
	var positioned: Array[Area3D] = []
	for hotspot in hotspots:
		hotspot.visible = show
		hotspot.collision_layer = (1 << 22) if show else 0
		if show:
			hotspot.update_pose(camera, model_anchor.global_transform, current_model_bounds_anchor, positioned)
			positioned.append(hotspot)


func set_model_data(model_data: Dictionary) -> void:
	var model_title: String = str(model_data.get("title", fallback_model_title))
	model_label.set_text(model_title)

	var model_path: String = str(model_data.get("model_path", ""))
	if model_path != "":
		var animation_name: String = str(model_data.get("animation", ""))
		if model_loader.is_loading(model_path):
			return
		model_loader.cancel_pending()
		if current_model_path == model_path:
			if model_data.get("animation_autoplay", true):
				model_animator.play(animation_name)
			model_loading_finished.emit(true)
			return

		if model_loader.request_model(model_data, model_path, animation_name):
			model_loading_started.emit(model_title)
			model_label.set_loading(model_title)
		else:
			_show_unavailable(model_data)
		return

	model_loader.cancel_pending()
	_show_unavailable(model_data)


func preload_model_path(model_path: String) -> void:
	model_loader.preload_model_path(model_path)


func adjust_display_scale(direction: float) -> void:
	if current_model_data.get("real_scale", false):
		return
	display_scale_multiplier = clampf(display_scale_multiplier + display_scale_step * signf(direction), 0.5, 1.8)
	if not current_model_data.is_empty():
		_normalize_current_model(current_model_data)


func reset_display_scale() -> void:
	display_scale_multiplier = 1.0
	if not current_model_data.is_empty():
		_normalize_current_model(current_model_data)


func reset_model_view() -> void:
	reset_display_scale()
	_reset_model_rotation()


func clear_viewer() -> void:
	model_loader.clear_requests()
	_clear_current_model()
	model_label.clear()


func rotate_model_manual(yaw_delta: float) -> void:
	model_yaw = wrapf(model_yaw + yaw_delta, -PI, PI)
	_apply_model_rotation()


func is_ray_over_current_model(ray_origin: Vector3, ray_direction: Vector3) -> bool:
	if current_model_bounds_anchor.size == Vector3.ZERO:
		return false
	if ray_direction.length() <= 0.001:
		return false

	var ray_end: Vector3 = ray_origin + ray_direction.normalized()
	var local_origin: Vector3 = model_anchor.global_transform.affine_inverse() * ray_origin
	var local_end: Vector3 = model_anchor.global_transform.affine_inverse() * ray_end
	var local_direction: Vector3 = (local_end - local_origin).normalized()
	return current_model_bounds_anchor.grow(ray_hit_bounds_margin).intersects_ray(local_origin, local_direction) is Vector3


func _show_model_scene(model_path: String, scene_resource: PackedScene, animation_name: String, model_data: Dictionary = {}) -> void:
	var started := Time.get_ticks_usec()
	_clear_current_model()
	display_scale_multiplier = 1.0

	if reset_rotation_on_model_change:
		_reset_model_rotation()

	var model_instance: Node = scene_resource.instantiate()
	current_model_container.add_child(model_instance)
	var instantiated := Time.get_ticks_usec()

	current_model_path = model_path
	current_model_data = model_data.duplicate(true)
	_normalize_current_model(model_data)
	model_label.visible = false # Names and details already live in the catalog/info panel.
	model_animator.bind_and_play(current_model_container, animation_name)
	if not model_data.get("animation_autoplay", true) and model_animator.current_animation_player != null:
		model_animator.current_animation_player.seek(0, true)
		model_animator.current_animation_player.pause()
	_build_hotspots()
	if not model_data.is_empty():
		model_label.set_text(str(model_data.get("title", fallback_model_title)))
	model_loading_finished.emit(true)
	get_viewport().set_meta("xr_profile_model", model_data.get("id", ""))
	print("XR_MODEL visible id=%s instantiate_ms=%.1f setup_ms=%.1f" % [model_data.get("id", ""), (instantiated-started)/1000.0, (Time.get_ticks_usec()-instantiated)/1000.0])


func _show_unavailable(model_data: Dictionary) -> void:
	_clear_current_model()
	model_label.visible = true
	model_label.position.y = 1.4
	model_label.set_unavailable(str(model_data.get("title", fallback_model_title)))
	model_loading_finished.emit(false)


func _on_model_resource_ready(model_path: String, scene_resource: PackedScene, model_data: Dictionary, animation_name: String) -> void:
	_show_model_scene(model_path, scene_resource, animation_name, model_data)


func _on_model_resource_failed(model_data: Dictionary) -> void:
	_show_unavailable(model_data)


func _clear_current_model() -> void:
	set_ghost(false)
	for hotspot in hotspots:
		hotspot.free()
	hotspots.clear()
	model_animator.clear()
	current_model_data.clear()
	current_model_path = ""
	current_model_bounds_anchor = AABB()
	for child in current_model_container.get_children():
		current_model_container.remove_child(child)
		child.queue_free()
	current_model_container.position = Vector3.ZERO
	current_model_container.scale = Vector3.ONE


func _reset_model_rotation() -> void:
	model_yaw = 0.0
	_apply_model_rotation()


func _apply_model_rotation() -> void:
	model_anchor.rotation = Vector3(0.0, model_yaw, 0.0)


func _normalize_current_model(model_data: Dictionary) -> void:
	current_model_container.position = Vector3.ZERO
	current_model_container.scale = Vector3.ONE

	var bounds: AABB = model_bounds.get_cached_bounds(model_data, current_model_path, model_anchor, current_model_container)
	if bounds.size == Vector3.ZERO:
		return

	var largest_axis: float = maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
	if largest_axis <= 0.001:
		return

	var configured_target_size: float = float(model_data.get("target_size", target_model_size))
	var display_scale: float = float(model_data.get("display_scale", 1.0)) * display_scale_multiplier
	var model_scale: float = (configured_target_size / largest_axis) * display_scale
	if model_data.get("real_scale", false):
		model_scale = 1.0
	var bounds_center: Vector3 = bounds.position + bounds.size * 0.5
	var bottom_y: float = bounds.position.y
	var vertical_offset: float = float(model_data.get("vertical_offset", 0.0))
	current_model_container.scale = Vector3.ONE * model_scale
	current_model_container.position = Vector3(
		-bounds_center.x * model_scale,
		model_floor_y + vertical_offset - bottom_y * model_scale,
		-bounds_center.z * model_scale
	)
	current_model_bounds_anchor = AABB(
		current_model_container.position + bounds.position * model_scale,
		bounds.size * model_scale
	)


func set_ghost(enabled: bool, valid := true) -> void:
	if ghost_enabled == enabled and ghost_valid == valid:
		return
	ghost_material.albedo_color = Color(0.2, 0.88, 0.77, 0.3) if valid else Color(1.0, 0.35, 0.22, 0.35)
	if enabled and ghost_enabled:
		ghost_valid = valid
		return
	ghost_enabled = enabled
	ghost_valid = valid
	if enabled:
		for mesh: MeshInstance3D in current_model_container.find_children("*", "MeshInstance3D", true, false):
			if not ghost_materials.has(mesh):
				ghost_materials[mesh] = mesh.material_override
			mesh.material_override = ghost_material
	else:
		for mesh: MeshInstance3D in ghost_materials:
			if is_instance_valid(mesh):
				mesh.material_override = ghost_materials[mesh]
		ghost_materials.clear()
	model_label.visible = not enabled and current_model_path == ""
	for hotspot in hotspots:
		hotspot.visible = not enabled
		hotspot.collision_layer = 0 if enabled else 1 << 22


func _build_hotspots() -> void:
	for data: Dictionary in current_model_data.get("hotspots", []):
		var anchor := current_model_container.find_child(str(data.get("anchor", "")), true, false) as Node3D
		if anchor == null:
			continue
		var hotspot := HOTSPOT_SCENE.instantiate() as IndustrialHotspot
		hotspot.info = data
		hotspot.anchor = anchor
		hotspot.number = hotspots.size() + 1
		add_child(hotspot)
		hotspot.selected.connect(func(info: Dictionary): hotspot_selected.emit(info))
		hotspots.append(hotspot)
