extends Node3D
class_name XRRoot3D

@export var start_xr := true
@export var enable_passthrough := false
@export var enable_scene_api := true
@export var enable_spatial_anchors := true
@export var log_scene_anchors := false
@export var log_performance := true
var profile_elapsed := 0.0
var profile_frames := 0
var profile_worst_ms := 0.0

@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var scene_manager: Node = $XROrigin3D/SceneManager
@onready var spatial_anchor_manager: Node = $XROrigin3D/SpatialAnchorManager


func _ready() -> void:
	_configure_scene_services()
	_configure_environment()

	if start_xr:
		_try_start_xr()


func _process(delta: float) -> void:
	if not log_performance:
		return
	profile_elapsed += delta
	profile_frames += 1
	profile_worst_ms = maxf(profile_worst_ms, delta * 1000.0)
	if profile_elapsed >= 5.0:
		print("XR_PERF fps=%.1f worst_ms=%.1f script_ms=%.1f physics_ms=%.1f draws=%d video_mb=%.1f model=%s" % [profile_frames/profile_elapsed, profile_worst_ms, Performance.get_monitor(Performance.TIME_PROCESS)*1000, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000, Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)/1048576, get_viewport().get_meta("xr_profile_model", "menu")])
		var walls := get_tree().get_nodes_in_group("xr_room_walls")
		var active_walls := walls.filter(func(node: Node): return node is CollisionObject3D and node.collision_layer != 0)
		print("XR_ROOM walls=%d active=%d world_scale=%.3f" % [walls.size(), active_walls.size(), XRServer.world_scale])
		profile_elapsed = 0.0
		profile_frames = 0
		profile_worst_ms = 0.0


func _try_start_xr() -> void:
	var xr_interface: XRInterface = XRServer.find_interface("OpenXR")

	if xr_interface == null:
		_fail_xr_start("OpenXR interface unavailable.")
		return

	if not xr_interface.is_initialized():
		var initialized := xr_interface.initialize()
		if not initialized:
			_fail_xr_start("OpenXR initialization failed.")
			return

	_configure_passthrough(xr_interface)
	get_viewport().use_xr = true
	xr_camera.current = true


func _configure_passthrough(xr_interface: XRInterface) -> void:
	if not enable_passthrough:
		return

	get_viewport().transparent_bg = true
	var alpha_blend_supported := XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in xr_interface.get_supported_environment_blend_modes()
	if alpha_blend_supported:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND

	var passthrough_started := _try_start_passthrough_api(xr_interface, "XRInterface")
	var meta_passthrough: Object = _get_meta_passthrough_extension()
	if meta_passthrough != null:
		if meta_passthrough.has_method("is_passthrough_started"):
			passthrough_started = bool(meta_passthrough.call("is_passthrough_started")) or passthrough_started
		_configure_meta_passthrough_style(meta_passthrough)
	elif not passthrough_started:
		push_warning("Meta passthrough extension singleton is unavailable.")

	if passthrough_started:
		return
	else:
		if not alpha_blend_supported:
			push_warning("OpenXR alpha blend mode is not supported; vendor passthrough must be enabled.")
		push_warning("OpenXR passthrough did not start.")


func _try_start_passthrough_api(api: Object, api_name: String) -> bool:
	if api == null:
		return false
	if not api.has_method("start_passthrough"):
		push_warning("%s does not expose start_passthrough()." % api_name)
		return false

	if api.has_method("is_passthrough_supported") and not bool(api.call("is_passthrough_supported")):
		push_warning("%s reports passthrough as unsupported on this runtime." % api_name)
		return false

	var start_result: Variant = api.call("start_passthrough")
	var started := true
	if start_result is bool:
		started = bool(start_result)
	if api.has_method("is_passthrough_started"):
		started = bool(api.call("is_passthrough_started"))

	if not started:
		push_warning("%s start_passthrough() returned false." % api_name)
	return started


func _get_meta_passthrough_extension() -> Object:
	for singleton_name in PackedStringArray([
		"OpenXRFbPassthroughExtension",
		"OpenXRFbPassthroughExtensionWrapper",
	]):
		if Engine.has_singleton(singleton_name):
			return Engine.get_singleton(singleton_name)
	return null


func _configure_meta_passthrough_style(meta_passthrough: Object) -> void:
	if meta_passthrough.has_method("set_edge_color"):
		meta_passthrough.call("set_edge_color", Color(0, 0, 0, 0))
	if meta_passthrough.has_method("set_texture_opacity_factor"):
		meta_passthrough.call("set_texture_opacity_factor", 1.0)


func _configure_scene_services() -> void:
	if enable_scene_api and scene_manager != null:
		_connect_signal_if_available(scene_manager, "openxr_fb_scene_data_missing", "_on_scene_data_missing")
		_connect_signal_if_available(scene_manager, "openxr_fb_scene_capture_completed", "_on_scene_capture_completed")
		_connect_signal_if_available(scene_manager, "openxr_fb_scene_anchor_created", "_on_scene_anchor_created")

	if enable_spatial_anchors and spatial_anchor_manager != null:
		_connect_signal_if_available(spatial_anchor_manager, "openxr_fb_spatial_anchor_tracked", "_on_spatial_anchor_tracked")
		_connect_signal_if_available(spatial_anchor_manager, "openxr_fb_spatial_anchor_create_failed", "_on_spatial_anchor_create_failed")


func _connect_signal_if_available(source: Object, signal_name: String, method_name: String) -> void:
	if source == null or not source.has_signal(signal_name):
		return

	var callback := Callable(self, method_name)
	if not source.is_connected(signal_name, callback):
		source.connect(signal_name, callback)


func refresh_room_anchors(replace_existing := false) -> bool:
	if not enable_scene_api:
		return false
	if scene_manager == null or not scene_manager.has_method("create_scene_anchors"):
		return false

	if scene_manager.has_method("are_scene_anchors_created") and bool(scene_manager.call("are_scene_anchors_created")):
		if not replace_existing:
			return true
		scene_manager.call("remove_scene_anchors")

	var result: Variant = scene_manager.call("create_scene_anchors")
	return int(result) == OK


func create_spatial_anchor(anchor_transform: Transform3D, custom_data: Dictionary = {}) -> bool:
	if not enable_spatial_anchors:
		return false
	if spatial_anchor_manager == null or not spatial_anchor_manager.has_method("create_anchor"):
		push_warning("Meta Spatial Anchor Manager is unavailable on this runtime.")
		return false

	var anchor_pose := anchor_transform
	anchor_pose.basis = anchor_pose.basis.orthonormalized()
	spatial_anchor_manager.call("create_anchor", anchor_pose, custom_data)
	return true


func _on_scene_data_missing() -> void:
	push_warning("No Meta scene data found for this space.")


func _on_scene_capture_completed(success: bool) -> void:
	if not success:
		push_warning("Meta scene capture was cancelled or failed.")
		return

	refresh_room_anchors(true)


func _on_scene_anchor_created(_scene_node: Object, spatial_entity: Object) -> void:
	if not log_scene_anchors:
		return
	if spatial_entity != null and spatial_entity.has_method("get_semantic_labels"):
		print("Scene anchor: ", spatial_entity.call("get_semantic_labels"))


func _on_spatial_anchor_tracked(_anchor_node: Object, spatial_entity: Object, is_new: bool) -> void:
	if log_scene_anchors and is_new and spatial_entity != null:
		print("Spatial anchor tracked: ", spatial_entity.get("uuid"))


func _on_spatial_anchor_create_failed(_anchor_transform: Transform3D, custom_data: Dictionary) -> void:
	push_warning("Spatial anchor creation failed: %s" % str(custom_data))


func _configure_environment() -> void:
	get_viewport().transparent_bg = enable_passthrough

	var environment: Environment = world_environment.environment
	if environment == null:
		push_warning("XRRoot requires WorldEnvironment.environment to be set in the scene.")
		return

	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0, 0) if enable_passthrough else Color(0.012, 0.016, 0.022, 1.0)


func _fail_xr_start(message: String) -> void:
	get_viewport().use_xr = false
	xr_camera.current = false
	push_error("XR startup failed: %s This app is configured as XR-only." % message)
