extends Node3D
class_name DemoRouter3D

signal demo_loaded(demo_id: String)
signal demo_load_failed(demo_id: String)
signal demo_unloaded
signal back_requested

@export var demo_scene_paths: Dictionary = {}

@onready var demo_container: Node3D = $DemoContainer

var current_demo: Node
var current_demo_id := ""
var loading_demo_id := ""
var loading_scene_path := ""
var is_waiting_for_instantiation := false


func _ready() -> void:
	set_process(false)


func _process(_delta: float) -> void:
	if loading_demo_id == "" or loading_scene_path == "" or is_waiting_for_instantiation:
		set_process(false)
		return

	var status: int = ResourceLoader.load_threaded_get_status(loading_scene_path)
	match status:
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return
		ResourceLoader.THREAD_LOAD_LOADED:
			is_waiting_for_instantiation = true
			set_process(false)
			call_deferred("_instantiate_threaded_demo", loading_demo_id, loading_scene_path)
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			var failed_demo_id := loading_demo_id
			_clear_loading_state()
			push_error("Cannot load demo scene: %s" % failed_demo_id)
			demo_load_failed.emit(failed_demo_id)


func load_demo(demo_id: String) -> void:
	var scene_path: String = _get_demo_scene_path(demo_id)
	if scene_path == "":
		push_warning("Unknown demo id: %s" % demo_id)
		return

	clear_demo()

	loading_demo_id = demo_id
	loading_scene_path = scene_path
	is_waiting_for_instantiation = false

	var error: int = ResourceLoader.load_threaded_request(loading_scene_path, "PackedScene", true)
	if error != OK and error != ERR_BUSY:
		var failed_demo_id := loading_demo_id
		_clear_loading_state()
		push_error("Cannot request threaded demo load: %s" % scene_path)
		demo_load_failed.emit(failed_demo_id)
		return

	set_process(true)


func _instantiate_threaded_demo(demo_id: String, scene_path: String) -> void:
	if demo_id != loading_demo_id or scene_path != loading_scene_path:
		return

	var scene := ResourceLoader.load_threaded_get(scene_path) as PackedScene
	if scene == null:
		_clear_loading_state()
		push_error("Cannot instantiate demo scene: %s" % scene_path)
		demo_load_failed.emit(demo_id)
		return

	current_demo = scene.instantiate()
	current_demo_id = demo_id
	demo_container.add_child(current_demo)

	if current_demo.has_signal("back_requested"):
		current_demo.connect("back_requested", Callable(self, "_on_current_demo_back_requested"))

	_clear_loading_state(false)
	demo_loaded.emit(demo_id)


func clear_demo() -> void:
	_clear_loading_state()
	if current_demo == null:
		return

	current_demo.queue_free()
	current_demo = null
	current_demo_id = ""
	demo_unloaded.emit()


func _on_current_demo_back_requested() -> void:
	back_requested.emit()


func _get_demo_scene_path(demo_id: String) -> String:
	if not demo_scene_paths.has(demo_id):
		return ""

	return str(demo_scene_paths[demo_id])


func _clear_loading_state(disable_process := true) -> void:
	loading_demo_id = ""
	loading_scene_path = ""
	is_waiting_for_instantiation = false
	if disable_process:
		set_process(false)
