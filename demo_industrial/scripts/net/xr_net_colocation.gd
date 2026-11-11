extends Node
## One shared physical reference per LAN room. No user IDs or manual
## calibration. Host creates and shares a group anchor; guests load it.
## Requires the patched OpenXR Vendors (native/openxr/README.md).

signal alignment_changed(ready: bool, anchor_transform: Transform3D)
## Emitted when the runtime re-anchors the tracking origin (e.g. on standby
## resume) while the anchor is not localised: the room must follow this
## delta or the shared world appears to have jumped elsewhere.
signal reference_shifted(delta: Transform3D)
signal status_changed(message: String)

const SessionScript = preload("res://scripts/net/xr_net_session.gd")
const SHARABLE := 2
const OPERATION_TIMEOUT := 25.0
const MAX_ATTEMPTS := 3

@export var floor_height_offset := 0.0
## When the patched backend is missing, keep the session usable without
## alignment: every participant sees the room in their own reference frame.
@export var fallback_without_backend := false

var status_message := "Crea o scegli una stanza."
var localized := false
var _session: Node
var _origin: XROrigin3D
var _camera: Camera3D
var _manager: Node
var _openxr: OpenXRInterface
var _anchor: Node3D
var _entity: RefCounted
var _query: RefCounted
var _connected := false
var _phase := "idle"
var _generation := 0
var _attempts := 0
var _deadline := 0.0
var _retry_at := 0.0
var _group_uuid := ""
var _anchor_uuid := ""
## Host's persistent anchor: retried in place (same UUID) instead of being
## recreated, which would force every client to re-recognise a new point.
var _host_group := ""
var _host_anchor := ""
var _refresh_frames := 0
var _was_focused := false
## UUID of the anchor that was successfully aligned at least once: the pose
## captured for it is still the best guess while the runtime re-recognises it.
var _aligned_anchor := ""
## Last observed reference frame: it changes when the runtime re-anchors the
## tracking origin (e.g. on standby resume), moving the whole global space.
var _reference := Transform3D.IDENTITY
var _reference_seen := false


## True while the SAME anchor is being re-recognised (e.g. after standby):
## the last known pose is still trustworthy, so the world may stay visible
## at its current position instead of being hidden. A brand-new anchor (the
## host recreated it, or the client got a different one) returns false.
func relocalizing() -> bool:
	if localized or _aligned_anchor.is_empty() or _session == null:
		return false
	if _session.hosting:
		return _host_anchor == _aligned_anchor
	return _session.anchor_descriptor.get("anchor", "") == _aligned_anchor


func setup(session: Node, origin: XROrigin3D, camera: Camera3D) -> void:
	XrDiag.log("colo", "setup manager=%s backend=%s" % [
		origin != null and origin.get_node_or_null("SpatialAnchorManager") != null,
		backend_supported()])
	_session = session
	_origin = origin
	_camera = camera
	_openxr = XRServer.find_interface("OpenXR") as OpenXRInterface
	_manager = origin.get_node_or_null("SpatialAnchorManager") if origin != null else null
	_session.require_colocation = true
	_session.state_updated.connect(_on_session_state)
	_session.anchor_changed.connect(_on_anchor_changed)
	if _manager != null:
		_manager.connect("openxr_fb_spatial_anchor_tracked", _on_anchor_tracked)
		_manager.connect("openxr_fb_spatial_anchor_create_failed", _on_create_failed)
	_on_session_state()


func _on_session_state() -> void:
	if _connected == _session.connected:
		return
	_connected = _session.connected
	XrDiag.log("colo", "state cb connected=%s" % _connected)
	stop()
	if _connected:
		_phase = "waiting"
		_set_status("Riconoscimento dello spazio… Guarda intorno a te.")


func _on_anchor_changed() -> void:
	if _session.hosting or not _session.connected:
		return
	if _session.anchor_descriptor.get("group", "") == _group_uuid \
			and _session.anchor_descriptor.get("anchor", "") == _anchor_uuid and not _group_uuid.is_empty():
		return
	stop()
	_phase = "waiting"
	_set_status("Attendo il riferimento condiviso dell'host…")


func _process(_delta: float) -> void:
	if _session == null or not _session.connected or _phase == "idle":
		return
	var reference := XRServer.get_reference_frame()
	if not _reference_seen:
		_reference_seen = true
		_reference = reference
	elif not _reference.is_equal_approx(reference):
		# The runtime re-anchored the tracking origin (standby resume): the
		# anchor pose is not being refreshed right now, so the room must
		# follow the shift itself or the furniture looks displaced.
		if not _aligned_anchor.is_empty():
			reference_shifted.emit(_origin.global_transform * reference
				* _reference.affine_inverse() * _origin.global_transform.affine_inverse())
		_reference = reference
	if not _is_focused():
		_was_focused = false
		_set_localized(false)
		if _deadline > 0.0:
			_deadline = _now() + OPERATION_TIMEOUT
		return
	if not _was_focused:
		_was_focused = true
		if _phase == "tracking":
			# Resume from standby (issue #16): the anchor may expose a stale
			# pose before the runtime re-localizes it. Keep the world hidden
			# until the shared pose is re-validated.
			refresh_tracking()
			return
	if _phase == "waiting":
		if not _backend_supported():
			if fallback_without_backend:
				_phase = "idle"
				_session.require_colocation = false
				_set_status("Allineamento non disponibile: ogni postazione vede la propria stanza.")
				alignment_changed.emit(true, Transform3D.IDENTITY)
			else:
				_fail("Allineamento automatico non disponibile su questo visore.", false)
		elif _session.hosting:
			_resume_host_anchor()
		elif not _session.anchor_descriptor.is_empty():
			_load_shared_anchor()
		return
	if _phase == "error":
		if _retry_at > 0.0 and _now() >= _retry_at:
			_retry_at = 0.0
			_reset_work()
			_phase = "waiting"
		return
	if _phase == "tracking":
		if _refresh_frames > 0:
			_refresh_frames -= 1
			return
		var valid: bool = is_instance_valid(_anchor) and _anchor.call("get_has_tracking_data") \
			and _anchor.global_transform.is_finite()
		_set_localized(valid)
		if valid:
			# Re-localization (or first localization) succeeded: refuel the
			# retry budget so a later tracking loss can still auto-recover.
			_attempts = 0
			alignment_changed.emit(true, _anchor.global_transform)
		elif _deadline == 0.0:
			# Tracking lost (e.g. after standby): arm the re-localization
			# timeout so the fail/retry path re-recognizes the space instead
			# of hiding the world forever.
			_deadline = _now() + OPERATION_TIMEOUT
		elif _now() >= _deadline:
			_fail("Non riconosco il punto comune. Guarda la stessa zona dell'host.")
		return
	if _deadline > 0.0 and _now() >= _deadline:
		_fail("Riconoscimento non riuscito. Guarda la stanza e verifica Internet.")


func _is_focused() -> bool:
	if _camera == null or _openxr == null or not _openxr.is_initialized():
		return false
	if _openxr.get_session_state() != OpenXRInterface.SESSION_STATE_FOCUSED:
		return false
	var tracker := XRServer.get_tracker("head") as XRPositionalTracker
	return tracker != null and tracker.get_pose("default") != null \
		and tracker.get_pose("default").has_tracking_data


func _backend_supported() -> bool:
	return _manager != null and backend_supported()


## True when the patched OpenXR Vendors expose Meta group spatial sharing.
static func backend_supported() -> bool:
	if not ClassDB.class_has_method("OpenXRFbSpatialEntity", "share_with_group") \
			or not ClassDB.class_has_method("OpenXRFbSpatialEntityQuery", "query_by_group") \
			or not Engine.has_singleton("OpenXRFbSpatialEntitySharingExtension"):
		return false
	var extension := Engine.get_singleton("OpenXRFbSpatialEntitySharingExtension")
	return extension != null and extension.has_method("is_spatial_entity_group_sharing_supported") \
		and extension.call("is_spatial_entity_group_sharing_supported")


static func new_group_uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 15) | 64
	bytes[8] = (bytes[8] & 63) | 128
	return canonical_uuid(bytes.hex_encode())


static func canonical_uuid(value: String) -> String:
	var hex := value.replace("-", "").to_lower()
	if hex.length() != 32:
		return ""
	var uuid := "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]
	return uuid if SessionScript.valid_uuid(uuid) else ""


static func anchor_creation_transform(desired_global: Transform3D, origin_global: Transform3D,
		reference_frame: Transform3D) -> Transform3D:
	# Vendors 5.1 manager removes XROrigin, but does not remove the reference frame.
	return origin_global * reference_frame.affine_inverse() * origin_global.affine_inverse() * desired_global


## Host retry: re-track the same shared anchor instead of creating a new one.
## A fresh UUID would make every client re-recognise the space from scratch
## (the cascade that hid the world after the 13:21 field failure). Only once
## the retry budget is exhausted (`_fail` clears the pair) does the host
## create a brand-new anchor.
func _resume_host_anchor() -> void:
	if _host_anchor.is_empty():
		_create_host_anchor()
		return
	_attempts += 1
	_group_uuid = _host_group
	_anchor_uuid = _host_anchor
	_phase = "loading"
	_deadline = _now() + OPERATION_TIMEOUT
	_set_status("Riconosco di nuovo lo spazio…")
	_query = _new_query()
	_query.set("timeout", 15.0)
	_query.set("max_results", 8)
	_query.call("query_by_uuid", [_anchor_uuid])
	_query.connect("openxr_fb_spatial_entity_query_completed_with_result", _on_loaded.bind(_generation), CONNECT_ONE_SHOT)
	var error: int = _query.call("execute")
	if error != OK and _phase == "loading":
		_fail("Riferimento non raggiungibile. Verifica Internet e riprova.")


func _create_host_anchor() -> void:
	_attempts += 1
	_group_uuid = new_group_uuid()
	_session.clear_anchor()
	_phase = "creating"
	_deadline = _now() + OPERATION_TIMEOUT
	_set_status("Creo il riferimento della stanza…")
	var forward := -_camera.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = Vector3.FORWARD
	var floor_frame := _origin.global_transform * XRServer.get_reference_frame()
	var desired := Transform3D(Basis.looking_at(forward.normalized()),
		Vector3(_camera.global_position.x, floor_frame.origin.y + floor_height_offset, _camera.global_position.z))
	_manager.call("create_anchor", anchor_creation_transform(desired, _origin.global_transform, XRServer.get_reference_frame()),
		{"xr_net": get_instance_id(), "generation": _generation})


func _on_anchor_tracked(anchor: Node3D, entity: RefCounted, _is_new: bool) -> void:
	var data: Dictionary = entity.get("custom_data")
	if data.get("xr_net") != get_instance_id():
		return
	if data.get("generation") != _generation or not _session.connected:
		_manager.call("untrack_anchor", entity)
		return
	_anchor = anchor
	_entity = entity
	_anchor_uuid = canonical_uuid(str(entity.get("uuid")))
	if _session.hosting:
		_phase = "enabling"
		_deadline = _now() + OPERATION_TIMEOUT
		if entity.call("is_component_enabled", SHARABLE):
			_share_anchor()
		else:
			entity.connect("openxr_fb_spatial_entity_set_component_enabled_completed", _on_sharable.bind(_generation), CONNECT_ONE_SHOT)
			entity.call("set_component_enabled", SHARABLE, true)
	else:
		_phase = "tracking"
		_deadline = _now() + OPERATION_TIMEOUT
		_set_status("Riconosco il punto comune… Guarda intorno a te.")


func _on_create_failed(_transform: Transform3D, data: Dictionary) -> void:
	if data.get("xr_net") == get_instance_id() and data.get("generation") == _generation:
		_fail("Non riesco a riconoscere la stanza. Guarda intorno a te.")


func _on_sharable(success: bool, component: int, enabled: bool, generation: int) -> void:
	if generation != _generation:
		return
	if not success or component != SHARABLE or not enabled:
		_fail("Condivisione spaziale non disponibile. Controlla i permessi del visore.")
	else:
		_share_anchor()


func _share_anchor() -> void:
	_phase = "sharing"
	_deadline = _now() + OPERATION_TIMEOUT
	_set_status("Condivido il riferimento della stanza…")
	_entity.connect("openxr_meta_spatial_entity_group_shared", _on_shared.bind(_generation), CONNECT_ONE_SHOT)
	if not _entity.call("share_with_group", _group_uuid) and _phase == "sharing":
		_fail("Condivisione non avviata. Verifica Internet e servizi spaziali Meta.")


func _on_shared(success: bool, result: int, generation: int) -> void:
	if generation != _generation:
		return
	XrDiag.log("colo", "share result=%d" % result)
	if not success:
		_fail("Condivisione non riuscita. Verifica Internet e Servizi spaziali avanzati.")
		return
	_phase = "tracking"
	_deadline = _now() + OPERATION_TIMEOUT
	_session.publish_anchor(_group_uuid, _anchor_uuid)
	if _session.hosting:
		_host_group = _group_uuid
		_host_anchor = _anchor_uuid
	_set_status("Riferimento condiviso. Riconosco lo spazio…")


func _new_query() -> RefCounted:
	return ClassDB.instantiate("OpenXRFbSpatialEntityQuery")


func _load_shared_anchor() -> void:
	_attempts += 1
	_group_uuid = _session.anchor_descriptor.group
	_anchor_uuid = _session.anchor_descriptor.anchor
	_phase = "loading"
	_deadline = _now() + OPERATION_TIMEOUT
	_set_status("Riconosco lo spazio dell'host… Guarda intorno a te.")
	_query = _new_query()
	_query.set("timeout", 15.0)
	_query.set("max_results", 8)
	_query.call("query_by_group", _group_uuid)
	_query.connect("openxr_fb_spatial_entity_query_completed_with_result", _on_loaded.bind(_generation), CONNECT_ONE_SHOT)
	var error: int = _query.call("execute")
	if error != OK and _phase == "loading":
		_fail("Riferimento non raggiungibile. Verifica Internet e riprova.")


func _on_loaded(entities: Array, result: int, generation: int) -> void:
	if generation != _generation:
		return
	XrDiag.log("colo", "load result=%d count=%d" % [result, entities.size()])
	_query = null
	if result >= 0:
		for entity: RefCounted in entities:
			if canonical_uuid(str(entity.get("uuid"))) == _anchor_uuid:
				_entity = entity
				entity.set("custom_data", {"xr_net": get_instance_id(), "generation": _generation})
				_phase = "locating"
				_deadline = _now() + OPERATION_TIMEOUT
				_manager.call("track_anchor", entity)
				return
	if _session.hosting:
		_fail("Non riconosco di nuovo il punto comune. Guarda la zona in cui l'avevi creato.")
	else:
		_fail("Non trovo ancora il punto comune. Guarda la stessa zona dell'host.")


func _set_localized(value: bool) -> void:
	if localized == value:
		return
	localized = value
	if not value:
		if is_instance_valid(_session):
			_session.suspend_tracking()
		alignment_changed.emit(false, Transform3D.IDENTITY)
		if _phase == "tracking":
			_set_status("Riconosco di nuovo lo spazio… Guarda intorno a te.")
	else:
		_deadline = 0.0
		_aligned_anchor = _anchor_uuid
		XrDiag.log("colo", "localized anchor=%s group=%s" % [_anchor_uuid, _group_uuid])
		_set_status("Spazio condiviso pronto.")


func refresh_tracking() -> void:
	_set_localized(false)
	# Let XRAnchor3D consume the new reference frame before exposing content again.
	_refresh_frames = 2


func retry() -> void:
	if _session == null or not _session.connected:
		return
	if _phase == "tracking" and is_instance_valid(_anchor):
		refresh_tracking()
		return
	# Keep the host's anchor: a manual retry must re-recognize the SAME point,
	# a new one would force every client to re-localize from scratch.
	stop(true)
	_phase = "waiting"
	_set_status("Riprovo il riconoscimento dello spazio…")


## True when the shared reference is broken and no automatic retry is left:
## the lobby exposes this as a Retry button.
func is_failed() -> bool:
	return _phase == "error" and _retry_at == 0.0


func _fail(message: String, automatic_retry := true) -> void:
	_phase = "error"
	_reset_work()
	_retry_at = _now() + 3.0 if automatic_retry and _attempts < MAX_ATTEMPTS else 0.0
	if _retry_at == 0.0 and _session != null and _session.hosting:
		# Even the saved anchor could not be recovered: the next manual retry
		# must create a brand-new one (the old point may be gone from the device).
		_host_group = ""
		_host_anchor = ""
	_set_status(message + (" Riprovo automaticamente…" if _retry_at > 0.0 else " Premi Riprova."))


func _reset_work() -> void:
	_generation += 1
	_set_localized(false)
	if is_instance_valid(_anchor) and is_instance_valid(_manager) and _entity != null:
		_manager.call("untrack_anchor", _entity)
	_anchor = null
	_entity = null
	_query = null
	_group_uuid = ""
	_anchor_uuid = ""
	_deadline = 0.0


func stop(keep_anchor := false) -> void:
	_phase = "idle"
	_reset_work()
	_attempts = 0
	_retry_at = 0.0
	if not keep_anchor:
		_host_group = ""
		_host_anchor = ""


func _set_status(message: String) -> void:
	if status_message == message:
		return
	status_message = message
	XrDiag.log("colo", "phase=%s msg=%s" % [_phase, message])
	status_changed.emit(message)


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _exit_tree() -> void:
	stop()
