extends Node3D
class_name DataPanel3D

const FittedLabel := preload("res://scripts/ui/fitted_label_3d.gd")

@export_group("Initial Status")
@export var initial_status_color := Color(0.32, 0.58, 0.95, 1.0)

@onready var title_label: Label3D = $TitleLabel
@onready var body_label: Label3D = $BodyLabel
@onready var values_root: Node3D = $ValueLines
@onready var status_badge: MeshInstance3D = $StatusBadge
@onready var status_label: Label3D = $StatusLabel

var status_material: StandardMaterial3D
var title_text := ""
var body_text := ""
var initial_status_text := ""
var value_line_labels: Array[Label3D] = []
var value_line_templates: Array[String] = []


func _ready() -> void:
	_collect_value_line_templates()
	if title_text == "":
		title_text = title_label.text
	if body_text == "":
		body_text = body_label.text
	if initial_status_text == "":
		initial_status_text = status_label.text
	status_material = RuntimeMaterials.duplicate_for_mesh(status_badge)
	set_panel_content(title_text, body_text)
	set_live_status(initial_status_text, initial_status_color)


func set_room_data(room_data: Dictionary) -> void:
	if str(room_data.get("station_code", "")).is_empty():
		set_panel_content(str(room_data.get("name", "NOI · Bolzano")), str(room_data.get("description", "")))
		return
	var title: String = str(room_data.get("name", "Room"))
	title_text = title
	if not is_node_ready():
		return

	FittedLabel.apply_text(title_label, title_text)
	body_label.visible = false
	values_root.visible = true
	OpenDataHubClient.expire_measurements(room_data)
	_sync_value_lines(room_data)
	var state := str(room_data.get("status", "unavailable"))
	set_live_status("AGGIORNATI" if state == "online" else ("PARZIALI" if state == "partial" else "IN ATTESA"), Color(0.3, 0.78, 0.55) if state == "online" else Color(0.95, 0.7, 0.25))


func set_panel_content(new_title: String, new_body: String) -> void:
	title_text = new_title
	body_text = new_body

	if not is_node_ready():
		return

	values_root.visible = false
	status_badge.hide()
	status_label.hide()
	body_label.visible = true
	FittedLabel.apply_text(title_label, title_text)
	FittedLabel.apply_text(body_label, body_text)


func set_live_status(status_text: String, color: Color) -> void:
	if not is_node_ready():
		return

	status_badge.visible = values_root.visible
	status_label.visible = values_root.visible
	FittedLabel.apply_text(status_label, status_text.to_upper())
	status_label.modulate = color.lightened(0.3)
	status_material.albedo_color = color.darkened(0.82)
	status_material.emission_enabled = true
	status_material.emission = color
	status_material.emission_energy_multiplier = 0.0


func _sync_value_lines(room_data: Dictionary) -> void:
	var values := _get_template_values(room_data)
	for index in range(value_line_labels.size()):
		var label := value_line_labels[index]
		var rendered := TemplateText.render(value_line_templates[index], values)
		label.visible = rendered != ""
		if label.visible:
			FittedLabel.apply_text(label, rendered)


func _collect_value_line_templates() -> void:
	value_line_labels.clear()
	value_line_templates.clear()
	for child in values_root.get_children():
		if child is Label3D:
			var label := child as Label3D
			value_line_labels.append(label)
			value_line_templates.append(label.fitted_text if label is FittedLabel3D else label.text)


func _get_template_values(room_data: Dictionary) -> Dictionary:
	var values := {
		"status": "Solo misure recenti · massimo 5 minuti",
		"area": str(room_data.get("display_location", room_data.get("area", ""))),
		"source": str(room_data.get("source", "Open Data Hub")),
		"last_updated": "Orario della misura accanto a ogni valore",
		"checked_at": "Nessun valore storico viene mostrato come attuale",
	}
	var units := {"temperature": "°C", "humidity": "%", "co2": "ppm"}
	var metrics: Dictionary = room_data.get("measurements", {})
	for field: String in units:
		var metric: Dictionary = metrics.get(field, {})
		if metric.is_empty():
			values[field] = "Non rilevata" if OpenDataHubClient.METRICS.find_key(field) not in room_data.get("datatypes", []) and room_data.has("station_code") else "Non disponibile"
			values[field + "_value"] = "—"
			values[field + "_time"] = values[field]
		else:
			var time_parts: PackedStringArray = str(metric["time"]).split(" ")
			values[field] = "%s %s · %s %s" % [str(metric["value"]), units[field], time_parts[1], time_parts[2]]
			values[field + "_value"] = "%s %s" % [str(metric["value"]), units[field]]
			values[field + "_time"] = "%s %s" % [time_parts[1], time_parts[2]]
	return values
