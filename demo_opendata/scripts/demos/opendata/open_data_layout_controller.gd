extends Node
class_name OpenDataLayoutController

signal back_requested

const XR_SURFACE_PLACEMENT := preload("res://scripts/xr/xr_surface_placement.gd")

enum DemoStep {
	INTRO,
	PLACING_MAP,
	EXPLORE,
}

@export_group("Step Labels")
@export var place_map_title := "Posa plastico"
@export var place_map_subtitle := "Tavolo o pavimento"
@export var confirm_map_title := "Conferma"
@export var confirm_map_subtitle := "Posa qui"
@export var primary_action_color := Color(0.18, 0.58, 0.9, 1.0)

@export_group("Placement")
@export var map_surface_min_up_dot := 0.65
@export var map_surface_offset := 0.04
@export var panel_readable_height := 1.55
@export var panel_side_offset := 2.65
@export_range(1.0, 6.0, 0.25) var remote_depth_gain := 3.0

@export_group("Scene References")
@export var back_button_node_path: NodePath
@export var place_map_button_node_path: NodePath
@export var reset_layout_button_node_path: NodePath
@export var intro_panel_node_path: NodePath
@export var noi_map_node_path: NodePath
@export var data_panel_node_path: NodePath
@export var placement_controller_node_path: NodePath

@onready var back_button: DemoButton3D = get_node_or_null(back_button_node_path) as DemoButton3D
@onready var place_map_button: DemoButton3D = get_node_or_null(place_map_button_node_path) as DemoButton3D
@onready var reset_layout_button: DemoButton3D = get_node_or_null(reset_layout_button_node_path) as DemoButton3D
@onready var intro_panel: InfoPanel3D = get_node_or_null(intro_panel_node_path) as InfoPanel3D
@onready var noi_map: NoiMap3D = get_node_or_null(noi_map_node_path) as NoiMap3D
@onready var data_panel: DataPanel3D = get_node_or_null(data_panel_node_path) as DataPanel3D
@onready var placement_controller: XRPlacementController3D = get_node_or_null(placement_controller_node_path) as XRPlacementController3D

var interaction: InteractiveCollisionController3D
var gestures: XRModelRotationController3D
const InteractiveCollisionControllerScene := preload("res://scenes/ui/InteractiveCollisionController3D.tscn")
const XRModelRotationControllerScene := preload("res://scenes/xr/XRModelRotationController3D.tscn")

var demo_step: int = DemoStep.INTRO
var default_map_transform := Transform3D.IDENTITY
var default_data_panel_transform := Transform3D.IDENTITY
var direct_candidates: Dictionary = {}
var original_map_pose := Transform3D.IDENTITY
var grab_start_pose := Transform3D.IDENTITY
var grab_start_tip := Vector3.ZERO
var grab_offset := Vector3.ZERO
var grab_depth := 1.0
var grab_start_reach := 0.0
var grab_direct := false
const MAP_BOUNDS := AABB(Vector3(-1.02, -0.04, -1.02), Vector3(2.04, 0.34, 2.04))


func _ready() -> void:
	if not noi_map.is_node_ready():
		await noi_map.ready
	if not data_panel.is_node_ready():
		await data_panel.ready
	interaction = InteractiveCollisionControllerScene.instantiate()
	gestures = XRModelRotationControllerScene.instantiate()
	add_child(interaction)
	add_child(gestures)
	gestures.source_provider = placement_controller
	gestures.can_start = _can_start_gesture
	gestures.move_requested.connect(_begin_gesture_move)
	gestures.move_finished.connect(_finish_gesture_move)
	gestures.rotation_requested.connect(func(angle: float): noi_map.global_basis = Basis(Vector3.UP, angle) * noi_map.global_basis)
	gestures.scale_requested.connect(func(factor: float): noi_map.set_zoom(noi_map.scale.x * factor))
	gestures.hold_progress.connect(func(seconds: float):
		if seconds > 0:
			noi_map.title.text = "Mantieni il pinch · %.1f / 1 s" % minf(seconds, 1)
		else:
			noi_map._sync_controls())
	noi_map.gestures = gestures
	noi_map.controls.reparent(data_panel, false)
	noi_map.legend.hide()
	default_map_transform = noi_map.global_transform
	default_data_panel_transform = data_panel.global_transform
	_set_demo_step(DemoStep.INTRO)


func _on_back_button_pressed(_demo_id: String) -> void:
	back_requested.emit()


func _on_place_map_button_pressed(_demo_id: String) -> void:
	match demo_step:
		DemoStep.INTRO:
			_set_demo_step(DemoStep.PLACING_MAP)
		DemoStep.PLACING_MAP:
			placement_controller.confirm(true)


func _on_reset_layout_button_pressed(_demo_id: String) -> void:
	_reset_layout()


func _set_demo_step(next_step: int) -> void:
	demo_step = next_step
	var is_intro: bool = demo_step == DemoStep.INTRO
	var is_placing: bool = demo_step == DemoStep.PLACING_MAP
	var is_explore: bool = demo_step == DemoStep.EXPLORE

	intro_panel.visible = is_intro
	place_map_button.visible = is_intro or is_placing
	reset_layout_button.visible = is_explore

	noi_map.visible = not is_intro
	data_panel.visible = is_explore
	for button in [place_map_button, reset_layout_button]:
		interaction.set_branch_interactive(button, button.visible)
	interaction.set_branch_interactive(data_panel, data_panel.visible)
	gestures.set_input_blocked(not is_explore)

	if is_intro:
		place_map_button.configure("place_map", place_map_title, place_map_subtitle, primary_action_color)
	elif demo_step == DemoStep.PLACING_MAP:
		place_map_button.configure("place_map", confirm_map_title, confirm_map_subtitle, primary_action_color)

	if demo_step == DemoStep.PLACING_MAP:
		placement_controller.begin(map_surface_min_up_dot)
	else:
		placement_controller.cancel()


func _on_placement_confirmed(target_info: Dictionary) -> void:
	_apply_placement_target(target_info)
	_position_panel_near_map()

	_set_demo_step(DemoStep.EXPLORE)
	gestures.block_after_placement()


func _reset_layout() -> void:
	gestures.stop_interaction()
	noi_map.pending_selection = Callable()
	noi_map.global_transform = default_map_transform
	var handle := data_panel.get_node("DragHandle") as XRPanelDragHandle3D
	handle.finish_drag(false)
	handle.wall_attached = false
	handle.room_body.initialized = false
	data_panel.global_transform = default_data_panel_transform
	_set_demo_step(DemoStep.EXPLORE)
	noi_map._sync_controls()


func _on_placement_target_updated(target_info: Dictionary) -> void:
	_apply_placement_target(target_info)


func _apply_placement_target(target_info: Dictionary) -> void:
	var point_value: Variant = target_info.get("point", Vector3.ZERO)
	var surface_point: Vector3 = point_value if point_value is Vector3 else Vector3.ZERO

	if demo_step == DemoStep.PLACING_MAP:
		noi_map.global_position = Vector3(surface_point.x, surface_point.y + map_surface_offset, surface_point.z)
		XR_SURFACE_PLACEMENT.orient_node_to_camera_yaw(noi_map, get_viewport().get_camera_3d())


func _position_panel_near_map() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	var side_direction := Vector3.RIGHT
	if camera != null:
		side_direction = camera.global_transform.basis.x.normalized()

	var panel_position: Vector3 = noi_map.global_position + side_direction * panel_side_offset
	data_panel.global_position = Vector3(panel_position.x, panel_readable_height, panel_position.z)
	XR_SURFACE_PLACEMENT.orient_node_to_camera_yaw(data_panel, get_viewport().get_camera_3d())


func _process(_delta: float) -> void:
	if demo_step != DemoStep.EXPLORE:
		back_button.global_transform = intro_panel.global_transform * Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.7), Vector3(0.62, -1.08, 0.04))
		place_map_button.global_transform = intro_panel.global_transform * Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.7), Vector3(-0.62, -1.08, 0.04))
		return
	var buttons := [back_button, reset_layout_button]
	for i in buttons.size():
		var button: DemoButton3D = buttons[i]
		var local_position := Vector3(-1.2 + i * 2.4, -0.94, 0.05)
		button.global_transform = data_panel.global_transform * Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.58), local_position)
	if gestures.dragging and not gestures.tracking_suspended:
		if gestures.rotating:
			_capture_grab() # Resume a one-hand move without jumping after a two-hand turn.
		else:
			_update_gesture_move()


func _can_start_gesture(hand: String) -> bool:
	if demo_step != DemoStep.EXPLORE or not noi_map.is_visible_in_tree() or placement_controller.is_pointing_at_ui(hand):
		return false
	if gestures.dragging or gestures.rotating:
		return true
	var sample := XRModelRotationController3D.hand_sample(hand)
	var inverse := noi_map.global_transform.affine_inverse()
	var direct := XRModelRotationController3D.usable(sample) and MAP_BOUNDS.has_point(inverse * sample.tip)
	if gestures.holding and gestures.drag_hand == hand and direct_candidates.get(hand, false):
		return direct
	direct_candidates[hand] = direct
	if direct:
		return true
	var ray := placement_controller.get_source_transform(hand)
	var hit: Variant = MAP_BOUNDS.intersects_ray(inverse * ray.origin, inverse.basis * -ray.basis.z.normalized())
	return hit is Vector3 and ray.origin.distance_to(noi_map.global_transform * hit) <= 4.5


func _begin_gesture_move() -> void:
	original_map_pose = noi_map.global_transform
	grab_direct = direct_candidates.get(gestures.drag_hand, false)
	_capture_grab()
	noi_map.pending_selection = Callable()


func _capture_grab() -> void:
	grab_start_pose = noi_map.global_transform
	var ray := placement_controller.get_source_transform(gestures.drag_hand)
	grab_depth = maxf(0.05, (grab_start_pose.origin - ray.origin).dot(-ray.basis.z.normalized()))
	grab_offset = grab_start_pose.origin - (ray.origin - ray.basis.z.normalized() * grab_depth)
	var sample := XRModelRotationController3D.hand_sample(gestures.drag_hand)
	grab_start_tip = sample.get("tip", Vector3.ZERO)
	var camera := get_viewport().get_camera_3d()
	grab_start_reach = camera.global_position.distance_to(grab_start_tip) if camera != null and not sample.is_empty() else 0.0


func _update_gesture_move() -> void:
	var sample := XRModelRotationController3D.hand_sample(gestures.drag_hand)
	if not XRModelRotationController3D.usable(sample):
		return
	if grab_direct:
		noi_map.global_position = grab_start_pose.origin + sample.tip - grab_start_tip
	else:
		var ray := placement_controller.get_source_transform(gestures.drag_hand)
		var camera := get_viewport().get_camera_3d()
		var reach := camera.global_position.distance_to(sample.tip) if camera != null else grab_start_reach
		var depth := XR_SURFACE_PLACEMENT.drag_depth(grab_depth, grab_start_reach, reach, remote_depth_gain)
		noi_map.global_position = ray.origin - ray.basis.z.normalized() * depth + grab_offset


func _finish_gesture_move(tracked: bool) -> void:
	if not tracked:
		noi_map.global_transform = original_map_pose
	noi_map._sync_controls()
