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
	_hide_exit_button(demo)
	loading_panel.visible = false


func _hide_exit_button(demo: Node) -> void:
	# Nelle standalone l'uscita avviene dal menu di sistema di Quest: il
	# pulsante "Menu"/"Esci" della suite resta nel file di scena ma non si
	# vede e non e' premibile, cosi' nessuno esce per sbaglio durante una demo.
	var back := demo.find_child("BackButton", true, false)
	if back == null:
		return
	back.visible = false
	for area in back.find_children("HitArea", "Area3D", true, false):
		(area as Area3D).monitorable = false
		(area as Area3D).input_ray_pickable = false


func _on_back_requested() -> void:
	# Il pulsante di uscita e' nascosto da _hide_exit_button; questo resta
	# come rete di sicurezza se qualche demo emette back_requested comunque.
	get_tree().quit()
