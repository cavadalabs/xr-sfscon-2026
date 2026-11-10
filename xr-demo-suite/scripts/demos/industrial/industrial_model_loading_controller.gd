extends Node
class_name IndustrialModelLoadingController

signal feedback_changed

@export_range(0, 10, 1) var default_model_load_delay_frames := 3

@export_group("Scene References")
@export var model_viewer_node_path: NodePath
@export var industrial_catalog_node_path: NodePath

@onready var model_viewer: IndustrialModelViewer3D = get_node_or_null(model_viewer_node_path) as IndustrialModelViewer3D
@onready var industrial_catalog: IndustrialCatalog = get_node_or_null(industrial_catalog_node_path) as IndustrialCatalog

var preload_generation := 0
var default_load_pending := false
var feedback_visible := false
var feedback_generation := 0


func stop() -> void:
	default_load_pending = false
	model_viewer.model_loader.cancel_pending()
	_on_model_loading_finished(false)
	preload_generation += 1


func load_default_model_after_catalog(models: Array, handled_pending_qr: bool) -> void:
	if handled_pending_qr:
		return
	if models.is_empty() or not models[0] is Dictionary:
		return

	default_load_pending = true
	call_deferred("_select_default_model_deferred")


func _on_model_loading_started(_model_title: String) -> void:
	_on_model_loading_finished(false)
	var generation := feedback_generation
	await get_tree().create_timer(0.35).timeout
	if not is_inside_tree() or generation != feedback_generation or model_viewer.model_loader.pending_model_path == "":
		return
	feedback_visible = true
	feedback_changed.emit()


func _on_model_loading_finished(_success: bool) -> void:
	feedback_generation += 1
	if feedback_visible:
		feedback_visible = false
		feedback_changed.emit()


func _select_default_model_deferred() -> void:
	for _frame_index in range(default_model_load_delay_frames):
		await get_tree().process_frame
		if not is_inside_tree() or not default_load_pending:
			return

	if default_load_pending and industrial_catalog.selected_model_id == "":
		default_load_pending = false
		industrial_catalog.select_default_model()


func preload_visible_models(models: Array) -> void:
	preload_generation += 1
	var generation := preload_generation
	await get_tree().create_timer(0.15).timeout
	if not is_inside_tree() or generation != preload_generation:
		return
	# Three visible cards plus the current asset fit the existing four-scene cache.
	# Obsolete pages must not keep a long queue alive after fast catalog scrolling.
	var loader := model_viewer.model_loader
	# Already requested loads must still be collected; only discard work not started.
	loader.preload_queue.assign(loader.preload_queue.filter(func(path: String): return loader.requested_paths.has(path)))
	for model: Dictionary in models:
		model_viewer.preload_model_path(str(model.get("model_path", "")))
