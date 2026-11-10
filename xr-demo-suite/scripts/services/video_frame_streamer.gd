class_name VideoFrameStreamer
extends Node

const XR_IMAGE_PAYLOAD := preload("res://scripts/xr/xr_image_payload.gd")

@export var enabled := false
@export var fps := 0.5
@export var max_side := 384
@export var jpeg_quality := 0.45
@export var pause_during_voice := true

var camera_capture: PassthroughCameraCapture
var agent_client: XRAgentClient
var context_builder: Callable

var camera_initialized := false
var frame_elapsed := 0.0
var payload_thread: Thread
var payload_thread_active := false


func setup(camera_capture_ref: PassthroughCameraCapture, agent_client_ref: XRAgentClient, context_builder_ref: Callable) -> void:
	camera_capture = camera_capture_ref
	agent_client = agent_client_ref
	context_builder = context_builder_ref


func _process(delta: float) -> void:
	_collect_thread_result()

	if not enabled:
		return
	if camera_capture == null or agent_client == null or not agent_client.is_agent_connected():
		return
	if pause_during_voice and not agent_client.can_capture_background_video():
		return
	if payload_thread_active:
		return

	frame_elapsed += delta
	var frame_interval: float = 1.0 / max(0.2, fps)
	if frame_elapsed < frame_interval:
		return
	frame_elapsed = 0.0

	if not camera_initialized:
		camera_initialized = camera_capture.initialize()
	if not camera_initialized:
		return

	var frame = camera_capture.capture_frame(max_side)
	if frame == null:
		return

	var context := _build_context()
	payload_thread = Thread.new()
	payload_thread_active = true
	var frame_copy: Image = frame.duplicate()
	var error: int = payload_thread.start(Callable(self, "_prepare_frame_on_thread").bind(frame_copy, context))
	if error != OK:
		payload_thread_active = false


func stop() -> void:
	if payload_thread_active and payload_thread != null:
		payload_thread.wait_to_finish()
	payload_thread_active = false
	frame_elapsed = 0.0


func _collect_thread_result() -> void:
	if not payload_thread_active or payload_thread == null or payload_thread.is_alive():
		return

	var result: Variant = payload_thread.wait_to_finish()
	payload_thread_active = false
	if result is Dictionary:
		_send_prepared_frame(result as Dictionary)


func _prepare_frame_on_thread(frame: Image, context: Dictionary) -> Dictionary:
	var payload := XR_IMAGE_PAYLOAD.prepare_jpeg_payload(frame, max_side, jpeg_quality, context)
	if payload.is_empty():
		return {}

	var payload_context: Variant = payload.get("context", context)
	if payload_context is Dictionary:
		context = payload_context as Dictionary
	context["video_width"] = int(payload.get("width", 0))
	context["video_height"] = int(payload.get("height", 0))
	context["video_fps"] = fps
	payload["context"] = context
	return payload


func _send_prepared_frame(payload: Dictionary) -> void:
	if payload.is_empty() or agent_client == null or not agent_client.is_agent_connected():
		return

	var context_value: Variant = payload.get("context", _build_context())
	var context: Dictionary = context_value if context_value is Dictionary else _build_context()
	agent_client.send_video_frame(str(payload.get("base64", "")), context)


func _build_context() -> Dictionary:
	if context_builder.is_valid():
		var value: Variant = context_builder.call("continuous_video")
		if value is Dictionary:
			return value
	return {
		"active_demo_id": "llm",
		"requested_capability": "continuous_video",
	}
