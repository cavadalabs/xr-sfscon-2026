extends Node3D

@export var button_node_path: NodePath

@onready var button: DemoButton3D = get_node(button_node_path)
@onready var viewer: IndustrialModelViewer3D = $Viewer
@onready var placement: IndustrialModelPlacementController = $Placement
@onready var gestures: XRModelRotationController3D = $Gestures

var noibot: NoiBotController
const NoiBotControllerScene := preload("res://scenes/demos/llm/NoiBotController.tscn")
var client: XRAgentClient
var enabled := false
var loading := false
var bounds_elapsed := 0.0


func _ready() -> void:
	set_process(false)
	button.title_label.max_chars_per_line = 20
	button.subtitle_label.max_chars_per_line = 30
	button.pressed.connect(_toggle)
	viewer.model_loading_finished.connect(_on_loaded)
	placement.model_state_changed.connect(_sync_button)
	gestures.set_input_blocked(true)
	_sync_button()


func _toggle(_id: String) -> void:
	if enabled:
		remove_robot()
		return
	enabled = true
	loading = true
	placement.prepare_selection()
	_sync_button()
	viewer.set_model_data({"id": "noibot", "title": "NoiBot", "model_path": "res://assets/models/assistant/NOIBOT.glb", "real_scale": true, "animation_autoplay": false})


func remove_robot() -> void:
	set_process(false)
	enabled = false
	loading = false
	if is_instance_valid(noibot):
		noibot.stop_speech()
		noibot.queue_free()
	noibot = null
	placement.stop()
	gestures.set_input_blocked(true)
	viewer.clear_viewer()
	viewer.hide()
	_sync_button()


func _on_loaded(success: bool) -> void:
	if not enabled:
		return
	loading = false
	if not success:
		remove_robot()
		button.configure("robot", "Riprova NoiBot", "Caricamento non riuscito", Color(0.9, 0.6, 0.3))
		return
	noibot = NoiBotControllerScene.instantiate()
	noibot.model = viewer.current_model_container.get_child(0)
	viewer.add_child(noibot)
	set_process(true)
	if client != null and client.playback_player.playing:
		_on_speech(client.mouth_cues)
	placement.on_model_loaded(true)
	placement.handle_action("place_model")
	_sync_button()


func _sync_button() -> void:
	var placing := enabled and placement.placement_mode and not placement.gesture_moving
	var title := "Annulla" if loading or placing else ("Rimuovi NoiBot" if enabled else "NoiBot")
	var hint := "Caricamento…" if loading else ("Pinch per posare" if placing else ("1 s sposta · 2 mani ruota" if enabled else "Aggiungi e posiziona"))
	button.configure("robot", title, hint, Color(0.3, 0.78, 0.68))


func connect_voice(agent: XRAgentClient) -> void:
	client = agent
	client.audio_playback_started.connect(_on_speech)
	client.audio_playback_stopped.connect(_on_speech_stopped)
	client.status_changed.connect(func(status: String):
		if is_instance_valid(noibot): noibot.listening = status == "Listening")


func _on_speech(cues: Array) -> void:
	if not is_instance_valid(noibot):
		return
	noibot.follow_speech(client.playback_player, cues)


func _on_speech_stopped() -> void:
	if is_instance_valid(noibot):
		noibot.stop_speech()


func _process(delta: float) -> void:
	bounds_elapsed += delta
	if bounds_elapsed >= 0.1 and is_instance_valid(noibot):
		bounds_elapsed = 0.0
		# Hands remain grabbable as the existing NoiBot rig gestures while speaking.
		viewer.current_model_bounds_anchor = viewer.model_bounds._calculate_bounds(viewer.model_anchor, viewer.current_model_container, [])
