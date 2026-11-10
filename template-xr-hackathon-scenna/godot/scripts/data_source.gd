class_name DataSource
extends Node

const REQUIRED_FIELDS := ["name", "value", "capacity", "unit", "status", "description"]

@export_group("1. Dataset")
## Disable this to work only with the local JSON file.
@export var use_live_data := true
## Shown at the top of the dashboard.
@export var dataset_title := "Val Gardena parking"
## Used automatically when the request fails or Use Live Data is disabled.
@export_file("*.json") var fallback_file := "res://data/fallback_parking.json"

@export_group("2. REST API")
## A public JSON endpoint. The demo sends one GET request at startup.
@export var api_url := "https://mobility.api.opendatahub.com/v2/flat/ParkingStation/free/latest?where=sorigin.eq.%22GARDENA%22&limit=6"
## Dot path to the list of items. Leave empty when the response itself is a list.
@export var items_array_path := "data"

@export_group("3. JSON Field Mapping")
## Dot paths inside each item. Example: smetadata.capacity.
@export var name_path := "sname"
@export var value_path := "mvalue"
@export var capacity_path := "smetadata.capacity"
@export var description_path := "mvalidtime"
## Text added after every value.
@export var unit_text := "free spaces"
## Used for every item only when Capacity Path is empty.
@export_range(0.01, 1000000.0, 0.01, "or_greater") var maximum_value := 100.0

@export_group("4. Status Rule")
## Values below this share of capacity are labelled LIMITED.
@export_range(0.0, 1.0, 0.05) var limited_below_ratio := 0.25


func items_from_api(body: PackedByteArray) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	var payload = JSON.parse_string(body.get_string_from_utf8())
	if payload == null:
		return items

	var rows = _value_at_path(payload, items_array_path)
	if rows is not Array:
		push_warning("Items Array Path does not point to a JSON array.")
		return items

	# Every live API is translated once into the six simple card fields.
	for row in rows:
		if row is not Dictionary:
			continue

		var name_value = _value_at_path(row, name_path)
		var name := "" if name_value == null else str(name_value).strip_edges()
		var value := _number(_value_at_path(row, value_path), -1.0)
		var capacity := maximum_value if capacity_path.is_empty() else _number(
			_value_at_path(row, capacity_path), -1.0
		)
		if name.is_empty() or value < 0.0 or capacity <= 0.0 or value > capacity:
			continue

		var description_value = null if description_path.is_empty() else _value_at_path(
			row, description_path
		)
		var description := "" if description_value == null else str(description_value).strip_edges()
		if description.is_empty():
			description = "Live data from the configured API."

		items.append({
			"name": name,
			"value": int(value) if is_equal_approx(value, round(value)) else value,
			"capacity": int(capacity) if is_equal_approx(capacity, round(capacity)) else capacity,
			"unit": unit_text,
			"status": _status(value, capacity),
			"description": description,
		})

	if items.is_empty():
		push_warning("No API item matched the field mapping; using the local fallback.")
	return items


func load_fallback() -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	var file := FileAccess.open(fallback_file, FileAccess.READ)
	if file == null:
		push_error("Cannot open fallback data: %s" % fallback_file)
		return items

	var payload = JSON.parse_string(file.get_as_text())
	if payload is not Array:
		push_error("Fallback data must be a JSON array.")
		return items

	for item in payload:
		if item is Dictionary and item.has_all(REQUIRED_FIELDS):
			items.append(item)
		else:
			push_warning("Skipping an invalid fallback item.")
	return items


func _status(value: float, capacity: float) -> String:
	if is_zero_approx(value):
		return "full"
	if value / capacity < limited_below_ratio:
		return "limited"
	return "available"


func _value_at_path(value: Variant, path: String) -> Variant:
	if path.is_empty():
		return value

	var current = value
	# ponytail: Object-only dot paths are enough until a chosen API needs array indexes.
	for key in path.split(".", false):
		if current is not Dictionary or not current.has(key):
			return null
		current = current[key]
	return current


func _number(value: Variant, fallback: float) -> float:
	if value is int or value is float:
		return float(value)
	var text := str(value)
	return text.to_float() if text.is_valid_float() else fallback
