extends Node
class_name IndustrialQRModelRegistry

@export var qr_model_instance_scene: PackedScene
@export var model_container_node_path: NodePath

@onready var model_container: Node3D = get_node_or_null(model_container_node_path) as Node3D

var qr_model_viewers: Dictionary = {}


func has_instance(qr_key: String) -> bool:
	var existing_viewer: Variant = qr_model_viewers.get(qr_key)
	return existing_viewer is IndustrialModelViewer3D and is_instance_valid(existing_viewer)


func get_or_create_model_viewer(qr_key: String) -> IndustrialModelViewer3D:
	var existing_viewer: Variant = qr_model_viewers.get(qr_key)
	if existing_viewer is IndustrialModelViewer3D and is_instance_valid(existing_viewer):
		return existing_viewer as IndustrialModelViewer3D

	if model_container == null:
		push_error("IndustrialQRModelRegistry requires a model container node.")
		return null

	if qr_model_instance_scene == null:
		push_error("IndustrialQRModelRegistry requires qr_model_instance_scene to be set.")
		return null

	var qr_viewer: IndustrialModelViewer3D = qr_model_instance_scene.instantiate() as IndustrialModelViewer3D
	if qr_viewer == null:
		return null

	qr_viewer.name = "QRModel_%s" % qr_key.sha256_text().substr(0, 8)
	model_container.add_child(qr_viewer)
	qr_model_viewers[qr_key] = qr_viewer
	return qr_viewer
