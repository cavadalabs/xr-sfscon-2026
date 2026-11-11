class_name IndustrialModelLoader
extends Node

signal model_ready(model_path: String, scene_resource: PackedScene, model_data: Dictionary, animation_name: String)
signal model_failed(model_data: Dictionary)

@export_range(1, 12, 1) var max_cached_scenes := 4

var scene_cache: Dictionary = {}
var requested_paths: Dictionary = {}
var preload_queue: Array[String] = []
var preload_active_path := ""
var pending_model_data: Dictionary = {}
var pending_model_path := ""
var pending_animation_name := ""
var pending_started_usec := 0


func _ready() -> void:
	_sync_process_state()


func _process(_delta: float) -> void:
	if pending_model_path != "":
		_update_pending_model()
	if preload_active_path != "" or not preload_queue.is_empty():
		_update_preload_model()
	_sync_process_state()


func get_cached_scene(model_path: String) -> PackedScene:
	if scene_cache.has(model_path):
		var scene := scene_cache[model_path] as PackedScene
		scene_cache.erase(model_path)
		scene_cache[model_path] = scene
		return scene
	return null


func _cache_scene(model_path: String, scene: PackedScene) -> void:
	scene_cache.erase(model_path)
	scene_cache[model_path] = scene
	while scene_cache.size() > max_cached_scenes:
		scene_cache.erase(scene_cache.keys()[0])


func is_loading(model_path: String) -> bool:
	return pending_model_path == model_path


func request_model(model_data: Dictionary, model_path: String, animation_name: String) -> bool:
	if model_path == "":
		return false
	if not _request_model_path(model_path):
		return false

	pending_model_data = model_data.duplicate(true)
	pending_model_path = model_path
	pending_animation_name = animation_name
	pending_started_usec = Time.get_ticks_usec()
	_sync_process_state()
	return true


func preload_model_path(model_path: String) -> void:
	if model_path == "":
		return
	if scene_cache.has(model_path) or requested_paths.has(model_path) or preload_queue.has(model_path):
		return

	preload_queue.append(model_path)
	_sync_process_state()


func clear_requests() -> void:
	pending_model_data.clear()
	pending_model_path = ""
	pending_animation_name = ""
	preload_queue.clear()
	preload_active_path = ""
	requested_paths.clear()
	_sync_process_state()


func cancel_pending() -> void:
	if pending_model_path != "" and pending_model_path != preload_active_path:
		preload_queue.push_front(pending_model_path)
	_clear_pending()


func _update_pending_model() -> void:
	var cached := get_cached_scene(pending_model_path)
	if cached != null:
		_finish_pending_model(cached, true)
		return
	var status: int = ResourceLoader.load_threaded_get_status(pending_model_path)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		_finish_pending_model(ResourceLoader.load_threaded_get(pending_model_path) as PackedScene, false)
	elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		var failed_model_path := pending_model_path
		var failed_model_data := pending_model_data.duplicate(true)
		requested_paths.erase(failed_model_path)
		if preload_active_path == failed_model_path:
			preload_active_path = ""
		_clear_pending()
		model_failed.emit(failed_model_data)


func _finish_pending_model(scene: PackedScene, cached: bool) -> void:
	var path := pending_model_path
	var data := pending_model_data.duplicate(true)
	var animation := pending_animation_name
	print("XR_MODEL resource id=%s wait_ms=%.1f cached=%s" % [data.get("id", ""), (Time.get_ticks_usec() - pending_started_usec) / 1000.0, cached])
	_clear_pending()
	requested_paths.erase(path)
	if preload_active_path == path:
		preload_active_path = ""
	if scene != null:
		_cache_scene(path, scene)
		model_ready.emit(path, scene, data, animation)
	else:
		model_failed.emit(data)


func _request_model_path(model_path: String) -> bool:
	if scene_cache.has(model_path) or requested_paths.has(model_path):
		return true

	var error: int = ResourceLoader.load_threaded_request(model_path, "PackedScene", true)
	if error == OK:
		requested_paths[model_path] = true
		return true

	return false


func _update_preload_model() -> void:
	if pending_model_path != "":
		return

	if preload_active_path == "":
		_start_next_preload()
		return

	var status: int = ResourceLoader.load_threaded_get_status(preload_active_path)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		var loaded_model_path := preload_active_path
		var scene_resource := ResourceLoader.load_threaded_get(loaded_model_path) as PackedScene
		if scene_resource != null:
			_cache_scene(loaded_model_path, scene_resource)
		requested_paths.erase(loaded_model_path)
		preload_active_path = ""
		_sync_process_state()
	elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		requested_paths.erase(preload_active_path)
		preload_active_path = ""
		_sync_process_state()


func _start_next_preload() -> void:
	while not preload_queue.is_empty():
		var model_path: String = preload_queue.pop_front()
		if scene_cache.has(model_path):
			continue

		if _request_model_path(model_path):
			preload_active_path = model_path
			_sync_process_state()
			return


func _clear_pending() -> void:
	pending_model_data.clear()
	pending_model_path = ""
	pending_animation_name = ""
	_sync_process_state()


func _sync_process_state() -> void:
	set_process(pending_model_path != "" or preload_active_path != "" or not preload_queue.is_empty())
