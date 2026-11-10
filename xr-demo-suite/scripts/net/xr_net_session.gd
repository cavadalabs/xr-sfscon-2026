extends Node
## Content-agnostic LAN session: ENet host-authoritative rooms with UDP
## discovery, room codes, shared poses, group-anchor metadata and a generic
## intent/world protocol. Game content lives in the host-side `on_intent`
## handler and the `world_state` dictionary owned by the demo, never here.
## All poses use the calibrated room frame; hands 0/1 mean left/right.
## Reliability (issue #18): every accepted intent bumps `world_rev`, events
## carry it, clients ack it, and the host re-sends (then resyncs) anyone
## lagging behind. A client that sees a revision gap asks for a snapshot.

const ValidationScript := preload("res://scripts/net/xr_net_validation.gd")
const CodecScript := preload("res://scripts/net/xr_net_snapshot_codec.gd")
const DiscoveryScript := preload("res://scripts/net/xr_net_discovery.gd")
const LedgerScript := preload("res://scripts/net/xr_net_ack_ledger.gd")

signal state_updated()
signal status_changed(message: String)
signal rooms_updated()
signal anchor_changed()
signal player_joined(peer_id: int)
signal player_left(peer_id: int)
signal intent_applied(intent: String, payload: Dictionary)
signal intent_rejected(intent: String, reason: String)

const PORT := 42424
const MAX_PLAYERS := 10
const TICK := 0.05
const TRACKING_TIMEOUT := 1.0
const WORLD_SEND_INTERVAL := 0.1
const PROFILE_COLORS := 8

## Host-side validator: called as `on_intent(peer_id, intent, payload)`.
## Return null to reject, or a (possibly mutated) payload to apply and
## broadcast via `intent_applied` on every peer.
var on_intent: Callable = Callable()

var players: Dictionary = {}
## Alias to the discovery module's room table (same object, never reassigned).
var rooms: Dictionary = {}
var world_state: Dictionary = {}
var session_name := "Stanza XR"
var room_code := ""
var connected := false
var connecting := false
var hosting := false
var anchor_descriptor: Dictionary = {}
var require_colocation := false
## Monotonic revision of `world_state` (host-authoritative, issue #18).
var world_rev := 0
## Highest revision this peer has applied (clients ack it, host mirrors it).
var applied_rev := 0
## Revision of the `world_state` dict content itself. A client's dict is a
## throttled snapshot (events arrive first): authoritative only when equal.
var world_applied_rev := 0

var _api := SceneMultiplayer.new()
var _discovery := DiscoveryScript.new()
var _last_pose: Dictionary = {}
var _pending_pose: Array = []
var _tick := 0.0
var _connect_started := 0.0
var _world_dirty := false
var _world_sent := 0.0
var _profile_name := ""
var _profile_color := 0
var _acked_rev: Dictionary = {}
var _retry_sent: Dictionary = {}
var _retry_next: Dictionary = {}
var _ledger: LedgerScript
var _event_rev := 0
var _event_intent := ""
var _event_payload: Dictionary = {}
var _event_time := 0.0


func _init() -> void:
	# The ledger operates on the session's own tables: the reconnect check
	# reads _acked_rev and zeroes it to simulate lost acks.
	_ledger = LedgerScript.new(_acked_rev, _retry_sent, _retry_next)
	# The lobby and the checks read session.rooms: keep it the discovery's object.
	rooms = _discovery.rooms
	_discovery.rooms_updated.connect(rooms_updated.emit)
	_discovery.status_changed.connect(status_changed.emit)
	_discovery.join_requested.connect(join_session)


func _enter_tree() -> void:
	# RPC paths are relative to this subtree, including in loopback tests.
	get_tree().set_multiplayer(_api, get_path())
	_api.server_relay = false
	_api.peer_connected.connect(_peer_connected)
	_api.peer_disconnected.connect(_peer_disconnected)
	_api.connected_to_server.connect(_connected_to_server)
	_api.connection_failed.connect(_connection_failed)
	_api.server_disconnected.connect(_server_disconnected)


func _ready() -> void:
	_discovery.start(false)


func _exit_tree() -> void:
	_close_network()
	_discovery.close()
	get_tree().set_multiplayer(null, get_path())


func local_peer_id() -> int:
	return _api.get_unique_id() if connected else 0


## Palette index for a peer, for user colors and ownership labels.
func color_for(peer_id: int) -> int:
	return int(players.get(peer_id, {}).get("color", 0))


## Local identity shown to the other participants.
func set_profile(display_name: String, color: int) -> void:
	_profile_name = display_name.strip_edges().left(24)
	_profile_color = clampi(color, 0, PROFILE_COLORS - 1)
	if hosting:
		_apply_profile(1)
	elif connected:
		_request_profile.rpc_id(1, _profile_name, _profile_color)


func host_session() -> Error:
	leave_session()
	var peer := ENetMultiplayerPeer.new()
	# Godot 4.7 misroutes nonzero max_channels into the receive-bandwidth limit:
	# keep native defaults so ENet does not throttle pose traffic.
	var error := peer.create_server(PORT, MAX_PLAYERS - 1)
	if error != OK:
		status_changed.emit("Impossibile creare la stanza (porta %d occupata?)." % PORT)
		return error
	_api.multiplayer_peer = peer
	hosting = true
	connected = true
	session_name = session_name.strip_edges().left(32)
	if session_name.is_empty():
		session_name = "Stanza XR"
	room_code = "%04d" % randi_range(1000, 9999)
	_add_player(1)
	_discovery.start(true)
	status_changed.emit("Stanza %s aperta · fino a %d persone sulla stessa LAN" % [room_code, MAX_PLAYERS])
	state_updated.emit()
	return OK


func join_session(ip: String) -> Error:
	ip = ip.strip_edges()
	if not ip.is_valid_ip_address() or ":" in ip:
		status_changed.emit("Inserisci l'indirizzo IPv4 dell'host, per esempio 192.168.1.100.")
		return ERR_INVALID_PARAMETER
	XrDiag.log("net-join", "connect %s" % ip)
	leave_session()
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(ip, PORT)
	if error != OK:
		status_changed.emit("Connessione non disponibile: %s" % error_string(error))
		return error
	_api.multiplayer_peer = peer
	connecting = true
	_connect_started = _now()
	status_changed.emit("Connessione a %s…" % ip)
	return OK


## Finds the room with this 4-digit code via a directed discovery query and
## joins it. Same-subnet only; use join_session() when the Wi-Fi isolates clients.
func join_by_code(code: String) -> Error:
	code = code.strip_edges()
	if not code.is_valid_int() or int(code) < 1000 or int(code) > 9999:
		status_changed.emit("Inserisci il codice stanza di 4 cifre mostrato dall'host.")
		return ERR_INVALID_PARAMETER
	XrDiag.log("net-join", "by code %s" % code)
	_discovery.query_code(code)
	_discovery.start(false)
	status_changed.emit("Cerco la stanza %s…" % code)
	return OK


func leave_session() -> void:
	_close_network()
	anchor_descriptor.clear()
	anchor_changed.emit()
	players.clear()
	_last_pose.clear()
	_pending_pose.clear()
	world_state.clear()
	_discovery.cancel_code()
	_discovery.start(false)
	state_updated.emit()
	status_changed.emit("Crea una stanza oppure scegli un host nella LAN.")


func _close_network() -> void:
	connected = false
	connecting = false
	hosting = false
	if _api.multiplayer_peer:
		_api.multiplayer_peer.close()
	_api.multiplayer_peer = null
	_api.clear()
	world_rev = 0
	applied_rev = 0
	world_applied_rev = 0
	_ledger.reset()
	_event_rev = 0
	_event_payload = {}


## Host-only: mark world_state as changed so the snapshot is rebroadcast.
func publish_world() -> void:
	if hosting:
		_world_dirty = true


## Host-only: clear the world and rebroadcast (wired to the demo's reset).
func reset_world() -> void:
	if hosting:
		world_state.clear()
		_world_dirty = true
		world_applied_rev = world_rev


func submit_pose(head: Transform3D, left: Transform3D, right: Transform3D,
		left_active: bool, right_active: bool) -> void:
	if connected and (not require_colocation or not anchor_descriptor.is_empty()):
		_pending_pose = [head, left, right, left_active, right_active]


## Request a world mutation. The host validates it through `on_intent` and
## broadcasts the accepted payload; nothing changes unless the host agrees.
func submit_intent(intent: String, payload: Dictionary) -> void:
	if hosting:
		_accept_intent(1, intent, payload)
	elif connected:
		_request_intent.rpc_id(1, intent, payload, _pending_pose, _anchor_group())
	else:
		XrDiag.log("net-out", "%s dropped: not connected" % intent)


func _accept_intent(peer_id: int, intent: String, payload: Dictionary) -> void:
	if not hosting or on_intent.is_null():
		return
	var result: Variant = on_intent.call(peer_id, intent, payload)
	if result is Dictionary:
		_world_dirty = true
		world_rev += 1
		# The host's world dict is updated in place by on_intent: current at this revision.
		world_applied_rev = world_rev
		_event_rev = world_rev
		_event_intent = intent
		_event_payload = result
		_event_time = _now()
		_ledger.host_applied(world_rev)
		XrDiag.log("net-out", "seq=%d %s peer=%d" % [world_rev, intent, peer_id])
		_event.rpc(world_rev, intent, result)
	else:
		_reject(peer_id, intent, "rifiutato")


func _reject(peer_id: int, intent: String, reason: String) -> void:
	# The host says no: the requester must know, or optimistic copies sit until
	# their timeout (issue #18: never a silent drop).
	XrDiag.log("net-reject", "%s peer=%d %s" % [intent, peer_id, reason])
	if peer_id == 1:
		intent_rejected.emit(intent, reason)
	else:
		_reject_intent.rpc_id(peer_id, intent, reason)


func _process(delta: float) -> void:
	_discovery.poll(delta, {"hosting": hosting, "name": session_name,
		"players": players.size(), "code": room_code, "port": PORT, "max_players": MAX_PLAYERS})
	if connecting and _now() - _connect_started > 8.0:
		_connection_failed()
	if not connected:
		return
	_tick += delta
	if _tick < TICK:
		return
	var step := minf(_tick, 0.1)
	_tick = 0.0
	if not _pending_pose.is_empty():
		if hosting:
			_accept_pose(1, _pending_pose[0], _pending_pose[1], _pending_pose[2], _pending_pose[3], _pending_pose[4])
		else:
			_pose.rpc_id(1, _pending_pose[0], _pending_pose[1], _pending_pose[2], _pending_pose[3], _pending_pose[4], _anchor_group())
		_pending_pose.clear()
	if hosting:
		_expire_tracking()
		_expire_acks()
		if _world_dirty and _now() - _world_sent >= WORLD_SEND_INTERVAL:
			if not _api.get_peers().is_empty():
				_receive_snapshot.rpc(_snapshot_packet())
			else:
				state_updated.emit()
			_world_dirty = false
			_world_sent = _now()
		elif not _api.get_peers().is_empty():
			state_updated.emit()


func _expire_tracking() -> void:
	for peer_id in players:
		if _now() - float(_last_pose[peer_id]) >= TRACKING_TIMEOUT:
			players[peer_id].tracked = false
			players[peer_id].left_active = false
			players[peer_id].right_active = false


## Host-side ACK+retry (issue #18): the ledger decides who is due and arms
## the next backoff window; this loop only performs the network sends.
func _expire_acks() -> void:
	for due in _ledger.pending(players.keys(), _event_rev, _now(), _event_time):
		var peer_id: int = due[0]
		if due[1]:
			_receive_snapshot.rpc_id(peer_id, _snapshot_packet())
			XrDiag.log("net-retry", "peer=%d seq=%d escalated to snapshot" % [peer_id, _event_rev])
		else:
			_event.rpc_id(peer_id, _event_rev, _event_intent, _event_payload)
			XrDiag.log("net-retry", "peer=%d seq=%d re-sent (%d/%d)" % [peer_id, _event_rev, due[2], LedgerScript.MAX_EVENT_RETRIES])


func _add_player(peer_id: int) -> void:
	players[peer_id] = {
		"head": Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0)),
		"left": Transform3D.IDENTITY, "right": Transform3D.IDENTITY,
		"left_active": false, "right_active": false, "tracked": false,
		"name": _profile_name if peer_id == 1 else "",
		# Join-order color: peer ids are reassigned on rejoin, so deriving
		# the color from peer_id would change the user's cursor color.
		"color": _profile_color if peer_id == 1 else (players.size() % PROFILE_COLORS),
	}
	_last_pose[peer_id] = 0.0


func _peer_connected(peer_id: int) -> void:
	if hosting:
		_add_player(peer_id)
		# Every snapshot is complete; late joiners need no spawn history.
		_receive_snapshot.rpc_id(peer_id, _snapshot_packet())
		# The join snapshot is the peer's starting point: only later events
		# can be missing, so only those may be retried (issue #18).
		_ledger.track_peer(peer_id, world_rev)
		player_joined.emit(peer_id)
		status_changed.emit("Stanza %s · %d/%d persone" % [room_code, players.size(), MAX_PLAYERS])


func _peer_disconnected(peer_id: int) -> void:
	if hosting:
		players.erase(peer_id)
		_last_pose.erase(peer_id)
		_ledger.forget_peer(peer_id)
		player_left.emit(peer_id)
		_world_dirty = true
		state_updated.emit()


func _connected_to_server() -> void:
	connecting = false
	connected = true
	_request_profile.rpc_id(1, _profile_name, _profile_color)
	_request_anchor.rpc_id(1)
	status_changed.emit("Connesso · riconoscimento dello spazio condiviso…")
	state_updated.emit()


static func valid_uuid(value: String) -> bool:
	return ValidationScript.valid_uuid(value)


func publish_anchor(group_uuid: String, anchor_uuid: String) -> void:
	if not hosting or not valid_uuid(group_uuid) or not valid_uuid(anchor_uuid):
		return
	anchor_descriptor = {"group": group_uuid, "anchor": anchor_uuid}
	_receive_anchor.rpc(anchor_descriptor)
	anchor_changed.emit()


func clear_anchor() -> void:
	if not hosting:
		return
	anchor_descriptor = {}
	_pending_pose.clear()
	for peer_id in players:
		_suspend_peer(peer_id)
	_receive_anchor.rpc(anchor_descriptor)
	anchor_changed.emit()


func _anchor_group() -> String:
	return str(anchor_descriptor.get("group", ""))


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_anchor() -> void:
	if hosting and players.has(_api.get_remote_sender_id()):
		_receive_anchor.rpc_id(_api.get_remote_sender_id(), anchor_descriptor)


@rpc("authority", "call_remote", "reliable", 0)
func _receive_anchor(descriptor: Dictionary) -> void:
	if not connected or hosting:
		return
	if not descriptor.is_empty() and (descriptor.size() != 2 \
			or not descriptor.get("group") is String or not descriptor.get("anchor") is String \
			or not valid_uuid(descriptor.group) or not valid_uuid(descriptor.anchor)):
		return
	if descriptor != anchor_descriptor:
		anchor_descriptor = descriptor.duplicate()
		suspend_tracking()
		anchor_changed.emit()


func suspend_tracking() -> void:
	_pending_pose.clear()
	if hosting:
		_suspend_peer(1)
	elif connected:
		_suspend_tracking.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable", 0)
func _suspend_tracking() -> void:
	if hosting:
		_suspend_peer(_api.get_remote_sender_id())


func _suspend_peer(peer_id: int) -> void:
	if players.has(peer_id):
		players[peer_id].tracked = false
		players[peer_id].left_active = false
		players[peer_id].right_active = false
		_last_pose[peer_id] = 0.0


func _connection_failed() -> void:
	leave_session()
	status_changed.emit("Host irraggiungibile o stanza piena. Controlla Wi-Fi e indirizzo IP.")


func _server_disconnected() -> void:
	leave_session()
	status_changed.emit("L'host ha chiuso la stanza. Puoi crearne o sceglierne un'altra.")


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _pose(head: Transform3D, left: Transform3D, right: Transform3D,
		left_active: bool, right_active: bool, anchor_group := "") -> void:
	if hosting and anchor_group == _anchor_group():
		_accept_pose(_api.get_remote_sender_id(), head, left, right, left_active, right_active)


func _valid_transform(value: Transform3D) -> bool:
	return ValidationScript.valid_transform(value)


func _accept_pose(peer_id: int, head: Transform3D, left: Transform3D, right: Transform3D,
		left_active: bool, right_active: bool) -> void:
	if require_colocation and anchor_descriptor.is_empty():
		return
	if not players.has(peer_id) or _now() - float(_last_pose[peer_id]) < 0.02:
		return
	if not _valid_transform(head) or not _valid_transform(left) or not _valid_transform(right):
		return
	if (left_active and head.origin.distance_to(left.origin) > 2.2) \
			or (right_active and head.origin.distance_to(right.origin) > 2.2):
		return
	_last_pose[peer_id] = _now()
	var player: Dictionary = players[peer_id]
	player.tracked = true
	player.head = head.orthonormalized()
	player.left = left.orthonormalized()
	player.right = right.orthonormalized()
	player.left_active = left_active
	player.right_active = right_active


func _accept_action_pose(peer_id: int, pose: Array) -> void:
	# Pose + action share one reliable packet, avoiding cross-channel ordering races.
	if pose.size() == 5 and pose[0] is Transform3D and pose[1] is Transform3D \
			and pose[2] is Transform3D and pose[3] is bool and pose[4] is bool:
		_accept_pose(peer_id, pose[0], pose[1], pose[2], pose[3], pose[4])


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_intent(intent: String, payload: Dictionary, pose: Array, anchor_group := "") -> void:
	if hosting and intent.length() <= 32:
		var peer_id := _api.get_remote_sender_id()
		if players.has(peer_id) and anchor_group != _anchor_group():
			# A stale reference frame must be visible, not silently dropped.
			_reject(peer_id, intent, "riferimento")
		elif players.has(peer_id):
			_accept_action_pose(peer_id, pose)
			_accept_intent(peer_id, intent, payload)
		else:
			# Right after a rejoin the peer may not be registered yet: say so
			# instead of dropping the intent (the client would only see the
			# 3s timeout as "Posizione non accettata").
			_reject(peer_id, intent, "non in stanza")


@rpc("authority", "call_local", "reliable", 0)
func _event(rev: int, intent: String, payload: Dictionary) -> void:
	if hosting:
		# Issue #30: the host applies the echo too (state handlers are
		# idempotent: pending copy adopted via tmp, self-drag ignored).
		applied_rev = rev
		intent_applied.emit(intent, payload)
		return
	if not connected or rev <= 0:
		return
	if rev > applied_rev + 1:
		# We missed an event: the broadcast is ordered, so this is a resync
		# request, not a normal path (issue #18).
		XrDiag.log("net-in", "gap %d→%d: requesting snapshot" % [applied_rev, rev])
		_request_snapshot.rpc_id(1)
	applied_rev = maxi(applied_rev, rev)
	XrDiag.log("net-in", "seq=%d %s" % [rev, intent])
	_ack_event.rpc_id(1, rev)
	intent_applied.emit(intent, payload)


@rpc("any_peer", "call_remote", "reliable", 0)
func _ack_event(rev: int) -> void:
	if hosting:
		var peer_id := _api.get_remote_sender_id()
		if players.has(peer_id) and _ledger.ack(peer_id, rev):
			XrDiag.log("net-ack", "peer=%d seq=%d" % [peer_id, rev])


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_snapshot() -> void:
	if hosting and players.has(_api.get_remote_sender_id()):
		var peer_id := _api.get_remote_sender_id()
		XrDiag.log("net-in", "snapshot request from peer=%d" % peer_id)
		_receive_snapshot.rpc_id(peer_id, _snapshot_packet())


@rpc("authority", "call_remote", "reliable", 0)
func _reject_intent(intent: String, reason: String) -> void:
	if not connected or hosting:
		return
	intent_rejected.emit(intent, reason)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_profile(display_name: String, color: int) -> void:
	var peer_id := _api.get_remote_sender_id()
	if hosting and players.has(peer_id):
		_set_profile(peer_id, display_name, color)


func _apply_profile(peer_id: int) -> void:
	_set_profile(peer_id, _profile_name, _profile_color)


func _set_profile(peer_id: int, display_name: String, color: int) -> void:
	players[peer_id].name = str(display_name).left(24)
	players[peer_id].color = clampi(int(color), 0, PROFILE_COLORS - 1)
	_world_dirty = true


func _snapshot_packet() -> PackedByteArray:
	return CodecScript.encode(players, world_state, session_name, room_code, world_rev)


@rpc("authority", "call_remote", "reliable", 0)
func _receive_snapshot(packet: PackedByteArray) -> void:
	if not connected or hosting:
		return
	var data := CodecScript.decode(packet)
	if data.is_empty():
		return
	var peers_meta: Dictionary = data["meta"]
	if int(data["rev"]) < applied_rev:
		# A snapshot older than what we already applied cannot be truth:
		# the 10 Hz dirty broadcast may have raced a late join copy.
		XrDiag.log("net-in", "stale snapshot rev=%d<%d ignored" % [int(data["rev"]), applied_rev])
		return
	for peer_id in peers_meta:
		if not players.has(peer_id):
			_add_player(peer_id)
		var meta: Dictionary = peers_meta[peer_id]
		var player: Dictionary = players[peer_id]
		for key in ["name", "color", "tracked", "left_active", "right_active"]:
			if meta.has(key):
				player[key] = meta[key]
	for peer_id in players.keys():
		if not peers_meta.has(peer_id):
			players.erase(peer_id)
	world_state = data["world_state"]
	session_name = data["session_name"]
	room_code = data["room_code"]
	applied_rev = int(data["rev"])
	# The dict is now a snapshot of this exact revision.
	world_applied_rev = applied_rev
	_ack_event.rpc_id(1, applied_rev)
	XrDiag.log("net-in", "snapshot rev=%d" % applied_rev)
	state_updated.emit()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
