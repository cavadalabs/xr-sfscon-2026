extends DemoButton3D
class_name WristMenuModelSlot3D

@export_group("Catalog Fields")
@export var id_field := "id"
@export var title_field := "title"
@export var subtitle_field := "category"
@export var color_field := "color"
@export var preview_shape_field := "preview_shape"

@export_group("Slot Visuals")
@export var default_color := "#2F7DD3"
@export_range(0.0, 0.6, 0.01) var selected_lighten := 0.22
@export_range(0.0, 1.0, 0.01) var preview_emission := 0.08
@export_range(0.0, 1.0, 0.01) var selection_emission := 0.09
@export_range(0.0, 1.0, 0.01) var preview_roughness := 0.62
@export_range(0.0, 1.0, 0.01) var selection_roughness := 0.65
## Quanto spazio dell'etichetta usa la miniatura (0.97 = quasi tutta).
@export_range(0.5, 1.0, 0.01) var thumbnail_fit := 0.97

@onready var preview_box: MeshInstance3D = $PreviewBox
@onready var preview_cylinder: MeshInstance3D = $PreviewCylinder
@onready var selected_strip: MeshInstance3D = $SelectedStrip

var preview_materials: Dictionary = {}
var selection_materials: Dictionary = {}
var thumbnail: Sprite3D
var plate_material: StandardMaterial3D


func configure_model(action_data: Dictionary, selected_action_id: String, previews_enabled: bool) -> void:
	var action_id := str(action_data.get(id_field, ""))
	var button_color := Color.html(str(action_data.get(color_field, default_color)))
	var is_selected_action := action_id == selected_action_id
	if is_selected_action:
		button_color = button_color.lightened(selected_lighten)
	var subtitle := str(action_data.get(subtitle_field, ""))
	var dimensions: Array = action_data.get("bounds_size", [])
	if action_data.get("real_scale", false) and dimensions.size() == 3:
		subtitle = "%d × %d × %d cm" % [roundi(float(dimensions[0])*100), roundi(float(dimensions[2])*100), roundi(float(dimensions[1])*100)]
	var nominal_dimensions := str(action_data.get("details", {}).get("Dimensioni", ""))
	if not nominal_dimensions.is_empty():
		subtitle = nominal_dimensions.trim_suffix(" (L × P × H)")

	configure(
		action_id,
		str(action_data.get(title_field, "Item")),
		subtitle,
		button_color
	)
	_sync_preview(str(action_data.get(preview_shape_field, "box")), button_color, previews_enabled)
	var image_path := str(action_data.get("thumbnail", ""))
	if thumbnail == null:
		thumbnail = $ProductImage
	thumbnail.texture = load(image_path) as Texture2D if image_path != "" and ResourceLoader.exists(image_path) else null
	thumbnail.visible = previews_enabled and thumbnail.texture != null
	if thumbnail.visible:
		# Fit the bitmap inside its plate, regardless of source image dimensions.
		var plate := get_node_or_null("ProductPlate") as MeshInstance3D
		if plate != null:
			var size := plate.mesh.get_aabb().size
			thumbnail.pixel_size = minf(size.x / thumbnail.texture.get_width(), size.y / thumbnail.texture.get_height()) * thumbnail_fit
		preview_box.visible = false
		preview_cylinder.visible = false
	_sync_card_hit_shape()
	_sync_selection_marker(button_color, is_selected_action)


func _sync_card_hit_shape() -> void:
	var bounds := body.transform * body.mesh.get_aabb()
	var plate := get_node_or_null("ProductPlate") as MeshInstance3D
	if plate != null:
		bounds = bounds.merge(plate.transform * plate.mesh.get_aabb())
	if thumbnail != null and thumbnail.visible:
		# Use bitmap dimensions immediately; Sprite3D refreshes its render AABB later.
		var size := Vector3(thumbnail.texture.get_width(), thumbnail.texture.get_height(), 0) * thumbnail.pixel_size
		bounds = bounds.merge(thumbnail.transform * AABB(-size * 0.5, size))
	var hit := $HitArea/HitShape as CollisionShape3D
	var shape := BoxShape3D.new()
	shape.size = Vector3(bounds.size.x + 0.05, bounds.size.y + 0.05, 0.12)
	hit.shape = shape
	hit.transform = $HitArea.transform.affine_inverse() * Transform3D(Basis.IDENTITY, Vector3(bounds.get_center().x, bounds.get_center().y, 0.05))


func set_hovered(hovered: bool) -> void:
	super.set_hovered(hovered)
	var plate := get_node_or_null("ProductPlate") as MeshInstance3D
	if plate != null:
		if plate_material == null:
			plate_material = RuntimeMaterials.duplicate_for_mesh(plate)
		plate_material.albedo_color = Color("b9eedd") if hovered else Color.WHITE


func clear_model_visuals() -> void:
	if thumbnail != null:
		thumbnail.visible = false
	_sync_preview("", Color.WHITE, false)
	_sync_selection_marker(Color.WHITE, false)


func _sync_preview(preview_shape: String, color: Color, should_show: bool) -> void:
	var use_cylinder := preview_shape.to_lower() == "cylinder"
	preview_box.visible = should_show and not use_cylinder
	preview_cylinder.visible = should_show and use_cylinder

	if preview_box.visible:
		_apply_preview_material(preview_box, color)
	if preview_cylinder.visible:
		_apply_preview_material(preview_cylinder, color)


func _apply_preview_material(preview: MeshInstance3D, color: Color) -> void:
	var runtime_material := RuntimeMaterials.cached_duplicate_for_mesh(preview, preview_materials)
	runtime_material.albedo_color = Color(color.r, color.g, color.b, 1.0)
	runtime_material.emission_enabled = true
	runtime_material.emission = Color(color.r, color.g, color.b, 1.0)
	runtime_material.emission_energy_multiplier = preview_emission
	runtime_material.roughness = preview_roughness


func _sync_selection_marker(color: Color, is_selected: bool) -> void:
	selected_strip.visible = is_selected
	if not is_selected:
		return

	var runtime_material := RuntimeMaterials.cached_duplicate_for_mesh(selected_strip, selection_materials)
	runtime_material.albedo_color = Color(color.r, color.g, color.b, 1.0)
	runtime_material.emission_enabled = true
	runtime_material.emission = Color(color.r, color.g, color.b, 1.0)
	runtime_material.emission_energy_multiplier = selection_emission
	runtime_material.roughness = selection_roughness
