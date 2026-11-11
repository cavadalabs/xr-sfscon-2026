extends RefCounted
## Shared furniture spawner (issue #29): the async half of the reconcile
## loop. Spawns queue one model load at a time through the hidden viewer;
## when a model is ready the item is instantiated into the shared room and
## handed back through `item_spawned` for the state's registry and placement
## hooks. The state's 2 s reconcile re-enqueues anything pruned or dropped.


signal item_spawned(spawn: Dictionary, item: Node3D)

const FurnitureItemScene := preload("res://scenes/demos/industrial/FurnitureItem.tscn")

var _queue: Array[Dictionary] = []
var _scheduled: Dictionary = {}
var _loading: Dictionary = {}
var _viewer: Node3D
var _room: Node3D
## model_id -> Dictionary catalog entry; null means the demo (catalog) is unloaded.
var _model_lookup: Callable
## world_ready(): whether the spawn frame may already be visible.
var _start_visible: Callable


func _init(viewer: Node3D, room: Node3D, model_lookup: Callable, start_visible: Callable) -> void:
	_viewer = viewer
	_room = room
	_model_lookup = model_lookup
	_start_visible = start_visible
	viewer.model_loading_finished.connect(_on_loaded)


## Queue one world item; ids already queued or loading are ignored.
func enqueue(spawn: Dictionary) -> void:
	var item_id := int(spawn["id"])
	if _scheduled.has(item_id):
		return
	_scheduled[item_id] = spawn
	_queue.append(spawn)
	_next()


## Drop everything (leave_session): reconcile re-enqueues on the next pass.
func clear() -> void:
	_queue.clear()
	_scheduled.clear()
	_loading = {}


func _next() -> void:
	if not _loading.is_empty() or _queue.is_empty():
		return
	var spawn: Dictionary = _queue.pop_front()
	var model_data: Variant = _model_lookup.call(str(spawn["m"]))
	if model_data == null:
		# Demo unloaded mid-queue: drop this spawn but forget the schedule
		# too, so the reconcile loop can re-enqueue it when the catalog is
		# back (the old code kept it scheduled forever, never spawning it).
		_scheduled.erase(int(spawn["id"]))
		return
	if model_data.is_empty():
		_scheduled.erase(int(spawn["id"]))
		return
	_loading = spawn
	_viewer.set_model_data(model_data)


func _on_loaded(success: bool) -> void:
	if _loading.is_empty():
		return
	var spawn: Dictionary = _loading
	_loading = {}
	_scheduled.erase(int(spawn["id"]))
	if not success:
		_next()
		return
	var item: Node3D = FurnitureItemScene.instantiate()
	_room.add_child(item)
	item.net_id = int(spawn["id"])
	item.net_owner = int(spawn["o"])
	_viewer.rotate_model_manual(float(spawn.get("y", 0.0)))
	item.capture(_viewer)
	item.global_transform = spawn["t"] as Transform3D
	item.visible = bool(_start_visible.call())
	item_spawned.emit(spawn, item)
	_next()
