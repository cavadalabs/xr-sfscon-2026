extends Node
class_name VoiceAssistantStatusProfile

@export var status_names: PackedStringArray = PackedStringArray()
@export var label_text := ""
@export var color := Color(0.82, 0.9, 0.98, 1.0)
@export_range(0.0, 1.0, 0.01) var emission := 0.22
@export_range(0.5, 1.6, 0.01) var orb_scale := 1.0


func matches(status_text: String) -> bool:
	var normalized := status_text.to_lower()
	for status_name in status_names:
		if String(status_name).to_lower() == normalized:
			return true
	return false


func get_label(status_text: String) -> String:
	return label_text if label_text != "" else status_text.to_upper()
