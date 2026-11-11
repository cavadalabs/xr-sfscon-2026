extends Node3D
class_name FurnitureItem

signal selected(item: Node3D)

## Distanza (metri) fra il bordo alto del modello e l'etichetta "SELEZIONATO".
@export var selection_label_gap := 0.08

var model_data: Dictionary
var model_yaw := 0.0
@onready var hit_area: Area3D = $HitArea
@onready var selection_label: Label3D = $SelectionLabel
var bounds := AABB()
var box_local_transform := Transform3D.IDENTITY
@onready var model_anchor: Node3D = $ModelAnchor
## Multi-user bookkeeping (shared_industrial_state): real id assigned by the
## host (negative = temporary pending id), owner peer and current lock holder.
var net_id := 0
var net_owner := -1
var net_held_by := -1


func capture(viewer: IndustrialModelViewer3D) -> void:
	model_data = viewer.current_model_data.duplicate(true)
	model_yaw = viewer.model_yaw
	add_to_group("xr_manipulable")
	bounds = viewer.current_model_bounds_anchor
	box_local_transform = viewer.model_anchor.transform * Transform3D(Basis.IDENTITY, bounds.get_center())
	global_transform = viewer.global_transform
	var container := model_anchor.get_node("CurrentModel") as Node3D
	for child in container.get_children():
		child.free()
	model_anchor.transform = viewer.model_anchor.transform
	container.transform = viewer.current_model_container.transform
	for child in viewer.current_model_container.get_children():
		child.reparent(container, false)
	var shape := hit_area.get_node("HitShape") as CollisionShape3D
	shape.shape.size = bounds.size
	shape.transform = box_local_transform
	selection_label.position = model_anchor.transform * Vector3(bounds.get_center().x, bounds.end.y + selection_label_gap, bounds.get_center().z)
	selection_label.visible = true
	viewer._clear_current_model()


func move_model_to(viewer: IndustrialModelViewer3D) -> void:
	# Move the existing nodes; picking up an item must not load or clone its asset.
	viewer._clear_current_model()
	viewer.current_model_data = model_data.duplicate(true)
	viewer.current_model_path = str(model_data.get("model_path", ""))
	viewer.current_model_bounds_anchor = bounds
	viewer.model_yaw = model_yaw
	viewer.model_anchor.transform = model_anchor.transform
	var container := model_anchor.get_node("CurrentModel") as Node3D
	viewer.current_model_container.transform = container.transform
	for child in container.get_children():
		child.reparent(viewer.current_model_container, false)
	viewer.model_animator.current_animation_player = viewer.model_animator._find_animation_player(viewer.current_model_container)
	viewer.model_label.visible = false


func mark_selected(enabled: bool) -> void:
	selection_label.visible = enabled


func activate() -> void:
	selected.emit(self)


func is_ray_over(origin: Vector3, direction: Vector3) -> bool:
	var inverse := (global_transform * box_local_transform).affine_inverse()
	var local_direction := inverse.basis * direction
	return AABB(-bounds.size * 0.5, bounds.size).intersects_ray(inverse * origin, local_direction) is Vector3


func set_interactive(enabled: bool) -> void:
	visible = enabled
	hit_area.collision_layer = (1 << 20) if enabled else 0
