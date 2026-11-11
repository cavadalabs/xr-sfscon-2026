extends Node
## Arredo di default (issue #20): entrando nella demo industriale la stanza
## è già arredata con un set di partenza, eliminabile e spostabile come ogni
## altro arredo. In locale è generato come anteprima (net_id 0), quindi
## scade all'ingresso in stanza come l'arredo messo a mano; in condivisa
## l'host lo semina con normali intent "place" (senza tmp), così il
## validatore assegna id e proprietario e l'echo sincronizza il set su tutti.
## Il set si semina una volta sola per ingresso/room: dopo un "reset"
## dell'host si ri-semina (vedi _process), mai se l'utente lo elimina.

const ViewerScene := preload("res://scenes/demos/industrial/IndustrialModelViewer.tscn")
const FurnitureItemScene := preload("res://scenes/demos/industrial/FurnitureItem.tscn")

## Set fisso (non "i primi N del catalogo"): un banco, due sedie e una madia,
## davanti al punto di ingresso a distanza di braccio.
const DEFAULT_SET := [
	{"m": "round_wooden_table_02", "p": Vector3(0.0, 0.0, -1.8), "y": 0.0},
	{"m": "dining_chair_02", "p": Vector3(0.95, 0.0, -1.8), "y": PI / 2.0},
	{"m": "dining_chair_02", "p": Vector3(-0.95, 0.0, -1.8), "y": -PI / 2.0},
	{"m": "modern_wooden_cabinet", "p": Vector3(0.0, 0.0, -3.4), "y": 0.0},
]

@export var catalog_node_path: NodePath
@export var placement_controller_node_path: NodePath

var _catalog: Node
var _placement: Node
var _state: Node
var _viewer: Node3D
var _queue: Array[Dictionary] = []
var _loading := false
var _pending: Dictionary = {}
var _local_seeded := false
var _shared_seeded := false


func _ready() -> void:
	_catalog = get_node_or_null(catalog_node_path)
	_placement = get_node_or_null(placement_controller_node_path)
	if _catalog == null or _placement == null:
		return
	_state = get_tree().get_first_node_in_group("shared_state")
	_viewer = ViewerScene.instantiate()
	_viewer.name = "DefaultFurnitureViewer"
	_viewer.visible = false
	add_child(_viewer)
	_viewer.model_loading_finished.connect(_on_model_loaded)
	_catalog.catalog_loaded.connect(_on_catalog_loaded)
	if _state != null:
		_state.connection_changed.connect(_on_connection_changed)


func _connected() -> bool:
	return _state != null and _state.session.connected


func _on_catalog_loaded(_models: Array) -> void:
	# Il catalogo si ricarica a ogni ingresso nella demo: qui si decide solo
	# quale percorso di semina prendere.
	if _connected():
		_seed_shared()
	else:
		_seed_local()


func _on_connection_changed() -> void:
	# Le transizioni invalidano il set: entrare in stanza voida le anteprime
	# locali, uscire rimette la demo locale, che va arredata di nuovo.
	_local_seeded = false
	_shared_seeded = false
	if _connected():
		_seed_shared()
	else:
		_seed_local()


func _process(_delta: float) -> void:
	# Il "reset" dell'host svuota la stanza e riporta next_id a 1 (una
	# cancellazione integrale dell'utente no); l'host non riceve gli echo
	# dei propri intent, quindi il ri-seed si scopre solo per polling. Va
	# atteso il prune degli item: i nuovi id ricominciano da 1 e un seed
	# prematuro li confonderebbe con i vecchi.
	if not _shared_seeded or not _connected() or not _state.hosting():
		return
	var world: Dictionary = _state.session.world_state
	if world.get("items", {}).is_empty() and int(world.get("next_id", 0)) == 1 \
			and _placement.furniture_items.is_empty():
		_shared_seeded = false
		_seed_shared()


func _seed_local() -> void:
	if _local_seeded or _connected() or _viewer == null:
		return
	_local_seeded = true
	_queue.assign(DEFAULT_SET)
	_pump()


func _seed_shared() -> void:
	# Semina solo l'host: l'intent "place" senza tmp passa dal validatore,
	# che assegna id e proprietario, e l'echo genera gli item per tutti.
	if _shared_seeded or not _connected() or not _state.hosting():
		return
	if not _state.session.world_state.get("items", {}).is_empty():
		_shared_seeded = true # Rientro nella demo: la stanza è già aredata.
		return
	var seeded := 0
	for entry in DEFAULT_SET:
		if _catalog.find_model_by_id(str(entry["m"])).is_empty():
			continue
		var pose := Transform3D(Basis.IDENTITY, entry["p"] as Vector3)
		_state.session.submit_intent("place", {"m": str(entry["m"]), "t": pose, "y": float(entry["y"])})
		seeded += 1
	if seeded > 0:
		_shared_seeded = true


func _pump() -> void:
	if _loading or _queue.is_empty():
		return
	var entry: Dictionary = _queue.pop_front()
	var model_data: Dictionary = _catalog.find_model_by_id(str(entry["m"]))
	if model_data.is_empty():
		_pump()
		return
	_loading = true
	_pending = entry
	_viewer.set_model_data(model_data)


func _on_model_loaded(success: bool) -> void:
	if not _loading:
		return
	_loading = false
	if success:
		_spawn(_pending)
	_pump()


func _spawn(entry: Dictionary) -> void:
	# Anteprima locale identica a quella manuale: net_id 0, figlia della
	# demo, selezionabile dal placement controller.
	var item: Node3D = FurnitureItemScene.instantiate()
	get_parent().get_parent().add_child(item)
	_viewer.rotate_model_manual(float(entry["y"]))
	item.capture(_viewer)
	item.global_transform = Transform3D(Basis.IDENTITY, entry["p"] as Vector3)
	item.selected.connect(_placement._on_furniture_selected)
	_placement.furniture_items.append(item)
