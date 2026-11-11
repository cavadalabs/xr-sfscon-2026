extends Node
class_name XRPlacementController3D

signal target_updated(target_info: Dictionary)
signal confirmed(target_info: Dictionary)
signal active_changed(is_active: bool)

const XR_SURFACE_PLACEMENT := preload("res://scripts/xr/xr_surface_placement.gd")

@export_group("Scene References")
@export var placement_target_node_path: NodePath

@export_group("Input")
@export var confirm_buttons: PackedStringArray = PackedStringArray(["trigger_click", "trigger", "ax_button", "primary_click", "select_click"])
@export var pinch_press_distance := 0.022
@export var pinch_release_distance := 0.035
@export var pinch_rearm_distance := 0.028
@export var hand_tracker_path := "/user/hand_tracker/right"
@export_range(0, 1000, 10) var confirm_guard_msec := 150

@export_group("Surfaces")
@export var room_surface_collision_layer := 1 << 23
@export var floor_y := 0.0
@export var min_distance := 0.35
@export var max_distance := 3.4
@export var default_distance := 1.7
@export var surface_min_up_dot := 0.65
@export var target_surface_offset := 0.012
@export_range(0.0, 0.08, 0.005) var height_snap_step := 0.02
@export_range(0.0, 1.0, 0.01) var preview_smoothing := 0.0
@export var request_room_surfaces_on_begin := true

@onready var placement_target: XRPlacementPreview3D = get_node_or_null(placement_target_node_path) as XRPlacementPreview3D

var right_controller: XRController3D
var left_controller: XRController3D
var active_hand := "right"
var active := false
var active_surface_min_up_dot := 0.65
var started_msec := 0
var pinch_pressed := false
var room_surfaces_requested := false
var has_smoothed_surface_point := false
var smoothed_surface_point := Vector3.ZERO
var last_target_info: Dictionary = {}
var require_floor := false
var target_filter: Callable
var confirm_on_release := false
var confirm_suppressed := false
var pending_pinch_confirm := false
var pending_controller_confirm := false
var dragging := false
var pending_target_info: Dictionary = {}


func _ready() -> void:
	active_surface_min_up_dot = surface_min_up_dot
	_bind_controllers()
	if placement_target != null:
		placement_target.visible = false
	_sync_process_state()


func _process(delta: float) -> void:
	if not is_instance_valid(right_controller) or not is_instance_valid(left_controller):
		_bind_controllers()

	if active:
		if delta > 0.25:
			pending_pinch_confirm = false
			pending_controller_confirm = false
			pending_target_info.clear()
			pinch_pressed = true
		if not pending_pinch_confirm or confirm_suppressed:
			update_target()
		_update_pinch_confirm()

	_sync_process_state()


func begin(surface_min_up_dot_override := -1.0) -> void:
	set_active_hand(str(get_viewport().get_meta("xr_active_hand", active_hand)))
	active = true
	active_surface_min_up_dot = surface_min_up_dot_override if surface_min_up_dot_override >= 0.0 else surface_min_up_dot
	started_msec = Time.get_ticks_msec()
	pinch_pressed = true # Release the catalog selection pinch before placing.
	pending_pinch_confirm = false
	pending_controller_confirm = false
	pending_target_info.clear()
	has_smoothed_surface_point = false
	last_target_info.clear()
	if placement_target != null:
		placement_target.visible = true
	if request_room_surfaces_on_begin:
		_ensure_room_surfaces_requested()
	active_changed.emit(true)
	update_target()
	_sync_process_state()


func cancel() -> void:
	active = false
	pinch_pressed = false
	pending_pinch_confirm = false
	pending_controller_confirm = false
	pending_target_info.clear()
	if placement_target != null:
		placement_target.visible = false
	active_changed.emit(false)
	_sync_process_state()


func confirm(from_button := false) -> void:
	if not active:
		return
	if confirm_suppressed and not from_button:
		return
	if not from_button and Time.get_ticks_msec() - started_msec < confirm_guard_msec:
		return
	if not from_button and is_pointing_at_ui():
		return

	if last_target_info.is_empty() or not last_target_info.get("valid", true):
		return
	confirmed.emit(last_target_info.duplicate(true))


func is_active() -> bool:
	return active


func set_active_hand(hand: String) -> void:
	active_hand = "left" if hand == "left" else "right"
	hand_tracker_path = "/user/hand_tracker/" + active_hand
	get_viewport().set_meta("xr_active_hand", active_hand)


func get_source_transform(hand := "") -> Transform3D:
	var source_hand := active_hand if hand == "" else hand
	return XR_SURFACE_PLACEMENT.get_source_transform(left_controller if source_hand == "left" else right_controller, get_viewport().get_camera_3d())


func update_target() -> Dictionary:
	if XRModelRotationController3D.is_hand_input(active_hand) and not XRModelRotationController3D.usable(XRModelRotationController3D.hand_sample(active_hand)):
		return last_target_info
	if is_pointing_at_ui() and not dragging:
		return last_target_info
	var target_info := _get_surface_target_info()
	target_info["valid"] = not require_floor or target_info.get("surface_kind", "fallback") in ["floor", "fallback"]
	var point_value: Variant = target_info.get("point", Vector3.ZERO)
	var raw_surface_point: Vector3 = point_value if point_value is Vector3 else Vector3.ZERO
	var surface_point: Vector3 = XR_SURFACE_PLACEMENT.snap_height(raw_surface_point, height_snap_step)
	surface_point = _smooth_surface_point(surface_point)
	target_info["point"] = surface_point
	if target_filter.is_valid():
		target_info = target_filter.call(target_info)
		surface_point = target_info.get("point", surface_point)
	last_target_info = target_info.duplicate(true)

	if placement_target != null:
		placement_target.global_position = Vector3(surface_point.x, surface_point.y + target_surface_offset, surface_point.z)
		placement_target.apply_feedback(
			bool(target_info.get("has_surface", false)),
			str(target_info.get("surface_kind", "fallback"))
		)

	target_updated.emit(last_target_info.duplicate(true))
	return last_target_info


func _bind_controllers() -> void:
	right_controller = get_tree().get_first_node_in_group("right_hand_controller") as XRController3D
	left_controller = get_tree().get_first_node_in_group("left_hand_controller") as XRController3D
	for hand in ["right", "left"]:
		var controller := right_controller if hand == "right" else left_controller
		if controller != null and not controller.button_pressed.is_connected(_on_controller_button_pressed.bind(hand)):
			controller.button_pressed.connect(_on_controller_button_pressed.bind(hand))
			controller.button_released.connect(_on_controller_button_released.bind(hand))


func _on_controller_button_pressed(button_name: String, hand: String) -> void:
	if not active:
		return
	if button_name in confirm_buttons:
		if hand != active_hand:
			return
		if XRModelRotationController3D.is_hand_input(hand):
			return # The same validated hand sample drives UI, placement and grabs.
		if not confirm_on_release:
			confirm()
		else:
			pending_controller_confirm = not is_pointing_at_ui()


func _on_controller_button_released(button_name: String, hand: String) -> void:
	if hand == active_hand and button_name in confirm_buttons and pending_controller_confirm:
		pending_controller_confirm = false
		confirm()


func _update_pinch_confirm() -> void:
	var sample := XRModelRotationController3D.hand_sample(active_hand)
	if not XRModelRotationController3D.usable(sample):
		pinch_pressed = true
		pending_pinch_confirm = false
		pending_target_info.clear()
		return
	# Re-arm as soon as the fingers are clearly apart (0.028 m): waiting for the
	# full release distance makes a fast second pinch feel like it is ignored.
	if pinch_pressed and not pending_pinch_confirm and not XRModelRotationController3D.pinch_down(sample, true) and not XRModelRotationController3D.pinch_open(sample, pinch_rearm_distance):
		return
	_update_pinch_state(XRModelRotationController3D.pinch_down(sample, pinch_pressed, pinch_press_distance, pinch_release_distance))


func _update_pinch_distance(pinch_distance: float) -> void:
	_update_pinch_state(pinch_distance < (pinch_release_distance if pinch_pressed else pinch_press_distance))


func _update_pinch_state(pressed: bool) -> void:
	var other := XRModelRotationController3D.hand_sample("left" if active_hand == "right" else "right")
	if confirm_suppressed or XRModelRotationController3D.pinch_down(other):
		pending_pinch_confirm = false
		pending_target_info.clear()
		pinch_pressed = true
		return
	if pinch_pressed:
		if not pressed:
			pinch_pressed = false
			if pending_pinch_confirm:
				pending_pinch_confirm = false
				last_target_info = pending_target_info.duplicate(true)
				confirm()
				pending_target_info.clear()
		return

	if pressed:
		pinch_pressed = true
		if confirm_on_release:
			pending_pinch_confirm = not is_pointing_at_ui() and not last_target_info.is_empty() and last_target_info.get("valid", false)
			pending_target_info = last_target_info.duplicate(true)
		else:
			confirm()


func is_pointing_at_ui(hand := "") -> bool:
	var source_hand := active_hand if hand == "" else hand
	var key := "xr_touch_target_" + source_hand
	var near: Variant = get_viewport().get_meta(key) if get_viewport().has_meta(key) else null
	if is_instance_valid(near) and near is DemoButton3D and not near.is_in_group("xr_manipulable") and near.is_visible_in_tree() and near.get_node("HitArea").collision_layer != 0:
		return true
	var controller := left_controller if source_hand == "left" else right_controller
	if controller == null:
		return false
	var pointer := controller.get_node_or_null("FunctionPointer") as XRToolsFunctionPointer
	if pointer == null:
		return false
	var ray := pointer.get_node("RayCast") as RayCast3D
	var target := ray.get_collider() as Node3D
	return is_instance_valid(target) and target.is_visible_in_tree() and target is CollisionObject3D and target.collision_layer != 0 and not target.get_parent().is_in_group("xr_manipulable")


func _get_surface_target_info() -> Dictionary:
	if require_floor:
		# A cabinet stays on one floor plane as the ray crosses walls and tabletops.
		# Scene FLOOR anchors are already expressed in the recentered XR world.
		var floors := get_tree().get_nodes_in_group("xr_room_floors").filter(func(node: Node): return node is CollisionObject3D and node.collision_layer != 0)
		if not floors.is_empty():
			floor_y = (floors[0] as Node3D).global_position.y
		var source := get_source_transform()
		return {
			"point": XR_SURFACE_PLACEMENT.get_floor_fallback_target_point(source.origin, -source.basis.z.normalized(), floor_y, min_distance, max_distance, default_distance),
			"has_surface": not floors.is_empty(),
			"normal": Vector3.UP,
			"surface_kind": "floor" if not floors.is_empty() else "fallback",
		}
	return XR_SURFACE_PLACEMENT.get_target_info(
		get_viewport().world_3d,
		get_source_transform(),
		room_surface_collision_layer,
		min_distance,
		max_distance,
		default_distance,
		floor_y,
		active_surface_min_up_dot
	)


func _smooth_surface_point(surface_point: Vector3) -> Vector3:
	if preview_smoothing <= 0.0:
		return surface_point
	if not has_smoothed_surface_point:
		smoothed_surface_point = surface_point
		has_smoothed_surface_point = true
		return surface_point

	var alpha := clampf(preview_smoothing, 0.0, 1.0)
	smoothed_surface_point = smoothed_surface_point.lerp(surface_point, alpha)
	smoothed_surface_point.y = surface_point.y
	return smoothed_surface_point


func _ensure_room_surfaces_requested() -> void:
	if room_surfaces_requested:
		return

	var scene_services := get_tree().get_first_node_in_group("xr_scene_services") as XRRoot3D
	if scene_services == null:
		return

	room_surfaces_requested = scene_services.refresh_room_anchors()


func _sync_process_state() -> void:
	set_process(active or right_controller == null or not is_instance_valid(right_controller))
