extends XRToolsFunctionPointer
class_name XRIntentPointer3D

var hand_armed := false
var hand_pressed := false
var hand := "right"
var tracking_lost_seconds := 0.0
var diag_seconds := 0.0


func _ready() -> void:
	hand = XRSurfacePlacement.pointer_hand(self)


func refresh_raycast() -> void:
	# Empty furniture bounds must not obscure visible catalog cards.
	$RayCast.collision_mask = collision_mask & (1 << 22)
	$RayCast.force_raycast_update()
	if not $RayCast.is_colliding():
		$RayCast.collision_mask = collision_mask
		$RayCast.force_raycast_update()


func _process(delta: float) -> void:
	if delta > 0.25:
		if delta >= 1.0:
			hand_armed = false
			hand_pressed = false
			target = null
		return
	refresh_raycast()
	super._process(delta)
	if not XRModelRotationController3D.is_hand_input(hand):
		hand_armed = false
		hand_pressed = false
		return
	var sample := pointer_sample(hand)
	diag_seconds += delta
	if diag_seconds >= 1.0:
		diag_seconds = 0.0
		var tracker := XRServer.get_tracker("/user/hand_tracker/" + hand) as XRHandTracker
		var controller := XRServer.get_tracker(hand + "_hand") as XRControllerTracker
		var pose: Variant = controller.get_pose("aim") if controller != null else null
		var src := -1
		if tracker != null:
			src = tracker.hand_tracking_source
		XrDiag.log("hand", "hand=%s src=%d tracked=%s pose=%s trig=%s dist=%.3f intent=%s armed=%s" % [hand, src, tracker != null and tracker.has_tracking_data, pose != null and (pose as XRPose).has_tracking_data, str(controller.get_input("trigger_click") if controller != null else "none"), float(sample.get("distance", -1.0)), str(sample.get("intent", false)), str(hand_armed)])
	update_hand_input(sample, delta)


static func pointer_sample(side: String) -> Dictionary:
	var controller := XRServer.get_tracker(side + "_hand") as XRControllerTracker
	var optical := XRModelRotationController3D.hand_sample(side)
	if controller != null:
		var pose := controller.get_pose("aim")
		var select: Variant = controller.get_input("trigger_click")
		var hand_mode := XRModelRotationController3D.is_hand_input(side)
		if select == true and hand_mode:
			XRModelRotationController3D.mark_runtime_select(side)
		# The native select is authoritative only when the controller is the
		# real input or the runtime has proven it maps the hand pinch to the
		# trigger; otherwise fall back to the optical pinch (Quest 2 hand mode).
		if pose != null and select is bool and pose.has_tracking_data and (not hand_mode or XRModelRotationController3D.runtime_select_live(side)):
			# A valid native aim/select does not require four fully tracked joints.
			var tip: Vector3 = optical.get("tip", (XRServer.get_world_origin() * pose.get_adjusted_transform()).origin)
			return {"native_ui": true, "select_pressed": select, "intent": true, "tip": tip}
	return optical


func update_hand_input(sample: Dictionary, delta := 1.0 / 72.0) -> void:
	if not enabled or not XRModelRotationController3D.usable(sample):
		tracking_lost_seconds += delta
		if enabled and tracking_lost_seconds <= 0.25:
			return
		hand_armed = false
		if hand_pressed:
			# No release event: an occluded hand must cancel, never commit a drag.
			target = null
		hand_pressed = false
		return
	tracking_lost_seconds = 0.0
	var down := XRModelRotationController3D.pinch_down(sample, hand_pressed)
	if not down:
		hand_armed = not down if sample.get("native_ui", false) else XRModelRotationController3D.pinch_open(sample)
		if hand_pressed:
			hand_pressed = false
			_button_released()
	elif down and hand_armed and not hand_pressed:
		hand_armed = false
		hand_pressed = true
		_button_pressed()


func _button_pressed() -> void:
	# Near and far UI use the same pinch edge and captured target. Proximity
	# alone never consumes a click or activates a neighbouring card.
	var key := "xr_touch_target_" + hand
	var touch: Variant = get_viewport().get_meta(key) if get_viewport().has_meta(key) else null
	if is_instance_valid(touch) and touch is DemoButton3D and touch.is_visible_in_tree():
		var area := touch.get_node("HitArea") as Area3D
		if area.collision_layer != 0:
			target = area
			last_collided_at = area.global_position
			XRToolsPointerEvent.pressed(self, target, last_collided_at)
			print("XR_UI hand=%s target=%s near=true" % [hand, touch.demo_id])
			return
	refresh_raycast()
	super._button_pressed()
	print("XR_UI hand=%s target=%s near=false" % [hand, str(target.get_parent().name) if is_instance_valid(target) else "miss"])


func _on_button_pressed(button: String, controller: XRController3D) -> void:
	if not XRModelRotationController3D.is_hand_input(hand):
		super._on_button_pressed(button, controller)


func _on_button_released(button: String, controller: XRController3D) -> void:
	if not XRModelRotationController3D.is_hand_input(hand):
		super._on_button_released(button, controller)
