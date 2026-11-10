extends Label3D
class_name FittedLabel3D

const Label3DFit := preload("res://scripts/ui/label_3d_fit.gd")

@export_multiline var fitted_text := ""
@export_range(4, 80, 1) var max_chars_per_line := 30
@export_range(1, 16, 1) var max_lines := 1
@export_range(8, 72, 1) var max_font_size := 28
@export_range(6, 48, 1) var min_font_size := 14


func _ready() -> void:
	render_priority = 10
	outline_render_priority = 9
	if fitted_text == "":
		fitted_text = text
	_sync_text()


func set_fitted_text(new_text: String) -> void:
	if fitted_text == new_text:
		return
	fitted_text = new_text
	if is_node_ready():
		_sync_text()


func refit() -> void:
	if is_node_ready():
		_sync_text()


static func apply_text(label: Label3D, value: String) -> void:
	if label.has_method("set_fitted_text"):
		label.call("set_fitted_text", value)
	else:
		label.text = value


func _sync_text() -> void:
	Label3DFit.fit(self, fitted_text, max_chars_per_line, max_lines, max_font_size, min_font_size)
