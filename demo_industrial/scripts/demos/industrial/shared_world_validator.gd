extends RefCounted
## Host-side validator (issue #29): the only writer of the world dict.
## Pure functions over the world table: the session is read for the connected
## peers (permission modes), the model catalog is asked through the Callable
## the state wires in. Returns the broadcast payload or null to reject.

const MAX_SHARED_ITEMS := 40
const ROOM_LIMIT := 12.0

var session: Node
var model_known: Callable


func _init(p_session: Node, p_model_known: Callable) -> void:
	session = p_session
	model_known = p_model_known


static func initial_world() -> Dictionary:
	return {"items": {}, "next_id": 1, "modes": {}}


func validate(peer_id: int, intent: String, payload: Dictionary) -> Variant:
	var world: Dictionary = session.world_state
	if world.is_empty():
		return null
	match intent:
		"place":
			var model_id := str(payload.get("m", ""))
			var pose: Transform3D = payload.get("t", Transform3D.IDENTITY)
			if not model_known.call(model_id) or not _valid_pose(pose) \
					or _furniture_count(world) >= MAX_SHARED_ITEMS:
				return null
			var item_id: int = int(world["next_id"])
			world["next_id"] = item_id + 1
			world["items"][item_id] = {"m": model_id, "t": pose,
				"y": clampf(float(payload.get("y", 0.0)), -PI, PI),
				"s": 1.0, "o": peer_id, "a": "", "p": false, "h": -1}
			return {"id": item_id, "tmp": int(payload.get("tmp", 0)), "m": model_id,
				"t": pose, "y": float(world["items"][item_id]["y"]), "o": peer_id}
		"grab":
			var item := _grab_target(world, payload)
			if item.is_empty():
				return null
			var item_id := int(item["id"])
			if int(item.get("h", -1)) != -1 or not can_operate(peer_id, item):
				return null
			_world_item(world, item_id)["h"] = peer_id
			return {"id": item_id, "h": peer_id}
		"move":
			var item := _grab_target(world, payload)
			if item.is_empty():
				return null
			var item_id := int(item["id"])
			var pose: Transform3D = payload.get("t", Transform3D.IDENTITY)
			if int(item.get("h", -1)) != peer_id or not _valid_pose(pose):
				return null
			var stored: Dictionary = _world_item(world, item_id)
			stored["t"] = pose
			stored["y"] = clampf(float(payload.get("y", 0.0)), -PI, PI)
			stored["h"] = -1
			return {"id": item_id, "t": pose, "y": float(stored["y"]), "h": -1}
		"drag":
			# Live preview (issue #19): same gate as move, but the lock stays.
			var item := _grab_target(world, payload)
			if item.is_empty():
				return null
			var item_id := int(item["id"])
			var pose: Transform3D = payload.get("t", Transform3D.IDENTITY)
			if int(item.get("h", -1)) != peer_id or not _valid_pose(pose):
				return null
			var stored: Dictionary = _world_item(world, item_id)
			stored["t"] = pose
			stored["y"] = clampf(float(payload.get("y", 0.0)), -PI, PI)
			return {"id": item_id, "t": pose, "y": float(stored["y"]), "h": peer_id}
		"delete":
			var item := _grab_target(world, payload)
			if item.is_empty():
				return null
			var item_id := int(item["id"])
			if int(item.get("o", -1)) != peer_id and peer_id != 1:
				return null
			world["items"].erase(item_id)
			return {"id": item_id}
		"anim":
			var item := _grab_target(world, payload)
			if item.is_empty():
				return null
			var item_id := int(item["id"])
			if not can_operate(peer_id, item):
				return null
			var stored: Dictionary = _world_item(world, item_id)
			stored["a"] = str(payload.get("a", "")).left(64)
			stored["p"] = bool(payload.get("p", false))
			return {"id": item_id, "a": str(stored["a"]), "p": bool(stored["p"])}
		"mode":
			var mode := clampi(int(payload.get("m", 0)), 0, 1)
			world["modes"][peer_id] = mode
			return {"peer": peer_id, "m": mode}
		"reset":
			if peer_id != 1:
				return null
			world.clear()
			world.merge(initial_world())
			return {}
	return null


## Owner or host may always act; a non-owner may act while the owner is
## present and in operate mode (the shared-permission gesture).
func can_operate(peer_id: int, item: Dictionary) -> bool:
	var owner := int(item.get("o", -2))
	if owner == peer_id or peer_id == 1:
		return true
	if not session.players.has(owner):
		return false
	return int(session.world_state.get("modes", {}).get(owner, 0)) == 1


func _grab_target(world: Dictionary, payload: Dictionary) -> Dictionary:
	var item_id := int(payload.get("id", -1))
	if not world["items"].has(item_id):
		return {}
	var item: Dictionary = (world["items"][item_id] as Dictionary).duplicate()
	item["id"] = item_id
	return item


func _world_item(world: Dictionary, item_id: int) -> Dictionary:
	return world["items"][item_id]


func _furniture_count(world: Dictionary) -> int:
	return world["items"].size()


func _valid_pose(pose: Transform3D) -> bool:
	if not pose.is_finite():
		return false
	return absf(pose.origin.x) <= ROOM_LIMIT and absf(pose.origin.z) <= ROOM_LIMIT \
		and pose.origin.y >= -0.5 and pose.origin.y <= 5.0
