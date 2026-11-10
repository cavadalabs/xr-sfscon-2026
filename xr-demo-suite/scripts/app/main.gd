extends Node3D

const DemoRouterScript := preload("res://scripts/app/demo_router.gd")
const MainMenuScript := preload("res://scripts/ui/main_menu_3d.gd")
const LoadingPanelScript := preload("res://scripts/ui/loading_panel_3d.gd")

@onready var demo_router: DemoRouterScript = $AppServices/DemoRouter
@onready var main_menu: MainMenuScript = $GlobalUI/MainMenu3D
@onready var loading_panel: LoadingPanelScript = $GlobalUI/LoadingPanel3D
@onready var context_provider: XRContextProvider = $AppServices/ContextProvider

var pending_demo_id := ""

func _ready() -> void:
	_show_menu()

func _on_demo_selected(demo_id: String) -> void:
	_load_demo(demo_id)

func _load_demo(demo_id: String) -> void:
	if demo_id != "llm":
		context_provider.clear_demo_context()
	context_provider.set_active_demo(demo_id)
	pending_demo_id = demo_id
	main_menu.visible = false
	main_menu.set_interactive(false)
	loading_panel.visible = true
	call_deferred("_load_demo_deferred", demo_id)

func _load_demo_deferred(demo_id: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if pending_demo_id != demo_id:
		return

	demo_router.load_demo(demo_id)

func _on_demo_loaded(_demo_id: String) -> void:
	pending_demo_id = ""
	context_provider.set_active_demo(_demo_id)
	loading_panel.visible = false

func _on_demo_load_failed(_demo_id: String) -> void:
	push_error("Demo load failed: %s" % _demo_id)
	_show_menu()

func _show_menu() -> void:
	pending_demo_id = ""
	loading_panel.visible = false
	demo_router.clear_demo()
	context_provider.set_active_demo("")
	main_menu.visible = true
	main_menu.set_interactive(true)
