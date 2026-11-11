extends Node
class_name IndustrialModelPlacementController

signal back_requested
signal status_changed(message: String)
signal placement_cancelled
signal model_state_changed

const CONTROL_ACTIONS := ["place_model", "reset_model", "scale_down", "scale_up", "menu", "cancel_placement", "delete_model", "duplicate_model"]
const FurnitureItemScene := preload("res://scenes/demos/industrial/FurnitureItem.tscn")
# ponytail: eight placed items per session; raise after a Quest frame-time pass.
## Numero massimo di arredi posizionabili nella stanza.
@export var max_furniture := 8
const XR_SURFACE_PLACEMENT := preload("res://scripts/xr/xr_surface_placement.gd")

@export_group("Wrist Menu Labels")
@export var place_button_move_title := "Move"
@export var place_button_move_subtitle := "Place"
@export var place_button_set_title := "Set"
@export var place_button_set_subtitle := "Place here"

@export_group("Placement")
@export var auto_anchor_placed_models := true
@export_range(1.0, 6.0, 0.25) var remote_depth_gain := 3.0

@export_group("Scene References")
@export var wrist_menu_node_path: NodePath
@export var model_viewer_node_path: NodePath
@export var industrial_catalog_node_path: NodePath
@export var placement_controller_node_path: NodePath
@export var rotation_controller_node_path: NodePath
@export var shared_state_node_path: NodePath

@onready var wrist_menu: WristMenu3D = get_node_or_null(wrist_menu_node_path) as WristMenu3D
@onready var model_viewer: IndustrialModelViewer3D = get_node_or_null(model_viewer_node_path) as IndustrialModelViewer3D
@onready var industrial_catalog: IndustrialCatalog = get_node_or_null(industrial_catalog_node_path) as IndustrialCatalog
@onready var placement_controller: XRPlacementController3D = get_node_or_null(placement_controller_node_path) as XRPlacementController3D
@onready var rotation_controller: XRModelRotationController3D = get_node_or_null(rotation_controller_node_path) as XRModelRotationController3D
@onready var shared: Node = _resolve_shared_state()

func _resolve_shared_state() -> Node:
	var node := get_node_or_null(shared_state_node_path)
	if node == null:
		# The state is persistent (AppServices in Main.tscn): find it by group.
		node = get_tree().get_first_node_in_group("shared_state")
	return node

var default_model_viewer_transform := Transform3D.IDENTITY
var placement_mode := false
var selection_blocked := false
var _shared_sync_pending := false
var _shared_drag_due := 0.0
## Live drag updates per second sent to the other headsets (issue #19).
const SHARED_DRAG_INTERVAL := 0.1
var furniture_items: Array[Node3D] = []
var selected_furniture: Node3D
var selecting_placed := false
var before_placement := Transform3D.IDENTITY
var room_body: XRRoomPlacementBody3D
var gesture_moving := false
var manual_wall_rotation := false
var gesture_candidates: Dictionary = {}
var direct_candidates: Dictionary = {}
var grab_start_pose := Transform3D.IDENTITY
var grab_start_tip := Vector3.ZERO
var grab_depth := 1.0
var grab_offset := Vector3.ZERO
var grab_direct := false
var grab_start_reach := 0.0
const ROOM_BODY_SCENE := preload("res://scenes/xr/XRRoomPlacementBody3D.tscn")


func _ready() -> void:
	default_model_viewer_transform = model_viewer.global_transform
	room_body = ROOM_BODY_SCENE.instantiate() as XRRoomPlacementBody3D
	add_child(room_body)
	placement_controller.target_filter = _constrain_target
	placement_controller.confirm_on_release = true
	rotation_controller.can_start = _can_start_gesture
	rotation_controller.rotation_requested.connect(_rotate_continuous)
	rotation_controller.move_requested.connect(_begin_gesture_move)
	rotation_controller.move_finished.connect(_finish_gesture_move)
	rotation_controller.hold_progress.connect(_show_hold_progress)
	sync_control_labels()


func _process(_delta: float) -> void:
	placement_controller.confirm_suppressed = gesture_moving or rotation_controller.rotating or rotation_controller.consumed
	if _shared_sync_pending:
		if gesture_moving or rotation_controller.rotating:
			_shared_sync_throttled()
		else:
			_shared_sync_flush()


func stop() -> void:
	rotation_controller.stop_interaction()
	cancel_placement()


func handles_action(action_id: String) -> bool:
	return action_id in CONTROL_ACTIONS


func handle_action(action_id: String) -> bool:
	if not handles_action(action_id):
		return false

	match action_id:
		"menu":
			back_requested.emit()
		"place_model":
			if placement_mode:
				placement_controller.confirm(true)
			else:
				_set_placement_mode(true)
		"cancel_placement":
			rotation_controller.stop_interaction()
			cancel_placement()
		"delete_model":
			delete_selected_furniture()
		"duplicate_model":
			if is_furniture() and not get_model_data().is_empty():
				industrial_catalog.select_model(get_model_data().duplicate(true))
		"reset_model":
			_reset_model_placement()
		"scale_down":
			model_viewer.adjust_display_scale(-1.0)
		"scale_up":
			model_viewer.adjust_display_scale(1.0)

	return true


func sync_control_labels() -> void:
	if wrist_menu == null:
		return
	if placement_mode:
		wrist_menu.set_control_label("place_model", place_button_set_title, place_button_set_subtitle)
	else:
		wrist_menu.set_control_label("place_model", place_button_move_title, place_button_move_subtitle)


func _set_placement_mode(is_enabled: bool) -> void:
	if is_enabled:
		if selected_furniture == null and model_viewer.current_model_path == "":
			return
		if shared != null and shared.active() and not shared.world_ready():
			# The shared room is not recognised yet: the preview would float
			# in the wrong space (the amber "dot in the void" of the field log)
			# and the placement would land outside the shared frame.
			status_changed.emit("Spazio condiviso non riconosciuto ancora: attendo io, riprova a posare")
			return
		if is_furniture() and selected_furniture == null and furniture_items.size() >= max_furniture \
				and not (shared != null and shared.active()):
			model_viewer.visible = false
			status_changed.emit("8 arredi presenti · elimina un oggetto per aggiungerne un altro")
			return
		if shared != null and shared.active() and selected_furniture != null \
				and not _shared_sync_pending \
				and (selected_furniture.net_id < 0 or not shared.can_grab(selected_furniture.net_id)):
			status_changed.emit("Questo arredo non è tuo o è già in presa")
			return
		before_placement = selected_furniture.global_transform if selected_furniture != null else model_viewer.global_transform
		placement_controller.require_floor = is_furniture()
		manual_wall_rotation = false
		if selected_furniture != null:
			selected_furniture.move_model_to(model_viewer)
			model_viewer.global_transform = selected_furniture.global_transform
			model_viewer.model_yaw = selected_furniture.model_yaw
			model_viewer.rotate_model_manual(0)
			selected_furniture.set_interactive(false)
		elif is_furniture():
			XR_SURFACE_PLACEMENT.orient_node_to_camera_yaw(model_viewer, get_viewport().get_camera_3d())
		model_viewer.visible = true
		model_viewer.set_ghost(true)
		if is_furniture():
			var seed := _viewer_box_pose()
			if selected_furniture == null:
				var camera := get_viewport().get_camera_3d()
				if camera != null:
					seed.origin.x = camera.global_position.x
					seed.origin.z = camera.global_position.z
				seed.origin.y = placement_controller.floor_y + model_viewer.current_model_bounds_anchor.size.y * 0.5
			room_body.reset_box(model_viewer.current_model_bounds_anchor.size, seed)
	placement_mode = is_enabled
	rotation_controller.allow_hold = not is_enabled
	placement_controller.dragging = gesture_moving
	sync_control_labels()

	if placement_mode:
		placement_controller.begin()
	else:
		placement_controller.cancel()

	rotation_controller.set_input_blocked(false)
	if not placement_mode:
		model_viewer.set_ghost(false)
	model_state_changed.emit()


func _on_placement_target_updated(target_info: Dictionary) -> void:
	if not placement_mode:
		return
	_apply_placement_target(target_info)
	var valid: bool = target_info.get("valid", true)
	model_viewer.set_ghost(true, valid)
	if not valid:
		status_changed.emit("Spazio insufficiente o superficie non adatta · sposta l’anteprima")
	elif gesture_moving:
		status_changed.emit("Trascina · rilascia per posare · due pinch per ruotare")
	elif target_info.get("wall_contact", false):
		status_changed.emit("Appoggiato alla parete · scorri lungo il muro, pinch per posare")
	elif not target_info.get("has_surface", false):
		status_changed.emit("Pavimento stimato · rilascia e fai pinch per posare")
	else:
		status_changed.emit("Superficie rilevata · rilascia e fai pinch per posare")


func _on_placement_confirmed(target_info: Dictionary) -> void:
	if not placement_mode or not target_info.get("valid", true):
		return
	# A single pinch places: the stray-pinch case is already covered by the
	# base controller (the catalog pinch is consumed by begin() and a press
	# with the finger still on a UI button is swallowed by is_pointing_at_ui).
	_apply_placement_target(target_info)
	rotation_controller.block_after_placement()
	_set_placement_mode(false)
	if is_furniture():
		if selected_furniture == null:
			selected_furniture = FurnitureItemScene.instantiate()
			get_parent().get_parent().add_child(selected_furniture)
			furniture_items.append(selected_furniture)
			selected_furniture.selected.connect(_on_furniture_selected)
		selected_furniture.capture(model_viewer)
		selected_furniture.set_interactive(true)
		model_viewer.visible = false
		rotation_controller.set_input_blocked(false)
		if shared != null and shared.active():
			if selected_furniture.net_id == 0:
				shared.register_placed_item(selected_furniture)
				_shared_sync_pending = false
			else:
				_shared_sync_flush()
		status_changed.emit("%d/%d arredi · due pinch: ruota · tieni 1 s: sposta · scheda: aggiungi copia" % [furniture_items.size(), max_furniture])
	else:
		_create_model_spatial_anchor()
		_shared_sync_pending = false
		status_changed.emit("Modello posato · seleziona i punti info per esplorarlo")
	model_state_changed.emit()


func _apply_placement_target(target_info: Dictionary) -> void:
	if target_info.has("model_transform"):
		model_viewer.global_transform = target_info.model_transform
		return
	var surface_point := Vector3.ZERO
	var point_value: Variant = target_info.get("point", Vector3.ZERO)
	if point_value is Vector3:
		surface_point = point_value as Vector3

	model_viewer.global_position = XR_SURFACE_PLACEMENT.get_node_root_from_surface_point(model_viewer, surface_point)
	if not is_furniture():
		XR_SURFACE_PLACEMENT.orient_node_to_camera_yaw(model_viewer, get_viewport().get_camera_3d())


func _create_model_spatial_anchor() -> void:
	var model_data := get_model_data()
	var selected_model_id: String = str(model_data.get("id", ""))
	if not auto_anchor_placed_models or selected_model_id == "":
		return

	var scene_services := get_tree().get_first_node_in_group("xr_scene_services") as XRRoot3D
	if scene_services == null:
		return

	scene_services.create_spatial_anchor(
		model_viewer.global_transform,
		{
			"type": "industrial_model",
			"model_id": selected_model_id,
			"title": str(model_data.get("title", selected_model_id)),
			"created_at": Time.get_datetime_string_from_system(true),
		}
	)


func _reset_model_placement() -> void:
	cancel_placement()
	rotation_controller.stop_interaction()
	model_viewer.global_transform = default_model_viewer_transform
	model_viewer.reset_model_view()


func is_furniture() -> bool:
	return get_model_data().get("collection", "industrial") == "furniture"


func get_model_data() -> Dictionary:
	return selected_furniture.model_data if selected_furniture != null else model_viewer.current_model_data


func prepare_selection() -> void:
	cancel_placement()
	if not selecting_placed:
		if selected_furniture != null:
			selected_furniture.mark_selected(false)
		selected_furniture = null
	model_viewer.visible = false
	model_viewer.set_ghost(true)
	if not selecting_placed:
		rotation_controller.set_input_blocked(true)
	model_state_changed.emit()


func on_model_loaded(success: bool) -> void:
	if not success:
		rotation_controller.set_input_blocked(false)
		status_changed.emit("Caricamento non riuscito · scegli di nuovo il modello")
		return
	model_viewer.visible = selected_furniture == null
	model_viewer.set_ghost(false)
	rotation_controller.set_input_blocked(false)
	if is_furniture() and selected_furniture == null:
		_set_placement_mode(true)
	elif selected_furniture != null:
		status_changed.emit("%s · due pinch per ruotare, tieni 1 s per spostare" % selected_furniture.model_data.get("title", "Arredo"))
	else:
		status_changed.emit("Esplora il modello · punti info, animazione e posizionamento")


func cancel_placement() -> void:
	placement_cancelled.emit()
	gesture_moving = false
	placement_controller.confirm_suppressed = false
	if placement_mode:
		model_viewer.global_transform = before_placement
		model_viewer.set_ghost(false)
		if selected_furniture != null:
			selected_furniture.capture(model_viewer)
	_set_placement_mode(false)
	if selected_furniture != null:
		selected_furniture.set_interactive(true)
	if is_furniture():
		model_viewer.visible = false
		rotation_controller.set_input_blocked(false)
	status_changed.emit("Anteprima annullata · gli arredi posati restano nella stanza")
	model_state_changed.emit()


func _on_furniture_selected(item: Node3D) -> void:
	if selection_blocked:
		return # The shared lobby owns the panel space; furniture stays put.
	if placement_mode:
		return # A placement pinch belongs to the ghost, not furniture behind it.
	if item != selected_furniture:
		cancel_placement()
		model_viewer._clear_current_model()
		model_viewer.visible = false
		if selected_furniture != null:
			selected_furniture.mark_selected(false)
		selected_furniture = item
		selected_furniture.mark_selected(true)
	# A repeated selection reopens its information without moving or loading it.
	selecting_placed = true
	industrial_catalog.select_model(item.model_data)
	selecting_placed = false
	status_changed.emit("%s · due pinch per ruotare, tieni 1 s per spostare" % item.model_data.get("title", "Arredo"))


func delete_selected_furniture() -> void:
	rotation_controller.stop_interaction()
	gesture_candidates.clear()
	direct_candidates.clear()
	cancel_placement()
	if selected_furniture == null:
		return
	if shared != null and shared.active() and selected_furniture.net_id > 0:
		# Host-authoritative: the delete echo frees the node (and the host
		# validator decides who had the right to ask).
		shared.submit_delete(selected_furniture.net_id)
		return
	if shared != null and shared.active() and selected_furniture.net_id < 0:
		shared.cancel_pending_place(selected_furniture.net_id)
	furniture_items.erase(selected_furniture)
	selected_furniture.set_interactive(false)
	selected_furniture.queue_free()
	selected_furniture = null
	model_viewer.clear_viewer()
	status_changed.emit("Arredo eliminato · %d/%d nella stanza" % [furniture_items.size(), max_furniture])
	model_state_changed.emit()


func _viewer_box_pose() -> Transform3D:
	return model_viewer.model_anchor.global_transform * Transform3D(Basis.IDENTITY, model_viewer.current_model_bounds_anchor.get_center())


func _constrain_target(info: Dictionary) -> Dictionary:
	if not placement_mode:
		return info
	var root_pose := model_viewer.global_transform
	var point: Vector3 = info.point
	if gesture_moving and rotation_controller.tracking_suspended:
		info["model_transform"] = root_pose
		info["point"] = root_pose.origin + Vector3.UP * model_viewer.model_floor_y
		info["valid"] = placement_controller.last_target_info.get("valid", false)
		return info
	if gesture_moving:
		var sample := XRModelRotationController3D.hand_sample(rotation_controller.drag_hand)
		if grab_direct and not sample.is_empty():
			root_pose.origin = grab_start_pose.origin + (sample.tip - grab_start_tip)
		else:
			var ray := placement_controller.get_source_transform()
			var camera := get_viewport().get_camera_3d()
			var reach := camera.global_position.distance_to(sample.tip) if camera != null and not sample.is_empty() else grab_start_reach
			var depth := XR_SURFACE_PLACEMENT.drag_depth(grab_depth, grab_start_reach, reach, remote_depth_gain)
			root_pose.origin = ray.origin - ray.basis.z.normalized() * depth + grab_offset
		if is_furniture():
			root_pose.origin.y = grab_start_pose.origin.y
		point = root_pose.origin + Vector3.UP * model_viewer.model_floor_y
		info.valid = true
	elif is_furniture():
		root_pose.origin = XR_SURFACE_PLACEMENT.get_node_root_from_surface_point(model_viewer, point)
	else:
		return info
	if is_furniture():
		var local_box := model_viewer.model_anchor.transform * Transform3D(Basis.IDENTITY, model_viewer.current_model_bounds_anchor.get_center())
		var result := room_body.solve(root_pose * local_box, not manual_wall_rotation and model_viewer.current_model_data.get("wall_snap", false))
		root_pose = result.pose * local_box.affine_inverse()
		info["wall_contact"] = result.wall_contact
		info["valid"] = bool(info.get("valid", false)) and result.valid
	info["model_transform"] = root_pose
	info["point"] = Vector3(root_pose.origin.x, point.y, root_pose.origin.z)
	return info


func _can_start_gesture(hand: String) -> bool:
	if not rotation_controller.dragging and not rotation_controller.rotating and placement_controller.is_pointing_at_ui(hand):
		return false
	if placement_mode:
		return not placement_controller.is_pointing_at_ui(hand) and model_viewer.is_ray_over_current_model(placement_controller.get_source_transform(hand).origin, -placement_controller.get_source_transform(hand).basis.z)
	if rotation_controller.dragging or rotation_controller.rotating:
		return is_instance_valid(gesture_candidates.get(hand))
	var held_item: Node3D = gesture_candidates.get(hand) if rotation_controller.holding and rotation_controller.drag_hand == hand else null
	var was_direct: bool = direct_candidates.get(hand, false)
	gesture_candidates.erase(hand)
	direct_candidates[hand] = false
	var ray := placement_controller.get_source_transform(hand)
	var sample := XRModelRotationController3D.hand_sample(hand)
	var candidates: Array[Node3D] = furniture_items.duplicate()
	if model_viewer.visible and not model_viewer.ghost_enabled and model_viewer.current_model_path != "":
		candidates.append(model_viewer)
	var best_distance := INF
	for item in candidates:
		if held_item != null and item != held_item:
			continue
		if not item.is_visible_in_tree():
			continue
		var box_pose: Transform3D = _viewer_box_pose() if item == model_viewer else item.global_transform * item.box_local_transform
		var size: Vector3 = model_viewer.current_model_bounds_anchor.size if item == model_viewer else item.bounds.size
		var bounds := AABB(-size * 0.5, size).grow(0.025)
		var inverse := box_pose.affine_inverse()
		if XRModelRotationController3D.usable(sample) and bounds.has_point(inverse * sample.tip):
			gesture_candidates[hand] = item
			direct_candidates[hand] = true
			return true
		if held_item != null and was_direct:
			continue
		if placement_controller.is_pointing_at_ui(hand):
			continue
		var hit: Variant = bounds.intersects_ray(inverse * ray.origin, inverse.basis * -ray.basis.z.normalized())
		if hit is Vector3:
			var distance := ray.origin.distance_to(box_pose * hit)
			if distance < best_distance and distance <= 4.5:
				best_distance = distance
				gesture_candidates[hand] = item
	var over_target := gesture_candidates.has(hand)
	if held_item != null:
		gesture_candidates[hand] = held_item
		direct_candidates[hand] = was_direct
	if over_target and shared != null and shared.active():
		var item: Node3D = gesture_candidates[hand]
		if item != model_viewer and item.net_id != 0 \
				and not (item.net_id > 0 and shared.can_grab(item.net_id)):
			over_target = false
			gesture_candidates.erase(hand)
	return over_target


func _select_gesture_target() -> void:
	placement_controller.set_active_hand(rotation_controller.drag_hand)
	var item: Node3D = gesture_candidates.get(rotation_controller.drag_hand)
	if is_instance_valid(item) and item != model_viewer and item != selected_furniture:
		_on_furniture_selected(item)


func _show_hold_progress(seconds: float) -> void:
	if seconds > 0 and not placement_mode:
		_select_gesture_target()
		status_changed.emit("Mantieni il pinch · %.1f / 1 s" % minf(seconds, 1))


func _begin_gesture_move() -> void:
	if placement_mode:
		return
	_select_gesture_target()
	grab_start_pose = selected_furniture.global_transform if selected_furniture != null else model_viewer.global_transform
	var ray := placement_controller.get_source_transform()
	grab_depth = maxf(0.05, (grab_start_pose.origin - ray.origin).dot(-ray.basis.z.normalized()))
	grab_offset = grab_start_pose.origin - (ray.origin - ray.basis.z.normalized() * grab_depth)
	var sample := XRModelRotationController3D.hand_sample(rotation_controller.drag_hand)
	grab_direct = direct_candidates.get(rotation_controller.drag_hand, false) and not sample.is_empty()
	grab_start_tip = sample.get("tip", Vector3.ZERO)
	var camera := get_viewport().get_camera_3d()
	grab_start_reach = camera.global_position.distance_to(grab_start_tip) if camera != null and not sample.is_empty() else 0.0
	gesture_moving = true
	_shared_grab_begin()
	_set_placement_mode(true)
	placement_controller.confirm_suppressed = true


func _finish_gesture_move(tracked: bool) -> void:
	if not gesture_moving:
		return
	if tracked:
		placement_controller.confirm(true)
		if placement_mode:
			cancel_placement()
	else:
		cancel_placement()
	gesture_moving = false
	placement_controller.dragging = false
	placement_controller.confirm_suppressed = false


## Shared session: a drag or rotation on a net item starts by reserving the
## physical lock through the host. The final pose is sent when the gesture
## ends (see _shared_sync_flush), which also releases the lock.
func _shared_grab_begin() -> void:
	if shared == null or not shared.active() or _shared_sync_pending:
		return
	if selected_furniture != null and selected_furniture.net_id > 0:
		shared.submit_grab(selected_furniture.net_id)
		_shared_sync_pending = true


func _shared_sync_flush() -> void:
	_shared_sync_pending = false
	if shared == null or not shared.active():
		return
	if selected_furniture != null and selected_furniture.net_id > 0:
		shared.submit_move(selected_furniture.net_id,
			shared.to_room_pose(selected_furniture.global_transform), selected_furniture.model_yaw)


## Live preview during a drag or rotation (issue #19): the pose the local
## user is steering goes out at ~10 Hz so the other headsets follow the
## motion instead of waiting for the release.
func _shared_sync_throttled() -> void:
	if shared == null or not shared.active():
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now < _shared_drag_due:
		return
	_shared_drag_due = now + SHARED_DRAG_INTERVAL
	if selected_furniture == null or selected_furniture.net_id <= 0:
		return
	var live := model_viewer if placement_mode else selected_furniture
	shared.submit_drag(selected_furniture.net_id,
		shared.to_room_pose(live.global_transform), live.model_yaw)


func _rotate_continuous(angle: float) -> void:
	if not placement_mode:
		_select_gesture_target()
	_shared_grab_begin()
	manual_wall_rotation = true
	placement_controller.pending_pinch_confirm = false
	if not is_furniture():
		model_viewer.rotate_model_manual(angle)
		return
	if placement_mode:
		var desired := room_body.global_transform
		desired.basis = Basis(Vector3.UP, angle) * desired.basis
		var result := room_body.solve(desired)
		var local_box := model_viewer.model_anchor.transform * Transform3D(Basis.IDENTITY, model_viewer.current_model_bounds_anchor.get_center())
		model_viewer.global_transform = result.pose * local_box.affine_inverse()
	elif selected_furniture != null:
		var item = selected_furniture
		var local_box: Transform3D = item.box_local_transform
		var desired: Transform3D = item.global_transform * local_box
		room_body.reset_box(item.bounds.size, desired)
		desired.basis = Basis(Vector3.UP, angle) * desired.basis
		var result := room_body.solve(desired)
		if result.valid:
			item.global_transform = result.pose * local_box.affine_inverse()
