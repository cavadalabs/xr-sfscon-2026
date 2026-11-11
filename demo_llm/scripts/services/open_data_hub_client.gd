class_name OpenDataHubClient
extends Node

signal status_changed(status_text: String, color: Color)
signal measurements_updated(updates: Dictionary)
signal request_failed(message: String, checked_at: String)

const METRICS := {"air-temperature": "temperature", "air-humidity": "humidity", "co2-ppm": "co2"}
const UNITS := {"temperature": "°C", "humidity": "%", "co2": "ppm"}
const FUTURE_TOLERANCE_SECONDS := 30.0

@export_multiline var measurements_url := ""
@export var refresh_interval_seconds := 10.0
# NOI indoor streams currently report every 120 s: two cycles plus 60 s transport margin.
@export_range(30.0, 300.0) var max_age_seconds := 300.0
@export var unavailable_source_text := "Open Data Hub · dati non disponibili"

var request: HTTPRequest
var poll_timer: Timer
var request_active := false
var polling := false
var expected_fields: Dictionary = {}
var snapshot: Dictionary = {}


func _ready() -> void:
	request = $HTTPRequest
	request.timeout = 8.0
	poll_timer = $PollTimer


func start_polling(rooms: Array) -> void:
	expected_fields.clear()
	for room: Dictionary in rooms:
		if room.get("city") != "Bolzano":
			continue
		var fields: Array = []
		for datatype in room.get("datatypes", []):
			if METRICS.has(datatype):
				fields.append(METRICS[datatype])
		expected_fields[str(room.get("station_code", ""))] = fields
	polling = true
	poll_timer.wait_time = maxf(5.0, refresh_interval_seconds)
	_request_measurements()
	poll_timer.start()


func stop_polling() -> void:
	polling = false
	poll_timer.stop()
	request.cancel_request()
	request_active = false
	snapshot.clear()
	_publish()


func _process(_delta: float) -> void:
	if not polling:
		return
	var changed := false
	for update: Dictionary in snapshot.values():
		changed = expire_measurements(update) or changed
	if changed:
		_publish()


func _request_measurements() -> void:
	if not polling or request_active:
		return
	request_active = true
	var error := request.request(measurements_url, PackedStringArray([
		"Accept: application/json", "Cache-Control: no-cache", "Pragma: no-cache",
	]))
	if error != OK:
		request_active = false
		_emit_request_failed("Connessione non disponibile")


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	request_active = false
	if not polling:
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_emit_request_failed("Connessione non disponibile")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not parsed is Dictionary or not parsed.get("data") is Array:
		_emit_request_failed("Risposta non valida")
		return
	# A complete snapshot replaces the previous one, including absent stations/metrics.
	snapshot = _parse_measurement_updates(parsed["data"])
	_publish()


func _parse_measurement_updates(rows: Array, now: float = -1.0, ticks: int = -1) -> Dictionary:
	if now < 0.0:
		now = Time.get_unix_time_from_system()
	if ticks < 0:
		ticks = Time.get_ticks_msec()
	var updates := {}
	for code: String in expected_fields:
		updates[code] = {"measurements": {}, "expected_fields": expected_fields[code],
			"checked_at": _format_rome_time_from_unix(int(now)), "source": "Open Data Hub"}
	for row in rows:
		if not row is Dictionary:
			continue
		var code := str(row.get("scode", ""))
		var field := str(METRICS.get(row.get("tname", ""), ""))
		if not updates.has(code) or field not in expected_fields[code]:
			continue
		if row.get("tunit", "") != UNITS[field]:
			continue
		var value: Variant = row.get("mvalue")
		if not (value is float or value is int) or not is_finite(float(value)):
			continue
		if (field == "humidity" and (value < 0 or value > 100)) or (field == "co2" and value < 0):
			continue
		var measured := _parse_odhub_utc_time(str(row.get("mvalidtime", "")))
		var age := now - measured
		if measured <= 0 or age < -FUTURE_TOLERANCE_SECONDS or age >= max_age_seconds:
			continue
		var metrics: Dictionary = updates[code]["measurements"]
		if metrics.has(field) and metrics[field]["measured_at_unix"] >= measured:
			continue
		metrics[field] = {"value": value, "measured_at_unix": measured,
			"expires_at_unix": measured + max_age_seconds,
			"expires_at_ticks_ms": ticks + int((max_age_seconds - age) * 1000),
			"time": _format_rome_time_from_unix(measured)}
	for update: Dictionary in updates.values():
		expire_measurements(update, now, ticks)
	return updates


# Shared by display, map and assistant context. Never refresh a value's lifetime on receipt.
static func expire_measurements(room: Dictionary, now: float = -1.0, ticks: int = -1) -> bool:
	if now < 0.0:
		now = Time.get_unix_time_from_system()
	if ticks < 0:
		ticks = Time.get_ticks_msec()
	var metrics: Dictionary = room.get("measurements", {})
	var changed := false
	var oldest := 0
	for field: String in METRICS.values():
		var metric: Dictionary = metrics.get(field, {})
		if not metric.is_empty() and (now >= float(metric.get("expires_at_unix", 0)) or ticks >= int(metric.get("expires_at_ticks_ms", 0)) or now < float(metric.get("measured_at_unix", 0)) - FUTURE_TOLERANCE_SECONDS):
			metrics.erase(field)
			metric = {}
			changed = true
		var value: Variant = metric.get("value")
		changed = changed or room.get(field) != value
		room[field] = value
		if not metric.is_empty():
			var stamp := int(metric["measured_at_unix"])
			oldest = stamp if oldest == 0 else mini(stamp, oldest)
	room["measurements"] = metrics
	var state := "unavailable" if metrics.is_empty() else ("online" if metrics.size() == room.get("expected_fields", []).size() else "partial")
	changed = changed or room.get("status", "") != state
	room["status"] = state
	room["last_updated"] = _format_rome_time_from_unix(oldest)
	return changed


func _publish() -> void:
	var count := 0
	for update: Dictionary in snapshot.values():
		expire_measurements(update)
		count += update["measurements"].size()
	measurements_updated.emit(snapshot.duplicate(true))
	status_changed.emit("DATI AGGIORNATI" if count > 0 else "DATI NON DISPONIBILI", Color(0.3, 0.78, 0.55) if count > 0 else Color(0.95, 0.7, 0.25))


func _emit_request_failed(message: String) -> void:
	snapshot.clear()
	_publish()
	request_failed.emit(message, _format_rome_time_from_unix(int(Time.get_unix_time_from_system())))


static func _parse_odhub_utc_time(value: String) -> int:
	var pattern := RegEx.create_from_string("^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?(Z|[+-]\\d{2}:?\\d{2})$")
	var match_value := pattern.search(value.strip_edges())
	if match_value == null:
		return 0
	var parts := {}
	var keys := ["year", "month", "day", "hour", "minute", "second"]
	for i in keys.size():
		parts[keys[i]] = int(match_value.get_string(i + 1))
	if parts.year < 1970 or parts.month < 1 or parts.month > 12 or parts.day < 1 or parts.day > _days_in_month(parts.year, parts.month) or parts.hour > 23 or parts.minute > 59 or parts.second > 59:
		return 0
	var unix := int(Time.get_unix_time_from_datetime_dict(parts))
	var zone := match_value.get_string(7).replace(":", "")
	if zone != "Z":
		var hours := int(zone.substr(1, 2))
		var minutes := int(zone.substr(3, 2))
		if hours > 14 or minutes > 59 or (hours == 14 and minutes != 0):
			return 0
		unix -= (1 if zone.begins_with("+") else -1) * (hours * 3600 + minutes * 60)
	return unix


static func _format_rome_time_from_unix(unix_utc: int) -> String:
	if unix_utc <= 0:
		return ""

	var offset_hours: int = 2 if _is_rome_dst(unix_utc) else 1
	var label: String = "CEST" if offset_hours == 2 else "CET"
	var local_time: Dictionary = Time.get_datetime_dict_from_unix_time(unix_utc + offset_hours * 3600)
	return "%02d/%02d/%04d %02d:%02d:%02d %s" % [
		local_time["day"],
		local_time["month"],
		local_time["year"],
		local_time["hour"],
		local_time["minute"],
		local_time["second"],
		label,
	]


static func _is_rome_dst(unix_utc: int) -> bool:
	var utc: Dictionary = Time.get_datetime_dict_from_unix_time(unix_utc)
	var year: int = int(utc["year"])
	var dst_start: int = int(Time.get_unix_time_from_datetime_dict({
		"year": year,
		"month": 3,
		"day": _last_sunday_day(year, 3),
		"hour": 1,
		"minute": 0,
		"second": 0,
	}))
	var dst_end: int = int(Time.get_unix_time_from_datetime_dict({
		"year": year,
		"month": 10,
		"day": _last_sunday_day(year, 10),
		"hour": 1,
		"minute": 0,
		"second": 0,
	}))
	return unix_utc >= dst_start and unix_utc < dst_end


static func _last_sunday_day(year: int, month: int) -> int:
	for day in range(_days_in_month(year, month), 0, -1):
		var unix: int = int(Time.get_unix_time_from_datetime_dict({
			"year": year,
			"month": month,
			"day": day,
			"hour": 12,
			"minute": 0,
			"second": 0,
		}))
		var datetime: Dictionary = Time.get_datetime_dict_from_unix_time(unix)
		if int(datetime["weekday"]) == 0:
			return day

	return 1


static func _days_in_month(year: int, month: int) -> int:
	match month:
		1, 3, 5, 7, 8, 10, 12:
			return 31
		4, 6, 9, 11:
			return 30
		2:
			if year % 400 == 0 or (year % 4 == 0 and year % 100 != 0):
				return 29
			return 28
		_:
			return 30
