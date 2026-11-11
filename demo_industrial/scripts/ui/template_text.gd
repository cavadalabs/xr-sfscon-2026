extends RefCounted
class_name TemplateText


static func render(template: String, values: Dictionary) -> String:
	var output := ""
	var cursor := 0

	while cursor < template.length():
		var start_index := template.find("{", cursor)
		if start_index < 0:
			output += template.substr(cursor)
			break

		var end_index := template.find("}", start_index + 1)
		if end_index < 0:
			output += template.substr(cursor)
			break

		output += template.substr(cursor, start_index - cursor)
		var key := template.substr(start_index + 1, end_index - start_index - 1).strip_edges()
		var value := str(values.get(key, "")).strip_edges()
		if value == "":
			return ""

		output += value
		cursor = end_index + 1

	return output.strip_edges()
