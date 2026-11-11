extends RefCounted
## Snapshot wire format (issue #29): deflate-compressed
## [meta, world_state, session_name, room_code, rev]. Pure encode/decode:
## the session node keeps ownership of applying decoded values to its state.


## Presence metadata only (poses ride the unreliable channel). Native
## compression keeps the complete 10-peer snapshot below ENet's MTU.
static func encode(players: Dictionary, world_state: Dictionary,
		session_name: String, room_code: String, world_rev: int) -> PackedByteArray:
	var meta: Dictionary = {}
	for peer_id in players:
		var player: Dictionary = players[peer_id]
		meta[peer_id] = {"name": player.name, "color": player.color,
			"tracked": player.tracked, "left_active": player.left_active,
			"right_active": player.right_active}
	return var_to_bytes([meta, world_state, session_name, room_code, world_rev]).compress(FileAccess.COMPRESSION_DEFLATE)


## Returns {} when the packet is not a well-formed snapshot payload;
## otherwise the five validated fields keyed for the caller.
static func decode(packet: PackedByteArray) -> Dictionary:
	if packet.size() > 16384:
		return {}
	var data: Variant = bytes_to_var(packet.decompress_dynamic(131072, FileAccess.COMPRESSION_DEFLATE))
	if data is Array and data.size() == 5 and data[0] is Dictionary \
			and data[1] is Dictionary and data[2] is String and data[3] is String and data[4] is int:
		return {"meta": data[0], "world_state": data[1], "session_name": data[2],
			"room_code": data[3], "rev": int(data[4])}
	return {}
