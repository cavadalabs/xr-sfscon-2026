extends Node
class_name XRHandTouchInteractor3D

@export_group("Scene References")
@export var target_root_node_path: NodePath

@export_group("Touch")
@export var enabled := true
@export var touch_enter_margin := 0.012
@export var touch_exit_margin := 0.025
@export var touch_smoothing := 0.3
@export var touch_hand_tracker_path := "/user/hand_tracker/right"
@export_range(0.0, 0.12, 0.005) var touch_poll_interval_seconds := 0.033

@onready var target_root: Node3D = get_node_or_null(target_root_node_path) as Node3D

var menu_open := true
var touch_target: DemoButton3D
var has_smoothed_tip := false
var smoothed_index_tip := Vector3.ZERO
var touch_poll_accumulator := 0.0
var touch_buttons: Array[DemoButton3D] = []


func _ready() -> void:
	touch_buttons = _collect_touch_buttons(target_root)
	if touch_hand_tracker_path.ends_with("right"):
		var left := duplicate() as XRHandTouchInteractor3D
		left.name = "LeftHandTouchInteractor"
		left.touch_hand_tracker_path = "/user/hand_tracker/left"
		get_parent().add_child.call_deferred(left)


func _process(delta: float) -> void:
	if not _is_active():
		touch_poll_accumulator = 0.0
		clear_touch_target()
		return

	touch_poll_accumulator += delta
	var poll_interval := touch_poll_interval_seconds
	if touch_target != null:
		poll_interval *= 0.5
	if poll_interval > 0.0 and touch_poll_accumulator < poll_interval:
		return

	var poll_delta := maxf(touch_poll_accumulator, delta)
	touch_poll_accumulator = 0.0
	_update_touch_interaction(poll_delta)


func set_menu_open(is_open: bool) -> void:
	menu_open = is_open
	if not menu_open:
		clear_touch_target()


func clear_touch_target() -> void:
	var meta_key := "xr_touch_target_" + ("left" if touch_hand_tracker_path.ends_with("left") else "right")
	if get_viewport().has_meta(meta_key) and get_viewport().get_meta(meta_key) == touch_target:
		get_viewport().set_meta(meta_key, null)
	_set_button_hovered(touch_target, false)
	touch_target = null
	has_smoothed_tip = false


func _is_active() -> bool:
	if not enabled or not menu_open:
		return false
	if target_root == null or not is_instance_valid(target_root):
		return false
	if not target_root.is_visible_in_tree():
		return false
	return true


func _update_touch_interaction(_delta: float) -> void:
	var tracker: XRHandTracker = XRServer.get_tracker(touch_hand_tracker_path) as XRHandTracker
	if tracker == null or not tracker.has_tracking_data:
		clear_touch_target()
		has_smoothed_tip = false
		return

	var hand := "left" if touch_hand_tracker_path.ends_with("left") else "right"
	var sample := XRModelRotationController3D.hand_sample(hand)
	if not XRModelRotationController3D.usable(sample):
		clear_touch_target()
		has_smoothed_tip = false
		return
	var raw_index_tip: Vector3 = sample.tip
	if not has_smoothed_tip:
		smoothed_index_tip = raw_index_tip
		has_smoothed_tip = true
	else:
		smoothed_index_tip = smoothed_index_tip.lerp(raw_index_tip, clampf(touch_smoothing, 0.0, 1.0))

	var next_target: DemoButton3D = touch_target
	if touch_target == null or not _is_tip_inside_button(touch_target, smoothed_index_tip, touch_exit_margin):
		next_target = _find_touched_button(smoothed_index_tip, touch_enter_margin)

	if next_target != touch_target:
		_set_button_hovered(touch_target, false)
		touch_target = next_target
		_set_button_hovered(touch_target, true)
		get_viewport().set_meta("xr_touch_target_" + hand, touch_target)


func _find_touched_button(index_tip: Vector3, margin: float) -> DemoButton3D:
	var best_button: DemoButton3D
	var best_score: float = INF

	for button_node in touch_buttons:
		var score: float = _get_button_touch_score(button_node, index_tip, margin)
		if score >= 0.0 and score < best_score:
			best_button = button_node
			best_score = score

	return best_button


func _collect_touch_buttons(root: Node) -> Array[DemoButton3D]:
	var buttons: Array[DemoButton3D] = []
	if root == null:
		return buttons

	for child in root.get_children():
		if child is DemoButton3D:
			buttons.append(child as DemoButton3D)
		buttons.append_array(_collect_touch_buttons(child))

	return buttons


func _is_tip_inside_button(button: DemoButton3D, index_tip: Vector3, margin: float) -> bool:
	return _get_button_touch_score(button, index_tip, margin) >= 0.0


func _get_button_touch_score(button: DemoButton3D, index_tip: Vector3, margin: float) -> float:
	if button == null or not is_instance_valid(button) or not button.is_visible_in_tree():
		return -1.0

	var area: Area3D = button.get_node_or_null("HitArea") as Area3D
	if area == null:
		area = button.get_node_or_null("Area3D") as Area3D
	if area == null or not area.input_ray_pickable or area.collision_layer == 0:
		return -1.0

	var shape_node: CollisionShape3D = area.get_node_or_null("HitShape") as CollisionShape3D
	if shape_node == null:
		shape_node = area.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node == null or not shape_node.shape is BoxShape3D:
		return -1.0

	var local_tip: Vector3 = shape_node.global_transform.affine_inverse() * index_tip
	var shape: BoxShape3D = shape_node.shape as BoxShape3D
	var local_margin: float = _global_margin_to_local(shape_node, margin)
	var half_size: Vector3 = shape.size * 0.5 + Vector3.ONE * local_margin
	var inside: bool = absf(local_tip.x) <= half_size.x and absf(local_tip.y) <= half_size.y and absf(local_tip.z) <= half_size.z
	if not inside:
		return -1.0

	var normalized_tip: Vector3 = Vector3(
		local_tip.x / maxf(0.001, half_size.x),
		local_tip.y / maxf(0.001, half_size.y),
		local_tip.z / maxf(0.001, half_size.z)
	)
	return normalized_tip.length()


func _global_margin_to_local(node: Node3D, margin: float) -> float:
	var node_scale: Vector3 = node.global_transform.basis.get_scale().abs()
	var largest_axis: float = maxf(0.001, maxf(node_scale.x, maxf(node_scale.y, node_scale.z)))
	return margin / largest_axis


func _set_button_hovered(button: DemoButton3D, is_hovered: bool) -> void:
	if button != null and is_instance_valid(button):
		button.set_hovered(is_hovered)
