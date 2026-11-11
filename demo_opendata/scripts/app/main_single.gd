extends Node3D
## Ingresso standalone: carica una sola demo senza menu né router.
## Usato dalle copie standalone (demo_industrial, demo_opendata, demo_llm).

@export var demo_id := ""
@export var demo_scene_path := ""

@onready var demo_container: Node3D = $DemoContainer
@onready var loading_panel: LoadingPanel3D = $GlobalUI/LoadingPanel3D
@onready var context_provider: XRContextProvider = $AppServices/ContextProvider


func _ready() -> void:
	if context_provider:
		context_provider.set_active_demo(demo_id)
	call_deferred("_load_demo")


func _load_demo() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var packed := load(demo_scene_path) as PackedScene
	if packed == null:
		push_error("Cannot load demo scene: %s" % demo_scene_path)
		loading_panel.set_message("Errore di caricamento")
		return
	var demo := packed.instantiate()
	demo_container.add_child(demo)
	if demo.has_signal("back_requested"):
		demo.connect("back_requested", _on_back_requested)
	loading_panel.visible = false


func _on_back_requested() -> void:
	# In standalone non esiste un menu principale: il tasto "Esci" chiude l'app.
	get_tree().quit()
