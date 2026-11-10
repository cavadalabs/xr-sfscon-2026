class_name XRPlacementPreview3D
extends MeshInstance3D

@export var surface_color := Color(0.18, 0.78, 1.0, 1.0)
@export var table_color := Color(0.24, 0.9, 0.58, 1.0)
@export var wall_color := Color(0.66, 0.52, 1.0, 1.0)
@export var fallback_color := Color(0.95, 0.68, 0.24, 1.0)
@export var surface_scale := Vector3.ONE
@export var fallback_scale := Vector3.ONE * 0.78
@export var target_surface_emission := 0.28
@export var target_fallback_emission := 0.12
@export var center_surface_emission := 0.42
@export var center_fallback_emission := 0.2

@onready var center: MeshInstance3D = $PlacementCenter

var target_material: StandardMaterial3D
var center_material: StandardMaterial3D


func _ready() -> void:
	target_material = RuntimeMaterials.duplicate_for_mesh(self)
	center_material = RuntimeMaterials.duplicate_for_mesh(center)
	apply_feedback(false, "fallback")


func apply_feedback(has_surface: bool, surface_kind: String) -> void:
	var color: Color = _get_feedback_color(has_surface, surface_kind)
	_apply_material_color(target_material, color, target_surface_emission if has_surface else target_fallback_emission)
	_apply_material_color(center_material, color, center_surface_emission if has_surface else center_fallback_emission)
	scale = surface_scale if has_surface else fallback_scale


func _get_feedback_color(has_surface: bool, surface_kind: String) -> Color:
	if not has_surface:
		return fallback_color

	match surface_kind:
		"table":
			return table_color
		"wall":
			return wall_color
		_:
			return surface_color


func _apply_material_color(material: StandardMaterial3D, color: Color, emission_energy: float) -> void:
	if material == null:
		return

	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.albedo_color = Color(color.r, color.g, color.b, 1.0)
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = emission_energy

