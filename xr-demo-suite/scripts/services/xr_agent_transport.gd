extends RefCounted
## WebSocket transport (issue #29): socket lifecycle, reconnect timer and the
## packet pump. The protocol and the audio pipeline live in xr_agent_client;
## this class only moves bytes and reports state edges.

signal state_changed(ready_state: WebSocketPeer.State)
signal text_packet(text: String)
signal binary_packet(bytes: PackedByteArray)

const SOCKET_BUFFER_BYTES := 8 * 1024 * 1024
const MAX_QUEUED_PACKETS := 4096

var url := ""
var reconnect_delay_ms := 800
var wants_connection := true
var next_reconnect_ms := 0
var socket: WebSocketPeer
var socket_state: WebSocketPeer.State = WebSocketPeer.STATE_CLOSED


func _init() -> void:
	_create_socket()


func is_open() -> bool:
	return socket != null and socket.get_ready_state() == WebSocketPeer.STATE_OPEN


func is_open_or_connecting() -> bool:
	if socket == null:
		return false
	var ready_state := socket.get_ready_state()
	return ready_state == WebSocketPeer.STATE_OPEN or ready_state == WebSocketPeer.STATE_CONNECTING


## Fresh socket and connect attempt: every attempt starts from a clean peer,
## the same the client did before the split.
func connect_now() -> Error:
	_create_socket()
	if url == "":
		return ERR_CANT_CONNECT
	return socket.connect_to_url(url)


## Close an open or connecting socket; the state edge arrives through poll().
func close() -> void:
	if is_open_or_connecting():
		socket.close()


func schedule_reconnect() -> void:
	if not wants_connection:
		return
	next_reconnect_ms = Time.get_ticks_msec() + reconnect_delay_ms


func poll() -> void:
	if socket == null:
		return
	socket.poll()
	var ready_state: WebSocketPeer.State = socket.get_ready_state() as WebSocketPeer.State
	if ready_state != socket_state:
		socket_state = ready_state
		state_changed.emit(ready_state)
	while socket.get_available_packet_count() > 0:
		var packet: PackedByteArray = socket.get_packet()
		if socket.was_string_packet():
			text_packet.emit(packet.get_string_from_utf8())
		else:
			binary_packet.emit(packet)


func send_json(payload: Dictionary) -> bool:
	if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	return socket.send_text(JSON.stringify(payload)) == OK


func send_binary(bytes: PackedByteArray) -> bool:
	if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	return socket.put_packet(bytes) == OK


func _create_socket() -> void:
	socket = WebSocketPeer.new()
	socket.inbound_buffer_size = SOCKET_BUFFER_BYTES
	socket.outbound_buffer_size = SOCKET_BUFFER_BYTES
	socket.max_queued_packets = MAX_QUEUED_PACKETS
	socket_state = WebSocketPeer.STATE_CLOSED
