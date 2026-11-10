extends RefCounted


static func fit(
	label: Label3D,
	source_text: String,
	max_chars_per_line: int,
	max_lines: int,
	max_font_size: int,
	min_font_size: int
) -> void:
	if label == null:
		return

	var text: String = source_text.strip_edges()
	if text == "":
		label.text = ""
		label.font_size = max_font_size
		return

	var safe_chars: int = maxi(1, max_chars_per_line)
	var safe_lines: int = maxi(1, max_lines)
	var safe_max_font: int = maxi(1, max_font_size)
	var safe_min_font: int = clampi(min_font_size, 1, safe_max_font)
	var selected_font_size: int = safe_min_font
	var selected_lines: PackedStringArray = _wrap_text(text, safe_chars)

	for font_size in range(safe_max_font, safe_min_font - 1, -1):
		var scaled_chars: int = maxi(1, int(round(float(safe_chars) * float(safe_max_font) / float(font_size))))
		var candidate_lines: PackedStringArray = _wrap_text(text, scaled_chars)
		if candidate_lines.size() <= safe_lines:
			selected_font_size = font_size
			selected_lines = candidate_lines
			safe_chars = scaled_chars
			break

	if selected_lines.size() > safe_lines:
		selected_lines = _limit_lines(selected_lines, safe_lines, safe_chars)

	label.font_size = selected_font_size
	label.text = "\n".join(selected_lines)


static func _wrap_text(text: String, max_chars: int) -> PackedStringArray:
	var lines := PackedStringArray()
	var paragraphs: PackedStringArray = text.split("\n", false)

	for paragraph in paragraphs:
		var trimmed: String = paragraph.strip_edges()
		if trimmed == "":
			continue

		var words: PackedStringArray = trimmed.split(" ", false)
		var current_line := ""

		for word in words:
			var remaining: String = word
			while remaining.length() > max_chars:
				if current_line != "":
					lines.push_back(current_line)
					current_line = ""

				var chunk_length: int = maxi(1, max_chars - 1)
				lines.push_back("%s-" % remaining.substr(0, chunk_length))
				remaining = remaining.substr(chunk_length)

			if remaining == "":
				continue

			if current_line == "":
				current_line = remaining
			elif current_line.length() + 1 + remaining.length() <= max_chars:
				current_line = "%s %s" % [current_line, remaining]
			else:
				lines.push_back(current_line)
				current_line = remaining

		if current_line != "":
			lines.push_back(current_line)

	if lines.is_empty():
		lines.push_back("")

	return lines


static func _limit_lines(lines: PackedStringArray, max_lines: int, max_chars: int) -> PackedStringArray:
	var result := PackedStringArray()
	for index in range(mini(lines.size(), max_lines)):
		result.push_back(lines[index])

	if lines.size() > max_lines and not result.is_empty():
		var last_index: int = result.size() - 1
		var last_line: String = result[last_index].strip_edges(false, true)
		var available_chars: int = maxi(3, max_chars)
		if last_line.length() > available_chars - 3:
			last_line = last_line.substr(0, available_chars - 3).strip_edges(false, true)
		result[last_index] = "%s..." % last_line

	return result
