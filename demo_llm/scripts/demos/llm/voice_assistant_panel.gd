extends Node3D
class_name VoiceAssistantPanel3D

const FittedLabel := preload("res://scripts/ui/fitted_label_3d.gd")

@onready var title_label: Label3D = $TitleLabel
@onready var body_label: Label3D = $BodyLabel
@onready var status_badge: MeshInstance3D = $StatusBadge
@onready var status_label: Label3D = $StatusLabel
@onready var status_orb: MeshInstance3D = $StatusOrb
@onready var status_profiles_root: Node = $StatusProfiles

var interaction: InteractiveCollisionController3D
const InteractiveCollisionControllerScene := preload("res://scenes/ui/InteractiveCollisionController3D.tscn")

var status_text := "Starting"
var response_text := ""
var panel_title := ""
var initial_response_text := ""
var status_material: StandardMaterial3D
var orb_material: StandardMaterial3D
var status_profiles: Array[VoiceAssistantStatusProfile] = []


func _ready() -> void:
	interaction = InteractiveCollisionControllerScene.instantiate()
	add_child(interaction)
	visibility_changed.connect(func(): interaction.set_branch_interactive(self, is_visible_in_tree()))
	interaction.set_branch_interactive(self, is_visible_in_tree())
	_collect_status_profiles()
	if panel_title == "":
		panel_title = title_label.text
	if initial_response_text == "":
		initial_response_text = body_label.text
	response_text = initial_response_text
	status_material = RuntimeMaterials.duplicate_for_mesh(status_badge)
	orb_material = RuntimeMaterials.duplicate_for_mesh(status_orb)
	_sync()


func set_status(value: String) -> void:
	if status_text == value:
		return
	status_text = value
	_sync()


func set_response(value: String) -> void:
	var next_response := _strip_think_blocks(value)
	if next_response == "":
		next_response = initial_response_text
	if response_text == next_response:
		return
	response_text = next_response
	_sync()


func set_error(value: String) -> void:
	var next_response := _strip_think_blocks(value)
	if status_text == "Error" and response_text == next_response:
		return
	status_text = "Error"
	response_text = next_response
	_sync()


func _sync() -> void:
	if not is_node_ready():
		return

	var status_profile := _get_status_profile(status_text)
	var status_color: Color = status_profile.color if status_profile != null else Color(0.82, 0.9, 0.98, 1.0)
	var status_label_text: String = status_profile.get_label(status_text) if status_profile != null else status_text.to_upper()
	FittedLabel.apply_text(status_label, status_label_text)
	status_label.modulate = status_color.lightened(0.3)
	status_material.albedo_color = status_color.darkened(0.82)
	status_material.emission_enabled = true
	status_material.emission = status_color
	status_material.emission_energy_multiplier = 0.0
	orb_material.albedo_color = Color(status_color.r, status_color.g, status_color.b, 1.0)
	orb_material.emission_enabled = true
	orb_material.emission = status_color
	orb_material.emission_energy_multiplier = status_profile.emission if status_profile != null else 0.22
	status_orb.scale = Vector3.ONE * (status_profile.orb_scale if status_profile != null else 1.0)

	FittedLabel.apply_text(title_label, panel_title)
	FittedLabel.apply_text(body_label, response_text)


func _collect_status_profiles() -> void:
	status_profiles.clear()
	for child in status_profiles_root.get_children():
		if child is VoiceAssistantStatusProfile:
			status_profiles.append(child as VoiceAssistantStatusProfile)


func _get_status_profile(value: String) -> VoiceAssistantStatusProfile:
	for profile in status_profiles:
		if profile.matches(value):
			return profile
	if not status_profiles.is_empty():
		return status_profiles[0]
	return null


func _strip_think_blocks(value: String) -> String:
	var source_text: String = value.strip_edges()
	if source_text == "":
		return ""

	var lower_text: String = source_text.to_lower()
	var cursor := 0
	var visible_text := ""

	while cursor < source_text.length():
		var start_index: int = lower_text.find("<think>", cursor)
		if start_index < 0:
			visible_text += source_text.substr(cursor)
			break

		visible_text += source_text.substr(cursor, start_index - cursor)
		var end_index: int = lower_text.find("</think>", start_index + 7)
		if end_index < 0:
			break

		cursor = end_index + 8

	return visible_text.strip_edges()
