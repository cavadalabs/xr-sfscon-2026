extends Node
class_name XRModelRotationController3D

signal rotation_requested(yaw_delta: float)
signal scale_requested(factor: float)
signal move_requested
signal move_finished(tracked: bool)
signal hold_progress(seconds: float)

@export var model_viewer_node_path: NodePath
@export var wrist_menu_node_path: NodePath
@export var source_provider_node_path: NodePath
@export var enabled := true
@export var pinch_press_distance := 0.022
@export var pinch_release_distance := 0.035
@export var hold_seconds := 1.0
@export var post_placement_block_msec := 450
@export var hold_target_grace_seconds := 0.15
@export var tracking_grace_seconds := 0.25
@export_range(0.002, 0.03, 0.001) var scale_deadzone_m := 0.008
# Reject a curled index against the palm; keep this ratio adjustable for hand sizes.
static var minimum_index_reach := 0.9

@onready var source_provider: XRPlacementController3D = get_node_or_null(source_provider_node_path) as XRPlacementController3D
var can_start: Callable
var input_blocked := false
var blocked_until_msec := 0
var right_pressed := false
var left_pressed := false
var holding := false
var dragging := false
var rotating := false
var consumed := false
var held_seconds := 0.0
var last_hand_angle := 0.0
var last_hand_span := 0.0
var had_tracking := false
var drag_hand := "right"
var allow_hold := true
var right_armed := false
var left_armed := false
var target_lost_seconds := 0.0
var tracking_lost_seconds := 0.0
var tracking_suspended := false


func _process(delta: float) -> void:
	if not enabled or input_blocked or Time.get_ticks_msec() < blocked_until_msec:
		return
	var right := hand_sample("right")
	var left := hand_sample("left")
	# UI owns a new pinch aimed at a panel, including the second hand of a grab.
	if source_provider != null:
		if not right_pressed and source_provider.is_pointing_at_ui("right"):
			right = {}
		if not left_pressed and source_provider.is_pointing_at_ui("left"):
			left = {}
	var right_available := can_start.is_valid() and bool(can_start.call("right"))
	var left_available := can_start.is_valid() and bool(can_start.call("left"))
	update_gesture(delta, right, left, right_available, left_available)


# A hand-sourced runtime only feeds the controller trigger when it emulates a
# controller (Quest 3 hand aim). The Quest 2 hand-interaction profile exposes
# the pinch on the select action Godot does not surface, so the trigger stays
# dead there: the native select is trusted only once observed during hand mode.
static var runtime_select := {}


static func runtime_select_live(side: String) -> bool:
	return runtime_select.get(side, false)


static func mark_runtime_select(side: String) -> void:
	runtime_select[side] = true


static func hand_sample(hand: String) -> Dictionary:
	var tracker := XRServer.get_tracker("/user/hand_tracker/" + hand) as XRHandTracker
	if tracker == null or not tracker.has_tracking_data or tracker.hand_tracking_source in [XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER, XRHandTracker.HAND_TRACKING_SOURCE_NOT_TRACKED]:
		return {}
	var index := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	var thumb := XRHandTracker.HAND_JOINT_THUMB_TIP
	var wrist := XRHandTracker.HAND_JOINT_WRIST
	var knuckle := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL
	var required := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED
	for joint in [index, thumb, wrist, knuckle]:
		if tracker.get_hand_joint_flags(joint) & required != required:
			return {}
	var tip := tracker.get_hand_joint_transform(index).origin
	var thumb_tip := tracker.get_hand_joint_transform(thumb).origin
	var wrist_position := tracker.get_hand_joint_transform(wrist).origin
	var knuckle_position := tracker.get_hand_joint_transform(knuckle).origin
	var reach := knuckle_position.distance_to(wrist_position)
	var intentional := reach > 0.025 and tip.distance_to(wrist_position) >= reach * minimum_index_reach
	var world_tip := XRServer.get_world_origin() * XRServer.get_reference_frame() * (tip * XRServer.world_scale)
	var sample := {"distance": tip.distance_to(thumb_tip), "tip": world_tip, "intent": intentional}
	var aim := XRServer.get_tracker(hand + "_hand") as XRControllerTracker
	# Only a runtime that has proven it drives the trigger from the hand
	# (Quest 3) can veto the optical pinch; a dead or unproven controller
	# trigger must not silence Quest 2 hand input.
	if aim != null and runtime_select_live(hand):
		var pose := aim.get_pose("aim")
		var select: Variant = aim.get_input("trigger_click")
		if pose != null and pose.has_tracking_data and select is bool:
			sample["select_pressed"] = select
	return sample


static func is_hand_input(hand: String) -> bool:
	var tracker := XRServer.get_tracker("/user/hand_tracker/" + hand) as XRHandTracker
	return tracker != null and tracker.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER


static func usable(sample: Dictionary) -> bool:
	return not sample.is_empty() and bool(sample.get("intent", false))


static func pinch_down(sample: Dictionary, was_pressed := false, press_distance := 0.022, release_distance := 0.035) -> bool:
	if not usable(sample):
		return false
	# Prefer the runtime's pinch recognition; optical geometry remains a fallback.
	if sample.has("select_pressed"):
		return bool(sample.select_pressed)
	return float(sample.distance) < (release_distance if was_pressed else press_distance)


static func pinch_open(sample: Dictionary, release_distance := 0.035) -> bool:
	var separation := minf(release_distance, 0.022) if sample.has("select_pressed") else release_distance
	return usable(sample) and float(sample.distance) >= separation and not pinch_down(sample, true, 0.022, release_distance)


func update_gesture(delta: float, right: Dictionary, left: Dictionary, over_target: bool, left_over_target := false) -> void:
	if delta > 0.25:
		if (dragging or rotating) and delta < 1.0:
			tracking_suspended = true
			return # A short render stall must not undo an established grab.
		if dragging:
			move_finished.emit(false)
		stop_interaction()
		consumed = true
		return
	var owner_lost := (holding or dragging) and not usable(right if drag_hand == "right" else left)
	if owner_lost or (rotating and (not usable(right) or not usable(left))) or (right.is_empty() and left.is_empty() and had_tracking):
		tracking_lost_seconds += delta
		tracking_suspended = true
		if (holding or dragging or rotating) and tracking_lost_seconds <= tracking_grace_seconds:
			return # Freeze and do not advance the hold timer while unobserved.
		if dragging:
			move_finished.emit(false)
		stop_interaction()
		had_tracking = false
		consumed = true # Reacquisition requires an open hand.
		return
	if right.is_empty() and left.is_empty():
		return
	var resumed := tracking_suspended
	tracking_suspended = false
	tracking_lost_seconds = 0.0
	had_tracking = true
	var was_right := right_pressed
	var was_left := left_pressed
	if not usable(right):
		right_armed = false
	elif pinch_open(right, pinch_release_distance):
		right_armed = true
	if not usable(left):
		left_armed = false
	elif pinch_open(left, pinch_release_distance):
		left_armed = true
	right_pressed = (was_right or right_armed) and pinch_down(right, was_right, pinch_press_distance, pinch_release_distance)
	left_pressed = (was_left or left_armed) and pinch_down(left, was_left, pinch_press_distance, pinch_release_distance)
	var right_began := right_pressed and not was_right
	var left_began := left_pressed and not was_left
	if right_began:
		right_armed = false
	if left_began:
		left_armed = false
	var owner_pressed := right_pressed if drag_hand == "right" else left_pressed
	if (holding or dragging) and not owner_pressed:
		if dragging:
			dragging = false
			holding = false
			held_seconds = 0
			var still_pinched := right_pressed or left_pressed
			move_finished.emit(true)
			consumed = still_pinched
			hold_progress.emit(0)
			return
		holding = false
		dragging = false
		held_seconds = 0
		hold_progress.emit(0)
	if not right_pressed and not left_pressed:
		consumed = false
		rotating = false
		return
	if right_pressed and left_pressed and (rotating or right_began or left_began) and (not consumed or rotating or dragging) and (over_target or left_over_target or holding or dragging or rotating):
		if not rotating and not holding and not dragging:
			drag_hand = "right" if over_target else "left"
		var span: Vector3 = right.tip - left.tip
		var hand_span := span.length()
		span.y = 0
		if span.length() < 0.12:
			if dragging:
				move_finished.emit(false)
			stop_interaction()
			consumed = true
			return
		var angle := atan2(span.z, span.x)
		if rotating and not resumed:
			var yaw_delta := -wrapf(angle - last_hand_angle, -PI, PI)
			if not is_zero_approx(yaw_delta):
				rotation_requested.emit(yaw_delta)
			if last_hand_span > 0.0 and absf(hand_span - last_hand_span) >= scale_deadzone_m:
				scale_requested.emit(hand_span / last_hand_span)
				last_hand_span = hand_span
		else:
			last_hand_span = hand_span # Rebase after occlusion; never scale from an unobserved movement.
		last_hand_angle = angle
		rotating = true
		holding = false
		held_seconds = 0
		consumed = true
		hold_progress.emit(0)
		return
	if rotating:
		rotating = false
		consumed = true
	if dragging or consumed or not allow_hold:
		return
	if right_began and over_target:
		drag_hand = "right"
		holding = true
		held_seconds = 0
		target_lost_seconds = 0
	elif left_began and left_over_target:
		drag_hand = "left"
		holding = true
		held_seconds = 0
		target_lost_seconds = 0
	if holding:
		var over_owner := over_target if drag_hand == "right" else left_over_target
		target_lost_seconds = 0.0 if over_owner else target_lost_seconds + delta
		if target_lost_seconds > hold_target_grace_seconds:
			holding = false
			held_seconds = 0
			consumed = true
			hold_progress.emit(0)
			return
		if not over_owner:
			return
		held_seconds += delta
		hold_progress.emit(held_seconds)
		if held_seconds >= hold_seconds:
			holding = false
			dragging = true
			move_requested.emit()


func set_input_blocked(is_blocked: bool) -> void:
	input_blocked = is_blocked
	if is_blocked:
		stop_interaction()


func block_after_placement() -> void:
	blocked_until_msec = Time.get_ticks_msec() + post_placement_block_msec
	stop_interaction()
	consumed = true


func stop_interaction() -> void:
	last_hand_span = 0.0
	tracking_lost_seconds = 0.0
	tracking_suspended = false
	right_pressed = false
	left_pressed = false
	holding = false
	dragging = false
	rotating = false
	held_seconds = 0
	consumed = false
	right_armed = false
	left_armed = false
	target_lost_seconds = 0
