extends Node
class_name SharedIndustrialState
## Host-authoritative multi-user layer for the industrial demo: placed
## furniture, per-user permission modes and physical grab locks. The hero
## viewer is a local preview (per-user selection), so only placed items are
## shared. The transport (scripts/net) stays content-agnostic; this node owns
## the "world" dictionary, the host-side validator and the scene-side apply.

signal status_changed(message: String)
signal connection_changed()
signal intent_applied(intent: String, payload: Dictionary)
signal room_list_changed()
signal alignment_changed(ready: bool)

const SessionScript := preload("res://scripts/net/xr_net_session.gd")
const ColocationScript := preload("res://scripts/net/xr_net_colocation.gd")
const LifecycleScript := preload("res://scripts/demos/industrial/shared_room_lifecycle.gd")
const CursorsScript := preload("res://scripts/demos/industrial/shared_user_cursors.gd")
const ValidatorScript := preload("res://scripts/demos/industrial/shared_world_validator.gd")
const SpawnerScript := preload("res://scripts/demos/industrial/shared_item_spawner.gd")
const ViewerScene := preload("res://scenes/demos/industrial/IndustrialModelViewer.tscn")
## Exposed for the industrial check; the spawner owns the shared spawns.
const FurnitureItemScene := preload("res://scenes/demos/industrial/FurnitureItem.tscn")
## Safety net (issue #18): the scene is re-applied from the world dict this
## often, healing lost spawns and silent drops even when no event arrives.
const RECONCILE_INTERVAL := 2.0
## Colori assegnati ai partecipanti (in ordine, si ripetono se i peer sono di più).
@export var user_colors: Array[Color] = [
	Color("2ed3c0"), Color("f2a65a"), Color("8f7bf7"), Color("e05d5d"),
	Color("63c96b"), Color("d982b8"), Color("5aa9e6"), Color("c9b458"),
]

@export var session_name := "Demo Industriale"
@export var user_name := "Operatore"

## Scene references wired by the demo before the first _process step.
var viewer: Node3D
var placement_controller: Node
var catalog: Node
var xr_origin: XROrigin3D
var camera: Camera3D

var session: Node
var colocation: Node
## Room lifecycle (issue #29): host/join/leave/rejoin and the auto-rejoin backoff.
var lifecycle: LifecycleScript
## Remote hand cursors (issue #29): the per-peer pointer pairs in the room.
var cursors: CursorsScript
## Host-side world validator (issue #29): the only writer of the world dict.
var validator: ValidatorScript
## Shared furniture spawner (issue #29): the async model-load queue.
var spawner: SpawnerScript
var room: Node3D
var aligned := false
var _ever_aligned := false

var _hidden_viewer: Node3D
var _pending_place: Dictionary = {}
var _net_items: Dictionary = {}
var _tmp_counter := 0
var _pose_due := 0.0
var _reconcile_due := 0.0
var _drag_targets: Dictionary = {}


func _ready() -> void:
	session = SessionScript.new()
	session.name = "Session"
	session.session_name = session_name
	add_to_group("shared_state")
	var model_known := func(model_id: String) -> bool:
		return is_instance_valid(catalog) and not catalog.find_model_by_id(model_id).is_empty()
	validator = ValidatorScript.new(session, model_known)
	session.on_intent = validator.validate
	session.status_changed.connect(_emit_status)
	session.rooms_updated.connect(_on_rooms_updated)
	session.state_updated.connect(_on_state_updated)
	session.intent_applied.connect(_on_intent_applied)
	session.intent_rejected.connect(_on_intent_rejected)
	session.player_joined.connect(_on_player_joined)
	add_child(session)
	lifecycle = LifecycleScript.new(session)
	lifecycle.status_changed.connect(_emit_status)
	lifecycle.connection_changed.connect(connection_changed.emit)
	lifecycle.connection_edge.connect(_on_connection_edge)
	lifecycle.room_hosted.connect(_seed_world)
	room = Node3D.new()
	room.name = "SharedRoom"
	add_child(room)
	cursors = CursorsScript.new(session, room, user_colors)
	colocation = ColocationScript.new()
	colocation.name = "Colocation"
	add_child(colocation)
	_hidden_viewer = ViewerScene.instantiate()
	_hidden_viewer.name = "SharedSpawnViewer"
	_hidden_viewer.visible = false
	add_child(_hidden_viewer)
	var model_lookup := func(model_id: String) -> Variant:
		return catalog.find_model_by_id(model_id) if is_instance_valid(catalog) else null
	spawner = SpawnerScript.new(_hidden_viewer, room, model_lookup, world_ready)
	spawner.item_spawned.connect(_on_item_spawned)


func _process(_delta: float) -> void:
	lifecycle.tick()
	if not session.connected:
		return
	_expire_pending_places()
	if not _room_ready():
		return
	_smooth_drag_targets(_delta)
	# Safety net (issue #18): re-apply the world periodically so a failed spawn or a lost echo heals by itself.
	if _now() >= _reconcile_due:
		_reconcile_due = _now() + RECONCILE_INTERVAL
		_reconcile_world()
	if _now() < _pose_due:
		return
	_pose_due = _now() + 0.05
	var inverse := room.global_transform.affine_inverse()
	var head := inverse * camera.global_transform if camera != null else Transform3D.IDENTITY
	var left: Variant = _hand_transform("left_hand_controller")
	var right: Variant = _hand_transform("right_hand_controller")
	session.submit_pose(head,
		left if left != null else Transform3D.IDENTITY,
		right if right != null else Transform3D.IDENTITY,
		left != null, right != null)
	cursors.refresh()


func _hand_transform(group: String) -> Variant:
	var controller := get_tree().get_first_node_in_group(group) as XRController3D
	if controller != null and controller.get_has_tracking_data():
		return controller.global_transform
	return null


## Demo wiring: viewer and placement controller exist in the scene; the XR
## origin/camera arrive once the XR session is live. The state is persistent
## (issue #17), so this is (re)bound on every demo load: existing shared
## furniture is re-registered with the fresh placement controller.
func setup_context(p_viewer: Node3D, p_placement: Node, p_catalog: Node) -> void:
	viewer = p_viewer
	placement_controller = p_placement
	catalog = p_catalog
	_reattach_items()


## Called when the demo unloads: the session and the shared room survive, only
## the demo-local collaborators go away.
func detach_context() -> void:
	viewer = null
	placement_controller = null
	catalog = null


func _reattach_items() -> void:
	if not is_instance_valid(placement_controller):
		return
	for item in _net_items.values():
		if not is_instance_valid(item):
			continue
		if not item.selected.is_connected(placement_controller._on_furniture_selected):
			item.selected.connect(placement_controller._on_furniture_selected)
		if item not in placement_controller.furniture_items:
			placement_controller.furniture_items.append(item)


## Furniture placed before joining (net_id 0) is a local preview: the shared
## room owns its own items and must not inherit leftovers from the lobby.
## The list is rebuilt (not erased) because a TypedArray cannot erase an
## already-freed instance.
func _clear_local_previews() -> void:
	if placement_controller == null:
		return
	var kept: Array[Node3D] = []
	for item in placement_controller.furniture_items:
		var net_id: Variant = item.get("net_id") if is_instance_valid(item) else null
		if net_id != null and net_id != 0:
			kept.append(item)
		else:
			if placement_controller.selected_furniture == item:
				placement_controller.selected_furniture = null
			if is_instance_valid(item):
				if item.is_inside_tree():
					item.queue_free()
				else:
					item.free()
	placement_controller.furniture_items = kept


func setup_xr(p_origin: XROrigin3D, p_camera: Camera3D) -> void:
	xr_origin = p_origin
	camera = p_camera
	if colocation == null:
		session.require_colocation = false
		aligned = true
		return
	if not colocation.is_connected("alignment_changed", _on_alignment_changed):
		colocation.setup(session, p_origin, p_camera)
		colocation.alignment_changed.connect(_on_alignment_changed)
		colocation.reference_shifted.connect(_on_reference_shifted)
		colocation.status_changed.connect(_emit_status)


func _room_ready() -> bool:
	if not ColocationScript.backend_supported():
		return true
	return aligned


func active() -> bool:
	return session.connected if session != null else false


func hosting() -> bool:
	return session.hosting if session != null else false


func room_code() -> String:
	return session.room_code if session != null else ""


func players() -> Dictionary:
	return session.players if session != null else {}


func rooms() -> Dictionary:
	return session.rooms if session != null else {}


func user_color(peer_id: int) -> Color:
	return cursors.color_for(peer_id)


## Pose in the shared room frame from a scene-global transform.
func to_room_pose(pose: Transform3D) -> Transform3D:
	return room.global_transform.affine_inverse() * pose


func host_room() -> Error:
	return lifecycle.host_room(user_name)


## Host-only rename: the discovery replies carry session_name, so the new
## name reaches every LAN search without extra plumbing.
func rename_room(new_name: String) -> void:
	lifecycle.rename_room(new_name)


func room_name() -> String:
	return str(session.session_name)


func join_room(ip: String) -> Error:
	return lifecycle.join_room(user_name, ip)


func join_room_by_code(code: String) -> Error:
	return lifecycle.join_room_by_code(user_name, code)


func leave_room() -> void:
	lifecycle.leave_room()
	_clear_all_items()
	aligned = false
	_ever_aligned = false
	connection_changed.emit()


## A connection edge (host or client): the shared world follows the link, and
## entering the room voids the local previews: furniture placed before
## joining is not shared.
func _on_connection_edge(connected: bool) -> void:
	_update_world_visibility()
	if connected:
		_clear_local_previews()
	connection_changed.emit()


## The host opened a room: seed the world dict the first snapshot will carry.
func _seed_world() -> void:
	session.world_state = validator.initial_world()
	session.publish_world()


func set_mode(shared: bool) -> void:
	session.submit_intent("mode", {"m": 1 if shared else 0})


func local_mode() -> bool:
	return int(_world().get("modes", {}).get(session.local_peer_id(), 0)) == 1


func reset_world() -> void:
	if hosting():
		session.submit_intent("reset", {})


## Manual recovery for a broken shared reference: the lobby shows a Retry
## button exactly when this reports true, so "Premi Riprova" is never a dead end.
func retry_colocation() -> void:
	if colocation != null:
		colocation.retry()


func colocation_failed() -> bool:
	return colocation != null and colocation.is_failed()


## Permission gate for the gesture layer: can this peer grab the item now?
func can_grab(item_id: int) -> bool:
	if not active():
		return true
	var item: Dictionary = _world().get("items", {}).get(item_id, {})
	if item.is_empty():
		return false
	if int(item.get("h", -1)) != -1:
		return false
	return validator.can_operate(session.local_peer_id(), item)


## Physical grab: reserves the lock through the host before the drag starts.
func submit_grab(item_id: int) -> void:
	session.submit_intent("grab", {"id": item_id})


## Live drag preview (issue #19): throttled pose updates while the item is
## in hand. The lock is kept; only the final move releases it.
func submit_drag(item_id: int, pose: Transform3D, yaw: float) -> void:
	session.submit_intent("drag", {"id": item_id, "t": pose, "y": yaw})


## Drag finished (or cancelled): releases the lock and stores the final pose.
func submit_move(item_id: int, pose: Transform3D, yaw: float) -> void:
	session.submit_intent("move", {"id": item_id, "t": pose, "y": yaw})


func submit_delete(item_id: int) -> void:
	session.submit_intent("delete", {"id": item_id})


func submit_anim(item_id: int, animation: String, playing: bool) -> void:
	session.submit_intent("anim", {"id": item_id, "a": animation, "p": playing})


## Optimistic place: register the captured item under a per-peer temporary id, the host assigns the real one.
func register_placed_item(item: Node3D) -> void:
	_tmp_counter -= 1
	var tmp := _tmp_counter
	item.net_id = tmp
	item.net_owner = session.local_peer_id()
	_net_items[tmp] = item
	_pending_place[tmp] = {"item": item, "at": _now()}
	session.submit_intent("place", {
		"m": str(item.model_data.get("id", "")),
		"t": to_room_pose(item.global_transform),
		"y": item.model_yaw,
		"tmp": tmp,
	})


## Local delete of a still-pending optimistic item: drop the pending entry so
## a late echo cannot rename a freed node.
func cancel_pending_place(tmp: int) -> void:
	_pending_place.erase(tmp)
	_net_items.erase(tmp)


func _world() -> Dictionary:
	return session.world_state


func _on_rooms_updated() -> void:
	room_list_changed.emit()


func _on_state_updated() -> void:
	if not session.hosting and session.connected:
		_reconcile_world()
	cursors.refresh()


func _on_player_joined(_peer_id: int) -> void:
	if session.hosting:
		session.publish_world()


## The runtime re-anchored the tracking origin while the anchor was being
## re-recognised: the visible world follows the physical room instead of
## appearing to have jumped elsewhere. The exact pose comes back with the
## next alignment_changed(true).
func _on_reference_shifted(delta: Transform3D) -> void:
	if _ever_aligned:
		room.global_transform = delta * room.global_transform


func _on_alignment_changed(ready: bool, anchor_transform: Transform3D) -> void:
	aligned = ready and session.connected
	if ready:
		room.global_transform = anchor_transform
		_ever_aligned = true
	elif is_instance_valid(colocation) and not colocation.relocalizing():
		# A brand-new anchor replaces the old one: the last pose is worth
		# nothing and the world must wait for the first alignment again.
		_ever_aligned = false
	# NOTE: on false the room is NOT teleported: while the same anchor is
	# being re-recognised (standby resume) the last pose is the best guess
	# and the furniture stays visible where the user left it.
	_update_world_visibility()
	if aligned:
		# The room frame just moved: every stored pose must be re-applied
		# through it before the world becomes visible again.
		_reconcile_world()
	alignment_changed.emit(aligned)


## The shared world is only trusted once the room is recognised: in shared
## mode the placed furniture stays hidden until the FIRST alignment (point
## of the shared playground: no silent per-device rooms). After that it
## stays visible while the runtime re-recognises the same anchor (e.g. on
## standby resume): the last pose is the best guess and the room frame
## follows the anchor the moment it is found again. The hero viewer is a
## local preview and never waits for alignment.
func world_ready() -> bool:
	return not session.connected or aligned or _ever_aligned


func _update_world_visibility() -> void:
	var show := world_ready()
	for item in _net_items.values():
		if is_instance_valid(item):
			item.visible = show


func _emit_status(message: String) -> void:
	status_changed.emit(message)


func _on_intent_applied(intent: String, payload: Dictionary) -> void:
	match intent:
		"place":
			_apply_place(payload)
		"move":
			_apply_item_pose(payload)
		"drag":
			_apply_drag(payload)
		"grab":
			_apply_grab(payload)
		"delete":
			_apply_delete(payload)
		"anim":
			_apply_anim(payload)
		"reset":
			_reconcile_world()
	intent_applied.emit(intent, payload)


## A freed reference is not null: reading it into a typed variable would
## raise, so every consumer validates the stored node and drops dead entries
## (issue #17: items freed with the demo before the reparent fix).
func _live_item(item_id: int) -> Node3D:
	var item = _net_items.get(item_id)
	if item == null:
		return null
	if not is_instance_valid(item):
		_net_items.erase(item_id)
		return null
	return item


func _apply_item_pose(payload: Dictionary) -> void:
	var item_id := int(payload.get("id", -1))
	var item: Node3D = _live_item(item_id)
	if item == null:
		return
	_drag_targets.erase(item_id)
	item.global_transform = _room_pose(payload.get("t", Transform3D.IDENTITY))
	item.model_yaw = float(payload.get("y", 0.0))
	item.model_anchor.rotation = Vector3(0.0, item.model_yaw, 0.0)
	_set_held(item, int(payload.get("h", -1)))


## Live drag preview (issue #19): the update arrives at ~10 Hz and the item
## slides toward it every frame (see _smooth_drag_targets). The sender's own
## echo is ignored: the local hand is already driving the item.
func _apply_drag(payload: Dictionary) -> void:
	var item_id := int(payload.get("id", -1))
	var item: Node3D = _live_item(item_id)
	if item == null:
		return
	var holder := int(payload.get("h", -1))
	_set_held(item, holder)
	if holder == session.local_peer_id():
		return
	_drag_targets[item_id] = {
		"t": _room_pose(payload.get("t", Transform3D.IDENTITY)),
		"y": float(payload.get("y", 0.0)),
	}


## Receiver-side interpolation (issue #19): a 10 Hz pose stream looks
## continuous when the visible item chases it at frame rate.
func _smooth_drag_targets(delta: float) -> void:
	for item_id in _drag_targets.keys().duplicate():
		var item: Node3D = _live_item(item_id)
		if item == null:
			_drag_targets.erase(item_id)
			continue
		var target: Dictionary = _drag_targets[item_id]
		var goal: Transform3D = target["t"]
		var blend := clampf(delta * 12.0, 0.0, 1.0)
		item.global_transform = item.global_transform.interpolate_with(goal, blend)
		var yaw := float(target["y"])
		item.model_yaw = lerpf(item.model_yaw, yaw, blend)
		item.model_anchor.rotation = Vector3(0.0, item.model_yaw, 0.0)
		if item.global_transform.origin.distance_to(goal.origin) < 0.002 \
				and absf(item.model_yaw - yaw) < 0.01:
			_drag_targets.erase(item_id)


func _apply_grab(payload: Dictionary) -> void:
	var item: Node3D = _live_item(int(payload.get("id", -1)))
	if item != null:
		_set_held(item, int(payload.get("h", -1)))


func _apply_delete(payload: Dictionary) -> void:
	var item_id := int(payload.get("id", -1))
	var item: Node3D = _live_item(item_id)
	if item == null:
		return
	_net_items.erase(item_id)
	_drag_targets.erase(item_id)
	if is_instance_valid(placement_controller):
		if placement_controller.selected_furniture == item:
			placement_controller.selected_furniture = null
		placement_controller.furniture_items.erase(item)
	item.set_interactive(false)
	item.queue_free()
	if is_instance_valid(placement_controller):
		placement_controller.model_state_changed.emit()


func _apply_anim(payload: Dictionary) -> void:
	var item: Node3D = _live_item(int(payload.get("id", -1)))
	if item == null:
		return
	var players := item.find_children("*", "AnimationPlayer", true, false)
	var player: AnimationPlayer = players[0] if not players.is_empty() else null
	if player == null:
		return
	if bool(payload.get("p", false)):
		player.play(str(payload.get("a", "")))
	else:
		player.pause()


func _room_pose(pose: Transform3D) -> Transform3D:
	return room.global_transform * pose


func _set_held(item: Node3D, peer_id: int) -> void:
	item.net_held_by = peer_id
	if peer_id >= 0:
		item.selection_label.text = "IN PRESA · %s" % _player_name(peer_id)
		item.selection_label.modulate = user_color(peer_id)
	else:
		item.selection_label.text = "SELEZIONATO"
		item.selection_label.modulate = Color("a2ead8")


func _player_name(peer_id: int) -> String:
	var name := str(session.players.get(peer_id, {}).get("name", ""))
	return name if name != "" else "Utente %d" % (peer_id % 1000)


func _reconcile_world() -> void:
	var world: Dictionary = _world()
	if world.is_empty():
		return
	var items: Dictionary = world.get("items", {})
	for item_id in items.keys():
		var stored: Dictionary = items[item_id]
		if _net_items.has(item_id):
			if not is_instance_valid(_net_items[item_id]):
				# Item freed with the demo before the reparent fix (or a
				# pending place lost on exit): drop the dead reference and
				# respawn it from the shared world.
				_net_items.erase(item_id)
			else:
				_reconcile_existing(item_id, stored)
				continue
		spawner.enqueue({"id": item_id, "m": str(stored.get("m", "")),
			"t": _room_pose(stored.get("t", Transform3D.IDENTITY)),
			"y": float(stored.get("y", 0.0)), "o": int(stored.get("o", -1))})
	# Deletions are the only dangerous direction: a client's world dict is a
	# throttled snapshot that can lag the events already applied (an item
	# placed moments ago is not in it yet). Only prune when the dict is
	# current at the highest applied revision; the next snapshot re-runs
	# this loop through state_updated anyway.
	if session.applied_rev <= session.world_applied_rev:
		for item_id in _net_items.keys().duplicate():
			if not items.has(item_id) and int(item_id) > 0:
				_apply_delete({"id": item_id})


func _reconcile_existing(item_id: int, stored: Dictionary) -> void:
	# A move rejected by the host (or lost with the lock): the local copy may
	# be out of sync. Snap it back to the shared pose, unless someone is
	# holding it or the local user is actively manipulating it.
	if int(stored.get("h", -1)) != -1:
		return
	var item: Node3D = _live_item(item_id)
	if item == null:
		return
	if item.net_held_by != -1 or (is_instance_valid(placement_controller)
			and placement_controller.selected_furniture == item):
		return
	var stored_pose := _room_pose(stored.get("t", Transform3D.IDENTITY))
	if item.global_transform.origin.distance_to(stored_pose.origin) > 0.05:
		_apply_item_pose({"id": item_id, "t": stored.get("t"), "y": float(stored.get("y", 0.0))})


## The spawner finished a model load: the state registers the item in its
## registry and re-attaches it to the placement controller.
func _on_item_spawned(spawn: Dictionary, item: Node3D) -> void:
	if is_instance_valid(placement_controller):
		item.selected.connect(placement_controller._on_furniture_selected)
		placement_controller.furniture_items.append(item)
	_net_items[int(spawn["id"])] = item


func _expire_pending_places() -> void:
	for tmp in _pending_place.keys().duplicate():
		var entry: Dictionary = _pending_place[tmp]
		if _now() - float(entry["at"]) > 3.0:
			_expire_pending_place(tmp, "La stanza non ha confermato la posizione · riprova")


func _expire_pending_place(tmp: int, message: String) -> void:
	if not _pending_place.has(tmp):
		return
	var entry: Dictionary = _pending_place[tmp]
	_pending_place.erase(tmp)
	_net_items.erase(tmp)
	var item: Node3D = entry["item"]
	if is_instance_valid(item):
		if is_instance_valid(placement_controller):
			placement_controller.furniture_items.erase(item)
		item.queue_free()
	_emit_status(message)


## The host refused an intent (issue #18): fail fast instead of letting the
## optimistic copy sit until its timeout.
func _on_intent_rejected(intent: String, reason: String) -> void:
	if intent == "place":
		for tmp in _pending_place.keys().duplicate():
			_expire_pending_place(tmp, "Lo spazio non è allineato · Riprova dal menu"
				if reason == "riferimento" else "Posizione rifiutata dalla stanza.")


func _clear_all_items() -> void:
	for item_id in _net_items.keys().duplicate():
		var item: Node3D = _live_item(item_id)
		if item != null:
			if is_instance_valid(placement_controller):
				placement_controller.furniture_items.erase(item)
			item.set_interactive(false)
			item.queue_free()
	_net_items.clear()
	_drag_targets.clear()
	spawner.clear()
	_pending_place.clear()


func _apply_place(payload: Dictionary) -> void:
	var item_id := int(payload.get("id", -1))
	var tmp := int(payload.get("tmp", 0))
	# tmp is only unique per peer: adopt the pending copy only from the echo
	# of our own place, never from another peer's (issue #30: the host's
	# echoes now reach every peer, so a foreign -1 must not steal the copy).
	if tmp != 0 and int(payload.get("o", -1)) == session.local_peer_id() \
			and _pending_place.has(tmp):
		var entry: Dictionary = _pending_place[tmp]
		_pending_place.erase(tmp)
		var item: Node3D = entry["item"]
		_net_items.erase(tmp)
		if not is_instance_valid(item):
			return # The local optimistic copy was deleted before the echo.
		item.net_id = item_id
		_net_items[item_id] = item
		if item.get_parent() != room:
			# The optimistic copy lives under the demo scene: reparent it to
			# the persistent room node so it survives leaving the demo.
			item.reparent(room, true)
		return
	if _net_items.has(item_id):
		return
	spawner.enqueue({"id": item_id, "m": str(payload.get("m", "")),
		"t": _room_pose(payload.get("t", Transform3D.IDENTITY)),
		"y": float(payload.get("y", 0.0)), "o": int(payload.get("o", -1))})


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
