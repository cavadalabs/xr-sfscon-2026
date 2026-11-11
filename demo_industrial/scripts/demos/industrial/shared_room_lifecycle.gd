extends RefCounted
## Room lifecycle (issue #29): host/join/leave/rejoin for the shared demo.
## Owns the auto-rejoin backoff; the session node is the transport, the state
## node decides what a fresh world looks like and what a leave cleans up.

signal status_changed(message: String)
signal connection_changed()
signal connection_edge(connected: bool)
signal room_hosted()

const REJOIN_DELAY := 1.0
const MAX_REJOIN_ATTEMPTS := 8

var session: Node

var _profile_name := "Operatore"
var _last_join := {}
var _rejoin_at := 0.0
var _rejoin_attempts := 0
var _was_connected := false


func _init(p_session: Node) -> void:
	session = p_session


func host_room(display_name: String) -> Error:
	session.set_profile(display_name, 0)
	_profile_name = display_name
	_last_join = {}
	_rejoin_at = 0.0
	var error: Error = session.host_session()
	if error == OK:
		# The default room name is the code itself: short, unique, and it
		# reads well in the LAN list (the host can rename it later).
		session.session_name = session.room_code
		room_hosted.emit()
		connection_changed.emit()
	return error


## Host-only rename: the discovery replies carry session_name, so the new
## name reaches every LAN search without extra plumbing.
func rename_room(new_name: String) -> void:
	if not session.hosting:
		return
	var cleaned := new_name.strip_edges().left(24)
	if cleaned.is_empty():
		return
	session.session_name = cleaned
	status_changed.emit("Stanza rinominata in %s." % cleaned)
	connection_changed.emit()


func join_room(display_name: String, ip: String) -> Error:
	session.set_profile(display_name, 0)
	_last_join = {"ip": ip}
	_rejoin_attempts = 0
	return session.join_session(ip)


func join_room_by_code(display_name: String, code: String) -> Error:
	session.set_profile(display_name, 0)
	_last_join = {"code": code}
	_rejoin_attempts = 0
	return session.join_by_code(code)


func leave_room() -> void:
	_last_join = {}
	_rejoin_at = 0.0
	session.leave_session()


## Per-frame: track the connection edge (the state reacts to it) and retry a
## dropped join. After a standby drop the user is still in the room, so retry
## the same code/IP with a gentle backoff instead of showing the lobby again.
## Giving up keeps the last state: the user can rejoin manually.
func tick() -> void:
	if session.connected != _was_connected:
		_was_connected = session.connected
		if session.connected:
			_rejoin_attempts = 0
			_rejoin_at = 0.0
		elif not _last_join.is_empty() and not session.hosting:
			# The link dropped (e.g. standby): rejoin without asking the code again.
			_rejoin_at = _now() + 1.0
			status_changed.emit("Mi ricollego alla stanza…")
		connection_edge.emit(bool(session.connected))
	if not session.connected:
		_try_rejoin()


func _try_rejoin() -> void:
	if _rejoin_at == 0.0 or _now() < _rejoin_at:
		return
	if _last_join.is_empty() or session.hosting:
		_rejoin_at = 0.0
		return
	_rejoin_attempts += 1
	if _rejoin_attempts > MAX_REJOIN_ATTEMPTS:
		_rejoin_at = 0.0
		_last_join = {}
		XrDiag.log("rejoin", "gave up after %d attempts" % MAX_REJOIN_ATTEMPTS)
		status_changed.emit("La stanza non risponde: riconnetti il codice.")
		return
	_rejoin_at = _now() + minf(REJOIN_DELAY * _rejoin_attempts, 3.0)
	session.set_profile(_profile_name, 0)
	if _last_join.has("code"):
		XrDiag.log("rejoin", "attempt %d/%d via code %s" % [_rejoin_attempts, MAX_REJOIN_ATTEMPTS, str(_last_join.code)])
		session.join_by_code(str(_last_join.code))
	else:
		XrDiag.log("rejoin", "attempt %d/%d via ip %s" % [_rejoin_attempts, MAX_REJOIN_ATTEMPTS, str(_last_join.ip)])
		session.join_session(str(_last_join.ip))


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
