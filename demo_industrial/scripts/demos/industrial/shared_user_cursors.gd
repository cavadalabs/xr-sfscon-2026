extends RefCounted
## Remote hand cursors (issue #29): one colored pointer pair per remote peer,
## parented to the shared room and driven by the session's player table.
## The color palette is the demo's; the session's color_for keeps the cursor
## color in sync with the item ownership labels.

const RemoteHandCursorScene := preload("res://scenes/xr/RemoteHandCursor.tscn")

var session: Node
var room: Node3D
var user_colors: Array[Color] = []

var _cursors: Dictionary = {}


func _init(p_session: Node, p_room: Node3D, p_colors: Array[Color]) -> void:
	session = p_session
	room = p_room
	user_colors = p_colors


func color_for(peer_id: int) -> Color:
	return user_colors[session.color_for(peer_id) % user_colors.size()]


## Spawn/refresh the cursors of the connected peers and free the ones whose
## player is gone.
func refresh() -> void:
	for peer_id in session.players:
		if peer_id == session.local_peer_id():
			continue
		var player: Dictionary = session.players[peer_id]
		var cursor: Dictionary = _cursors.get(peer_id, {})
		if cursor.is_empty():
			var color := color_for(peer_id)
			cursor = {"left": _make_cursor(color), "right": _make_cursor(color)}
			_cursors[peer_id] = cursor
			room.add_child(cursor["left"])
			room.add_child(cursor["right"])
		for hand in range(2):
			var key := "left" if hand == 0 else "right"
			var pointer: MeshInstance3D = cursor[key]
			var visible_hand: bool = bool(player.get("tracked", false)) \
				and bool(player.get("%s_active" % key, false))
			pointer.visible = visible_hand
			if visible_hand:
				pointer.transform = Transform3D(Basis.IDENTITY, (player[key] as Transform3D).origin)
	for peer_id in _cursors.keys().duplicate():
		if not session.players.has(peer_id):
			for key in ["left", "right"]:
				_cursors[peer_id][key].queue_free()
			_cursors.erase(peer_id)


func _make_cursor(color: Color) -> MeshInstance3D:
	var pointer := RemoteHandCursorScene.instantiate() as MeshInstance3D
	var material := (pointer.material_override as StandardMaterial3D).duplicate()
	material.albedo_color = color
	pointer.material_override = material
	return pointer
