extends Node3D

signal back_requested

@onready var assistant_panel: VoiceAssistantPanel3D = $VoiceAssistantPanel
@onready var agent_client: XRAgentClient = $TechnicalNodes/XRAgentClient
@onready var camera_capture: PassthroughCameraCapture = get_node_or_null("TechnicalNodes/PassthroughCameraCapture") as PassthroughCameraCapture
@onready var video_streamer: VideoFrameStreamer = get_node_or_null("TechnicalNodes/VideoFrameStreamer") as VideoFrameStreamer
@onready var snapshot_controller: Node = $TechnicalNodes/LLMSnapshotController


func _ready() -> void:
	$AssistantRobot.connect_voice(agent_client)
	assistant_panel.set_status("Connecting")
	_setup_agent_client()


func _exit_tree() -> void:
	if video_streamer != null:
		video_streamer.stop()
	if agent_client != null:
		agent_client.disconnect_agent()


func _setup_agent_client() -> void:
	if agent_client == null:
		_set_assistant_error("XRAgentClient node is missing.")
		return

	agent_client.connect_agent()

	_setup_video_streamer()


func _setup_video_streamer() -> void:
	if video_streamer != null and snapshot_controller != null:
		video_streamer.setup(camera_capture, agent_client, Callable(snapshot_controller, "build_context"))


func _build_context(requested_capability: String) -> Dictionary:
	if snapshot_controller != null and snapshot_controller.has_method("build_context"):
		var context: Variant = snapshot_controller.call("build_context", requested_capability)
		if context is Dictionary:
			context["avatar"] = "noibot" if $AssistantRobot.enabled else ""
			return context as Dictionary

	return {
		"active_demo_id": "llm",
		"requested_capability": requested_capability,
	}


func _on_back_button_pressed(_demo_id: String) -> void:
	back_requested.emit()


func _on_agent_connected() -> void:
	if agent_client != null:
		agent_client.send_scene_state(_build_context("voice"))


func _on_agent_turn_committing() -> void:
	if agent_client != null:
		agent_client.send_scene_state(_build_context("voice"))


func _on_agent_disconnected() -> void:
	assistant_panel.set_status("Offline")


func _on_agent_status_changed(status: String) -> void:
	assistant_panel.set_status(status)


func _on_agent_transcript_received(text: String) -> void:
	if text.strip_edges() == "":
		return
	assistant_panel.set_response("La tua domanda: %s" % text)


func _on_agent_response_received(text: String) -> void:
	assistant_panel.set_response(text)


func _on_agent_response_delta_received(text: String) -> void:
	assistant_panel.set_response(text)


func _on_agent_error_received(message: String) -> void:
	_set_assistant_error(message)


func _set_assistant_error(message: String) -> void:
	assistant_panel.set_error(message)
