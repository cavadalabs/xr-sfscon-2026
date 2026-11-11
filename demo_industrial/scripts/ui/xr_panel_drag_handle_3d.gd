extends Node3D
class_name XRPanelDragHandle3D

@export var panel_size := Vector2(3.25, 2.12)
@export var handle_size := Vector2(1.1, 0.18)
@export var handle_color := Color("235652")
@export var view_offset := Vector3(0, -0.2, -2.0)
@export var present_on_show := true
@export var face_camera := true
@export_range(1.0, 6.0, 0.25) var remote_depth_gain := 3.0
@onready var panel := get_parent() as Node3D
@onready var room_body: XRRoomPlacementBody3D = $RoomBody
@onready var label: Label3D = $Label
@onready var hit_area: Area3D = $HitArea
var pointer: Node3D
var pressed := false
var dragging := false
var distance := 2.0
var grab_offset := Vector3.ZERO
var original_pose := Transform3D.IDENTITY
var panel_scale := Vector3.ONE
var uses_hands := false
var hand := "right"
var grab_start_reach := 0.0
var tracking_lost_seconds := 0.0
var wall_attached := false
var original_wall_attached := false
var needs_presentation := true
var user_positioned := false
var original_user_positioned := false


func _ready() -> void:
	# The node structure (Body, Label, HitArea/Shape, RoomBody) comes from
	# XRPanelDragHandle3D.tscn; here we only apply the exported size and tint.
	var material := (load("res://assets/materials/ui/glass_button.tres") as StandardMaterial3D).duplicate() as StandardMaterial3D
	material.albedo_color = handle_color
	$Body.material_override = material
	$Body.mesh.size = handle_size
	$HitArea/Shape.shape.size = Vector3(handle_size.x, handle_size.y, 0.12)
	# The interactive controller caches the "default" layer the first time it
	# touches the area. Pin it to the UI layer now, so a first call while the
	# panel is hidden (layer already zeroed here) cannot remember 0 as default.
	hit_area.set_meta("default_collision_layer", 1 << 22)
	visibility_changed.connect(_sync_visibility)
	_sync_visibility()


func _sync_visibility() -> void:
	var in_tree := is_visible_in_tree()
	hit_area.collision_layer = (1 << 22) if in_tree else 0
	hit_area.input_ray_pickable = in_tree
	if pressed and not in_tree:
		finish_drag(false)


func pointer_event(event: Variant) -> void:
	if not event is XRToolsPointerEvent:
		return
	if event.event_type == XRToolsPointerEvent.Type.PRESSED and not pressed:
		pointer = event.pointer
		hand = XRSurfacePlacement.pointer_hand(pointer)
		pressed = true
		original_pose = panel.global_transform
		original_wall_attached = wall_attached
		original_user_positioned = user_positioned
		grab_offset = panel.global_position - event.position
		distance = _pointer_pose().origin.distance_to(event.position)
		uses_hands = XRModelRotationController3D.is_hand_input(hand)
		var sample := XRIntentPointer3D.pointer_sample(hand)
		var camera := get_viewport().get_camera_3d()
		grab_start_reach = camera.global_position.distance_to(sample.tip) if camera != null and not sample.is_empty() else 0.0
		begin_drag()
	elif event.event_type == XRToolsPointerEvent.Type.RELEASED and event.pointer == pointer:
		finish_drag(true)


func _process(delta: float) -> void:
	if not pressed:
		if panel.is_visible_in_tree() and not wall_attached and face_camera:
			var camera := get_viewport().get_camera_3d()
			if present_on_show and needs_presentation and camera is XRCamera3D and XRSurfacePlacement.is_head_tracked():
				present_to(camera)
			var previous_pose := panel.global_transform
			XRSurfacePlacement.orient_node_to_camera_yaw(panel, camera)
			if room_body.initialized:
				var result := room_body.solve(panel.global_transform)
				panel.global_transform = Transform3D(result.pose.basis.scaled(panel_scale), result.pose.origin) if result.valid else previous_pose
		return
	if delta > 0.25:
		if dragging and delta < 1.0:
			return
		finish_drag(false)
		return
	if not panel.is_visible_in_tree() or not is_instance_valid(pointer):
		finish_drag(false)
		return
	if uses_hands and not XRModelRotationController3D.usable(XRIntentPointer3D.pointer_sample(hand)):
		tracking_lost_seconds += delta
		if tracking_lost_seconds > 0.25:
			finish_drag(false)
		return
	tracking_lost_seconds = 0.0
	update_drag(_pointer_pose())


func present_to(camera: Camera3D) -> void:
	var forward := -camera.global_basis.z
	forward.y = 0
	if forward.length_squared() < 0.001:
		return
	panel.global_position = camera.global_position + Basis.looking_at(forward.normalized()) * view_offset
	XRSurfacePlacement.orient_node_to_camera_yaw(panel, camera)
	needs_presentation = false


func begin_drag() -> void:
	dragging = true
	user_positioned = true
	needs_presentation = false
	panel_scale = panel.global_basis.get_scale()
	room_body.reset_box(Vector3(panel_size.x * panel_scale.x, panel_size.y * panel_scale.y, 0.09), panel.global_transform)
	var scene_services := get_tree().get_first_node_in_group("xr_scene_services") as XRRoot3D
	if scene_services != null and scene_services.scene_manager != null and not scene_services.scene_manager.call("are_scene_anchors_created"):
		scene_services.refresh_room_anchors()


func update_drag(source: Transform3D) -> void:
	var direction := -source.basis.z.normalized()
	var desired := panel.global_transform.orthonormalized()
	var sample := XRIntentPointer3D.pointer_sample(hand)
	var camera := get_viewport().get_camera_3d()
	var reach := camera.global_position.distance_to(sample.tip) if uses_hands and camera != null and not sample.is_empty() else grab_start_reach
	var depth := XRSurfacePlacement.drag_depth(distance, grab_start_reach, reach, remote_depth_gain)
	desired.origin = source.origin + direction * depth + grab_offset
	if camera != null:
		var to_camera := camera.global_position - desired.origin
		to_camera.y = 0
		if to_camera.length_squared() > 0.001:
			desired.basis = Basis.looking_at(-to_camera.normalized())
	var hit: Variant = XRSurfacePlacement.raycast_surface(get_world_3d(), source.origin, direction, XRRoomPlacementBody3D.WALL_LAYER, 0.05, 4.5, 0)
	var attached := false
	if hit is Dictionary:
		var normal: Vector3 = hit.normal
		normal.y = 0
		normal = normal.normalized()
		var gap: float = (desired.origin - hit.point).dot(normal) - room_body.projected_radius(desired.basis, normal)
		if gap <= 0.12:
			attached = true
			desired.basis = Basis.looking_at(-normal, Vector3.UP)
			desired.origin = hit.point + grab_offset.slide(normal) + normal * (0.045 + room_body.wall_clearance)
	var result := room_body.solve(desired)
	if result.valid:
		panel.global_transform = Transform3D(result.pose.basis.scaled(panel_scale), result.pose.origin)
		wall_attached = attached
	label.text = "PARETE · RILASCIA" if attached else "TRASCINA · RILASCIA"


func finish_drag(commit: bool) -> void:
	if pressed and not commit:
		panel.global_transform = original_pose
		wall_attached = original_wall_attached
		user_positioned = original_user_positioned
		room_body.reset_box(room_body.box.size, original_pose)
	pressed = false
	dragging = false
	tracking_lost_seconds = 0.0
	label.text = "⠿  PINCH E TRASCINA"


func _pointer_pose() -> Transform3D:
	var ray := pointer.get_node_or_null("RayCast") as Node3D
	return ray.global_transform if ray != null else pointer.global_transform
