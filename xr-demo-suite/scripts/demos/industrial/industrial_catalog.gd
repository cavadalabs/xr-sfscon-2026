class_name IndustrialCatalog
extends Node

signal catalog_loaded(models: Array)
signal model_selected(model_data: Dictionary, title: String)

@export_file("*.json") var catalog_path := ""
@export var fallback_title := "Catalog item"
@export var fallback_category := "Catalog"
@export var category_label := "Category"

var models: Array = []
var selected_model_id := ""


func load_catalog() -> void:
	var loaded_models: Variant = ApiClient.load_json_file(catalog_path)
	if loaded_models is Array:
		models = loaded_models
	else:
		models = []

	catalog_loaded.emit(models)


func select_default_model() -> bool:
	# The demo opens on the Arredi page: the hero is the first furniture
	# model, not the first line of the catalog file.
	for model in models:
		if model is Dictionary and str(model.get("collection", "")) == "furniture" \
				and str(model.get("brand", "")) == "":
			return select_model(model as Dictionary)
	if models.is_empty() or not models[0] is Dictionary:
		return false

	return select_model(models[0] as Dictionary)


func select_model_id(model_id: String) -> bool:
	var model_data: Dictionary = find_model_by_id(model_id)
	if model_data.is_empty():
		return false

	return select_model(model_data)


func select_model(model_data: Dictionary) -> bool:
	selected_model_id = str(model_data.get("id", ""))
	model_selected.emit(
		model_data,
		get_model_title(model_data)
	)
	return true


func get_selected_model_id() -> String:
	return selected_model_id


func get_selected_model() -> Dictionary:
	return find_model_by_id(selected_model_id)


func get_model_title(model_data: Dictionary) -> String:
	return str(model_data.get("title", fallback_title))


func find_model_by_id(model_id: String) -> Dictionary:
	for model in models:
		if model is Dictionary and str(model.get("id", "")) == model_id:
			return model as Dictionary

	return {}


func find_model_by_qr_payload(payload: String) -> Dictionary:
	var payload_keys: PackedStringArray = _get_qr_match_keys(payload)
	if payload_keys.is_empty():
		return {}

	for model in models:
		if not model is Dictionary:
			continue

		var model_data: Dictionary = model as Dictionary
		for candidate in _get_model_qr_match_keys(model_data):
			if payload_keys.has(candidate):
				return model_data

	return {}


func get_neighbor_preload_models(active_model_id: String, neighbor_radius: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var model_index: int = find_model_index_by_id(active_model_id)
	if model_index < 0:
		return result

	var first_index: int = maxi(0, model_index - neighbor_radius)
	var last_index: int = mini(models.size() - 1, model_index + neighbor_radius)
	for index in range(first_index, last_index + 1):
		if index == model_index or not models[index] is Dictionary:
			continue
		result.append(models[index] as Dictionary)

	return result


func get_flagged_preload_models(active_model_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for model in models:
		if not model is Dictionary:
			continue

		var model_data: Dictionary = model as Dictionary
		if str(model_data.get("id", "")) == active_model_id:
			continue
		if bool(model_data.get("preload", false)):
			result.append(model_data)

	return result


func find_model_index_by_id(model_id: String) -> int:
	for index in range(models.size()):
		if models[index] is Dictionary and str((models[index] as Dictionary).get("id", "")) == model_id:
			return index

	return -1


func _get_model_qr_match_keys(model_data: Dictionary) -> PackedStringArray:
	var result := PackedStringArray()
	_append_unique_qr_keys(result, _get_qr_match_keys(str(model_data.get("id", ""))))

	var payload_value: Variant = model_data.get("qr_payloads", [])
	if payload_value is Array:
		for item in payload_value:
			_append_unique_qr_keys(result, _get_qr_match_keys(str(item)))
	elif payload_value is String:
		_append_unique_qr_keys(result, _get_qr_match_keys(str(payload_value)))

	return result


func _get_qr_match_keys(value: String) -> PackedStringArray:
	var result := PackedStringArray()
	var normalized: String = value.strip_edges().to_lower()
	if normalized == "":
		return result

	_add_unique_string(result, normalized)
	_add_unique_string(result, normalized.trim_suffix("/"))

	if normalized.begins_with("https://"):
		_add_unique_string(result, normalized.trim_prefix("https://").trim_suffix("/"))
	elif normalized.begins_with("http://"):
		_add_unique_string(result, normalized.trim_prefix("http://").trim_suffix("/"))

	var without_query: String = normalized.split("?")[0].trim_suffix("/")
	_add_unique_string(result, without_query)

	var parts: PackedStringArray = without_query.split("/", false)
	if not parts.is_empty():
		_add_unique_string(result, parts[parts.size() - 1])

	return result


func _append_unique_qr_keys(target: PackedStringArray, source: PackedStringArray) -> void:
	for item in source:
		_add_unique_string(target, item)


func _add_unique_string(target: PackedStringArray, value: String) -> void:
	if value != "" and not target.has(value):
		target.append(value)


func get_model_info_values(model_data: Dictionary) -> Dictionary:
	var values := {
		"description": str(model_data.get("description", "")),
		"category_label": category_label,
		"category": str(model_data.get("category", fallback_category)),
	}

	var details: Variant = model_data.get("details", {})
	if details is Dictionary:
		var index := 1
		for key in details.keys():
			values["detail_%d" % index] = "%s: %s" % [key, details[key]]
			index += 1

	return values
