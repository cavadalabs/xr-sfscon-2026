extends RefCounted
## LAN discovery (issue #29): UDP beacon and room table, split from the
## session node. Owns the socket, the room list and the pending join-by-code
## query. The session forwards `rooms` (same Dictionary object) and relays
## the signals, so the lobby and the checks keep reading `session.rooms`.


signal rooms_updated()
signal status_changed(message: String)
## Emitted when a room answering the pending code query is seen.
signal join_requested(ip: String)

const DISCOVERY_PORT := 42425
const DISCOVERY_MAGIC := "xr-shared-industrial-v1"
const JOIN_CODE_PREFIX := "JOIN_CODE:"
const CODE_TIMEOUT := 6.0
const ROOM_TIMEOUT := 3.5

## Read-only for everyone but this module (clear/mutate in place only).
var rooms: Dictionary = {}

var _udp := PacketPeerUDP.new()
var _tick := 0.0
var _pending_code := ""
var _code_deadline := 0.0


## Binds the beacon socket: hosts answer on the fixed port, clients on any.
func start(as_host: bool) -> void:
	_udp.close()
	_udp = PacketPeerUDP.new()
	var error := _udp.bind(DISCOVERY_PORT if as_host else 0, "0.0.0.0")
	if error != OK:
		status_changed.emit("Ricerca LAN non disponibile; usa l'IP dell'host.")
		return
	_udp.set_broadcast_enabled(true)
	_tick = 1.0
	rooms.clear()
	rooms_updated.emit()


func close() -> void:
	_udp.close()


## Start hunting for the room with this 4-digit code (join_by_code).
func query_code(code: String) -> void:
	_pending_code = code
	_code_deadline = _now() + CODE_TIMEOUT


## Drop any pending code query (leave_session).
func cancel_code() -> void:
	_pending_code = ""


## One frame of beacon work. `ctx` is the host-side snapshot the reply needs:
## {"hosting": bool, "name": String, "players": int, "code": String, "port": int}.
func poll(delta: float, ctx: Dictionary) -> void:
	if not _udp.is_bound():
		return
	var hosting := bool(ctx.get("hosting", false))
	# Limit discovery work per frame even if another LAN device floods UDP.
	for packet_index in mini(_udp.get_available_packet_count(), 16):
		var packet := _udp.get_packet()
		var ip := _udp.get_packet_ip()
		var port := _udp.get_packet_port()
		if packet.size() > 512:
			continue
		var message := packet.get_string_from_utf8()
		if hosting and (message == DISCOVERY_MAGIC or message == JOIN_CODE_PREFIX + str(ctx.get("code", ""))):
			_udp.set_dest_address(ip, port)
			_udp.put_packet(JSON.stringify({"protocol": DISCOVERY_MAGIC,
				"name": ctx.get("name", ""), "players": ctx.get("players", 0),
				"port": ctx.get("port", 0), "code": ctx.get("code", "")}).to_utf8_buffer())
		elif not hosting and message.begins_with("{"):
			var data: Variant = JSON.parse_string(message)
			if data is Dictionary and data.get("protocol") == DISCOVERY_MAGIC \
					and data.get("port") == ctx.get("port", 0) and data.get("name") is String \
					and (data.get("players") is float or data.get("players") is int):
				var count := int(data.players)
				if count >= 1 and count <= int(ctx.get("max_players", 10)):
					rooms[ip] = {"name": str(data.name).left(32), "players": count,
						"code": str(data.get("code", "")), "seen": _now()}
					rooms_updated.emit()
					if _pending_code != "" and str(data.get("code", "")) == _pending_code:
						_pending_code = ""
						join_requested.emit(ip)
	# Targeted code queries are broadcast even while the generic list is open.
	_tick += delta
	if _tick >= 1.0:
		_tick = 0.0
		if not hosting:
			_udp.set_dest_address("255.255.255.255", DISCOVERY_PORT)
			_udp.put_packet(DISCOVERY_MAGIC.to_utf8_buffer())
			# Also find a local desktop host when testing multiple windows.
			_udp.set_dest_address("127.0.0.1", DISCOVERY_PORT)
			_udp.put_packet(DISCOVERY_MAGIC.to_utf8_buffer())
			if _pending_code != "":
				_udp.set_dest_address("255.255.255.255", DISCOVERY_PORT)
				_udp.put_packet((JOIN_CODE_PREFIX + _pending_code).to_utf8_buffer())
				_udp.set_dest_address("127.0.0.1", DISCOVERY_PORT)
				_udp.put_packet((JOIN_CODE_PREFIX + _pending_code).to_utf8_buffer())
		for ip in rooms.keys():
			if _now() - float(rooms[ip].seen) > ROOM_TIMEOUT:
				rooms.erase(ip)
				rooms_updated.emit()
	if _pending_code != "" and _now() > _code_deadline:
		_pending_code = ""
		status_changed.emit("Stanza non trovata. Verifica il codice e la stessa rete Wi-Fi.")


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
