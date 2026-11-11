extends Node
class_name LLMSnapshotController

const XR_IMAGE_PAYLOAD := preload("res://scripts/xr/xr_image_payload.gd")

@export_group("Snapshot Image")
@export_range(256, 1024, 32) var snapshot_max_side := 512
@export_range(0.4, 0.95, 0.01) var snapshot_jpeg_quality := 0.68

@export_group("Snapshot Messages")
@export_multiline var default_snapshot_prompt := "Analyze this Quest camera snapshot using the XR scene context. Answer in the user's language."
@export var snapshot_sent_text := "Sto analizzando l’immagine acquisita dal visore."
@export var agent_disconnected_error := "XR agent is not connected."
@export var snapshot_busy_error := "Quest camera capture is already running."
@export var snapshot_prepare_error := "Unable to prepare camera snapshot."
@export var camera_unavailable_error := "Camera feed unavailable. Check Quest camera permission and vendor support."
@export var camera_frame_unavailable_error := "Camera frame unavailable."

@export_group("Scene References")
@export var agent_client_node_path: NodePath
@export var camera_capture_node_path: NodePath
@export var assistant_panel_node_path: NodePath

@onready var agent_client: XRAgentClient = get_node_or_null(agent_client_node_path) as XRAgentClient
@onready var camera_capture: PassthroughCameraCapture = get_node_or_null(camera_capture_node_path) as PassthroughCameraCapture
@onready var assistant_panel: VoiceAssistantPanel3D = get_node_or_null(assistant_panel_node_path) as VoiceAssistantPanel3D

var camera_initialized := false
var capture_in_progress := false
var payload_thread: Thread
var payload_thread_active := false
var active_snapshot_request_id := ""
var active_snapshot_prompt := ""


func _ready() -> void:
	call_deferred("_warm_up_camera")


func _process(_delta: float) -> void:
	if payload_thread_active and payload_thread != null and not payload_thread.is_alive():
		var thread_result: Variant = payload_thread.wait_to_finish()
		payload_thread_active = false
		if thread_result is Dictionary:
			_send_prepared_snapshot(thread_result as Dictionary)
		else:
			_finish_capture_with_error(snapshot_prepare_error)


func _exit_tree() -> void:
	if payload_thread_active and payload_thread != null:
		payload_thread.wait_to_finish()
		payload_thread_active = false


func build_context(requested_capability: String) -> Dictionary:
	var context_provider := get_tree().get_first_node_in_group("xr_context_provider") as XRContextProvider
	if context_provider != null:
		var context := context_provider.build_context({
			"requested_capability": requested_capability,
		})
		# L'assistente non riceve la selezione: la consapevolezza ambientale
		# reale viene dal tool camera get_what_user_is_seeing (#28).
		context.erase("selected_model")
		context.erase("selected_room")
		return context

	return {
		"active_demo_id": "llm",
		"requested_capability": requested_capability,
	}


func has_active_capture() -> bool:
	return capture_in_progress


func _on_agent_snapshot_requested(request_id: String, prompt: String) -> void:
	if capture_in_progress:
		if agent_client != null:
			agent_client.send_snapshot_error(request_id, snapshot_busy_error)
		return

	await _capture_and_send_snapshot(request_id, prompt)


func _capture_and_send_snapshot(request_id: String, prompt: String) -> void:
	if capture_in_progress:
		return

	var snapshot_prompt := prompt.strip_edges()
	if snapshot_prompt == "":
		snapshot_prompt = default_snapshot_prompt

	active_snapshot_request_id = request_id.strip_edges()
	active_snapshot_prompt = snapshot_prompt

	if agent_client == null or not agent_client.is_agent_connected():
		_finish_capture_with_error(agent_disconnected_error)
		return

	capture_in_progress = true
	_set_panel_status("Capturing")
	await get_tree().process_frame

	if camera_capture == null:
		_finish_capture_with_error(camera_unavailable_error)
		return

	if not camera_initialized:
		camera_initialized = camera_capture.initialize()

	if not camera_initialized:
		_finish_capture_with_error(camera_unavailable_error)
		return

	var frame := camera_capture.capture_frame(snapshot_max_side)
	if frame == null:
		_finish_capture_with_error(camera_frame_unavailable_error)
		return

	var context := build_context("vision")
	agent_client.send_scene_state(context)
	_start_payload_thread(frame, context, active_snapshot_request_id, active_snapshot_prompt)


func _warm_up_camera() -> void:
	await get_tree().create_timer(0.35).timeout
	if camera_initialized or capture_in_progress:
		return
	if camera_capture == null:
		return

	camera_initialized = camera_capture.initialize()


func _start_payload_thread(frame: Image, context: Dictionary, request_id: String, prompt: String) -> void:
	if payload_thread_active:
		_finish_capture_with_error(snapshot_busy_error)
		return

	_set_panel_status("Preparing")

	payload_thread = Thread.new()
	payload_thread_active = true
	var frame_copy: Image = frame.duplicate()
	var error: int = payload_thread.start(Callable(self, "_prepare_snapshot_on_thread").bind(frame_copy, context, request_id, prompt))
	if error != OK:
		payload_thread_active = false
		_finish_capture_with_error(snapshot_prepare_error)


func _prepare_snapshot_on_thread(frame: Image, context: Dictionary, request_id: String, prompt: String) -> Dictionary:
	var payload := XR_IMAGE_PAYLOAD.prepare_jpeg_payload(frame, snapshot_max_side, snapshot_jpeg_quality, context)
	if payload.is_empty():
		return {}

	payload["request_id"] = request_id
	payload["prompt"] = prompt
	return payload


func _send_prepared_snapshot(payload: Dictionary) -> void:
	if payload.is_empty():
		_finish_capture_with_error(snapshot_prepare_error)
		return
	if agent_client == null or not agent_client.is_agent_connected():
		_finish_capture_with_error(agent_disconnected_error)
		return

	var context_value: Variant = payload.get("context", build_context("vision"))
	var context: Dictionary = context_value if context_value is Dictionary else build_context("vision")
	var request_id_value: Variant = payload.get("request_id", active_snapshot_request_id)
	var request_id := str(request_id_value).strip_edges()
	if request_id == "":
		request_id = "quest_%s" % Time.get_ticks_msec()

	var prompt_value: Variant = payload.get("prompt", active_snapshot_prompt)
	var prompt := str(prompt_value).strip_edges()
	if prompt == "":
		prompt = default_snapshot_prompt

	agent_client.send_scene_state(context)
	agent_client.send_snapshot(str(payload.get("base64", "")), prompt, request_id, context)

	capture_in_progress = false
	_clear_active_snapshot()
	_set_panel_status("Preparing")
	_set_panel_response(snapshot_sent_text)


func _finish_capture_with_error(message: String) -> void:
	var request_id := active_snapshot_request_id
	capture_in_progress = false
	_clear_active_snapshot()
	if request_id != "" and agent_client != null:
		agent_client.send_snapshot_error(request_id, message)
	_set_panel_error(message)


func _clear_active_snapshot() -> void:
	active_snapshot_request_id = ""
	active_snapshot_prompt = ""


func _set_panel_status(status: String) -> void:
	if assistant_panel != null:
		assistant_panel.set_status(status)


func _set_panel_response(response: String) -> void:
	if assistant_panel != null:
		assistant_panel.set_response(response)


func _set_panel_error(message: String) -> void:
	if assistant_panel != null:
		assistant_panel.set_error(message)
