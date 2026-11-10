class_name ApiClient
extends RefCounted


static func load_json_file(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_warning("JSON file not found: %s" % path)
		return null

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Cannot open JSON file: %s" % path)
		return null

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null:
		push_warning("Invalid JSON file: %s" % path)

	return parsed
