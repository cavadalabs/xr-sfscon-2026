class_name XRAgentClient
extends Node

signal status_changed(status: String)
signal transcript_received(text: String)
signal response_received(text: String)
signal error_received(message: String)
signal connected
signal disconnected
signal audio_playback_started(cues: Array)
signal audio_playback_stopped
signal turn_committing
signal snapshot_requested(request_id: String, prompt: String)
signal response_delta_received(text: String)

const DEFAULT_OUTPUT_SAMPLE_RATE := 24_000
## Optional local overrides (ws_url, …) kept OUT of the project so deployments
## never commit network addresses: copy agent_config.example.json to
## user://agent_config.json on the device (or the desktop user data dir).
const USER_CONFIG_PATH := "user://agent_config.json"
const XR_AUDIO_CODEC := preload("res://scripts/services/xr_audio_codec.gd")
const TransportScript := preload("res://scripts/services/xr_agent_transport.gd")
const VadScript := preload("res://scripts/services/xr_voice_turn.gd")

@export_group("Connection")
@export var ws_url := "ws://192.168.1.100:8091/ws/realtime"
@export_range(200, 5000, 100) var reconnect_delay_ms := 800
@export_range(5.0, 120.0, 1.0) var response_timeout_seconds := 30.0

@export_group("Voice Detection")
@export_range(0.003, 0.12, 0.001) var voice_threshold := 0.018
@export_range(1, 8, 1) var min_voice_chunks := 4
@export_range(200, 1600, 50) var silence_commit_ms := 600
@export_range(2.0, 20.0, 0.5) var max_turn_seconds := 12.0
@export_range(0, 20, 1) var preroll_chunk_count := 8
@export_range(0.2, 4.0, 0.1) var input_gain := 1.4
@export_range(100, 2000, 50) var min_turn_ms := 700
@export_range(100, 1200, 50) var min_voice_ms := 300

@export_group("Playback")
@export_range(0, 2000, 50) var playback_suppression_padding_ms := 450
@export_range(0.15, 1.0, 0.05) var streaming_audio_buffer_seconds := 0.35

@export_group("Barge-In")
@export var barge_in_enabled := true
@export_range(1.0, 4.0, 0.1) var barge_in_threshold_multiplier := 1.7
@export_range(1, 8, 1) var barge_in_voice_chunks := 3
@export_range(0, 1000, 50) var barge_in_grace_ms := 250

## The websocket lives in its own transport (issue #29): socket lifecycle,
## reconnect timer and packet pump. Created eagerly so the client is usable
## before it enters the tree (the headless checks drive it directly).
var transport: TransportScript = TransportScript.new()
## Voice-activity turn machine (issue #29): VAD thresholds, preroll buffer,
## turn timing and barge-in counting. Tuned from the exports in _ready.
var vad: VadScript = VadScript.new()
var capture_effect: AudioEffectCapture
@onready var microphone_player: AudioStreamPlayer = get_node_or_null("MicrophonePlayer") as AudioStreamPlayer
@onready var playback_player: AudioStreamPlayer = get_node_or_null("PlaybackPlayer") as AudioStreamPlayer
var capture_bus_name := "XRAgentMic"
var sample_rate := 48_000
var frames_per_chunk := 960
var session_started := false
var awaiting_response := false
var mic_suppressed_until_ms := 0
var collecting_audio_output := false
var output_audio_buffer := PackedByteArray()
var output_audio_rate := DEFAULT_OUTPUT_SAMPLE_RATE
var output_audio_stereo := false
var mouth_cues: Array = []
var streaming_audio_output := false
var streaming_audio_finished := false
var stream_generator_playback: AudioStreamGeneratorPlayback
var stream_generator_buffer_frames := 0
var stream_output_received_bytes := 0
var stream_pending_audio_buffer := PackedByteArray()
var playback_was_playing := false
var playback_started_ms := 0
var response_started_ms := 0
var last_server_event_ms := 0


## Reads user://agent_config.json (see USER_CONFIG_PATH). Returns {} when the
## file is absent or malformed, so the scene defaults stay in charge.
static func load_user_config(path: String = USER_CONFIG_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("XR_AGENT_CONFIG cannot be opened: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_warning("XR_AGENT_CONFIG is not a JSON object: %s" % path)
	return {}


func _ready() -> void:
	var user_cfg := load_user_config()
	if user_cfg.has("ws_url"):
		ws_url = String(user_cfg["ws_url"])
	transport.state_changed.connect(_on_socket_state_changed)
	transport.text_packet.connect(_handle_text_packet)
	transport.binary_packet.connect(_handle_audio_packet)
	vad.voice_threshold = voice_threshold
	vad.min_voice_chunks = min_voice_chunks
	vad.silence_commit_ms = silence_commit_ms
	vad.max_turn_seconds = max_turn_seconds
	vad.preroll_chunk_count = preroll_chunk_count
	vad.min_turn_ms = min_turn_ms
	vad.min_voice_ms = min_voice_ms
	vad.barge_in_threshold_multiplier = barge_in_threshold_multiplier
	vad.barge_in_voice_chunks = barge_in_voice_chunks
	vad.turn_started.connect(_on_turn_started)
	vad.turn_committed.connect(_on_turn_committed)
	vad.turn_cancelled.connect(_on_turn_cancelled)
	vad.barge_in.connect(_on_barge_in)
	vad.mic_silent.connect(_on_mic_silent)
	sample_rate = int(AudioServer.get_mix_rate())
	if sample_rate <= 0:
		sample_rate = 48_000
	frames_per_chunk = max(1, int(round(float(sample_rate) * VadScript.FRAME_MS / 1000.0)))
	_setup_audio_output()
	_setup_microphone_capture()


func _process(delta: float) -> void:
	transport.poll()
	_try_reconnect()
	_capture_and_stream_audio(delta)
	_update_playback_state()
	_update_response_watchdog()


func connect_agent() -> void:
	if ws_url.strip_edges() == "":
		error_received.emit("XR agent URL is empty.")
		return

	transport.url = ws_url
	transport.reconnect_delay_ms = reconnect_delay_ms
	transport.wants_connection = true
	_ensure_microphone_running()
	if transport.is_open_or_connecting():
		return

	session_started = false
	vad.reset()
	if transport.next_reconnect_ms == 0:
		status_changed.emit("Connecting")
	var error: int = transport.connect_now()
	if error != OK:
		error_received.emit("Unable to connect XR agent websocket: %s" % error)
		transport.schedule_reconnect()


func disconnect_agent() -> void:
	transport.wants_connection = false
	transport.close()
	_stop_audio_output()
	_stop_microphone()


func send_scene_state(context: Dictionary) -> void:
	var active_demo := str(context.get("active_demo_id", "llm"))
	var selected_object := str(context.get("selected_object_id", ""))
	var objects: Array = []
	if context.has("objects") and context["objects"] is Array:
		objects = context["objects"]

	_send_json({
		"type": "scene.state",
		"objects": objects,
		"gaze_target": selected_object,
		"active_demo": active_demo,
		"metadata": context,
	})


func send_snapshot(image_jpeg_base64: String, prompt: String, request_id: String, metadata: Dictionary = {}) -> void:
	if image_jpeg_base64.strip_edges() == "":
		error_received.emit("Snapshot image is empty.")
		return

	_send_json({
		"type": "vision.snapshot",
		"request_id": request_id,
		"prompt": prompt,
		"image_jpeg_base64": image_jpeg_base64,
		"metadata": metadata,
	})


func send_snapshot_error(request_id: String, message: String) -> void:
	if request_id.strip_edges() == "":
		return

	_send_json({
		"type": "vision.snapshot.error",
		"request_id": request_id,
		"message": message,
	})


func send_video_frame(image_jpeg_base64: String, metadata: Dictionary = {}) -> void:
	if image_jpeg_base64.strip_edges() == "":
		return

	_send_json({
		"type": "vision.video_frame",
		"request_id": "video_%s" % Time.get_ticks_msec(),
		"image_jpeg_base64": image_jpeg_base64,
		"metadata": metadata,
		"captured_at_ms": Time.get_ticks_msec(),
	})


func is_agent_connected() -> bool:
	return transport.is_open() and session_started


func can_capture_background_video() -> bool:
	if not is_agent_connected():
		return false
	return not vad.turn_active \
		and not awaiting_response \
		and not collecting_audio_output \
		and not streaming_audio_output \
		and (playback_player == null or not playback_player.playing)


func _try_reconnect() -> void:
	if not transport.wants_connection:
		return
	if transport.is_open_or_connecting():
		return
	if Time.get_ticks_msec() < transport.next_reconnect_ms:
		return

	connect_agent()


func _on_socket_state_changed(ready_state: WebSocketPeer.State) -> void:
	if ready_state == WebSocketPeer.STATE_OPEN:
		transport.next_reconnect_ms = 0
		_ensure_microphone_running()
		connected.emit()
		status_changed.emit("Connected")
		_send_json({
			"type": "session.start",
			"sample_rate": sample_rate,
		})
	elif ready_state == WebSocketPeer.STATE_CLOSED:
		session_started = false
		awaiting_response = false
		response_started_ms = 0
		collecting_audio_output = false
		output_audio_buffer.clear()
		_stop_audio_output()
		vad.reset()
		disconnected.emit()
		status_changed.emit("Offline")
		transport.schedule_reconnect()


func _handle_text_packet(text: String) -> void:
	last_server_event_ms = Time.get_ticks_msec()
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		error_received.emit("Invalid XR agent message.")
		return

	var event: Dictionary = parsed
	var event_type := str(event.get("type", ""))
	match event_type:
		"session.connected":
			status_changed.emit("Connected")
		"session.ready":
			session_started = true
			awaiting_response = false
			response_started_ms = 0
			status_changed.emit("Listening")
		"scene.updated":
			pass
		"stt.start":
			status_changed.emit("Transcribing")
		"stt.done":
			transcript_received.emit(str(event.get("text", "")))
			status_changed.emit("Thinking")
		"turn.empty":
			awaiting_response = false
			response_started_ms = 0
			vad.reset()
			status_changed.emit("Listening")
		"llm.start":
			status_changed.emit("Thinking")
		"llm.delta":
			var partial_text := str(event.get("text", ""))
			if partial_text.strip_edges() != "":
				response_delta_received.emit(partial_text)
		"llm.done":
			response_received.emit(str(event.get("text", "")))
		"tts.start":
			_set_awaiting_response(true)
			status_changed.emit("Thinking")
		"audio.output.start":
			_begin_audio_output(event)
		"audio.output.done":
			pass
		"tts.done":
			awaiting_response = false
			response_started_ms = 0
			if streaming_audio_output:
				streaming_audio_finished = true
			else:
				_play_collected_audio()
		"vision.start":
			status_changed.emit("Looking")
		"vision.decision", "vision.ready":
			status_changed.emit("Thinking")
		"vision.snapshot.request":
			status_changed.emit("Looking")
			snapshot_requested.emit(
				str(event.get("request_id", "")),
				str(event.get("prompt", ""))
			)
		"barge_in.ack":
			status_changed.emit("Listening")
		"audio.cancelled":
			awaiting_response = false
			response_started_ms = 0
			_stop_audio_output()
			vad.reset()
			status_changed.emit("Listening")
		"error":
			awaiting_response = false
			response_started_ms = 0
			_stop_audio_output()
			vad.reset()
			error_received.emit(str(event.get("message", "XR agent error.")))
		_:
			pass


func _handle_audio_packet(audio_bytes: PackedByteArray) -> void:
	if audio_bytes.is_empty():
		return

	if streaming_audio_output:
		_push_streamed_audio(audio_bytes)
		return

	if collecting_audio_output:
		output_audio_buffer.append_array(audio_bytes)
		return

	_play_audio_bytes(audio_bytes)


func _begin_audio_output(event: Dictionary) -> void:
	mouth_cues = event.get("mouth_cues", []) if event.get("mouth_cues", []) is Array else []
	var use_streaming := bool(event.get("streaming", false))
	if use_streaming:
		_begin_streamed_audio_output(event)
		return

	collecting_audio_output = true
	streaming_audio_output = false
	streaming_audio_finished = false
	output_audio_buffer.clear()
	output_audio_rate = int(event.get("sample_rate", DEFAULT_OUTPUT_SAMPLE_RATE))
	output_audio_stereo = false
	_set_awaiting_response(true)
	vad.reset_barge_watch()
	status_changed.emit("Thinking")


func _begin_streamed_audio_output(event: Dictionary) -> void:
	collecting_audio_output = false
	output_audio_buffer.clear()
	streaming_audio_output = true
	streaming_audio_finished = false
	stream_output_received_bytes = 0
	stream_pending_audio_buffer.clear()
	output_audio_rate = int(event.get("sample_rate", DEFAULT_OUTPUT_SAMPLE_RATE))
	output_audio_stereo = false
	_set_awaiting_response(true)
	vad.reset_barge_watch()

	var stream := AudioStreamGenerator.new()
	stream.mix_rate = output_audio_rate
	stream.buffer_length = streaming_audio_buffer_seconds
	stream_generator_buffer_frames = max(1, int(round(float(output_audio_rate) * stream.buffer_length)))

	playback_player.stop()
	playback_player.stream = stream
	playback_player.play()
	audio_playback_started.emit(mouth_cues)
	stream_generator_playback = playback_player.get_stream_playback() as AudioStreamGeneratorPlayback
	playback_started_ms = Time.get_ticks_msec()
	playback_was_playing = true
	status_changed.emit("Speaking")


func _push_streamed_audio(audio_bytes: PackedByteArray) -> void:
	stream_output_received_bytes += audio_bytes.size()
	stream_pending_audio_buffer.append_array(audio_bytes)


func _pump_streamed_audio() -> void:
	if stream_generator_playback == null or stream_pending_audio_buffer.is_empty():
		return

	var frame_count := int(float(stream_pending_audio_buffer.size()) / 2.0)
	var frames_available := stream_generator_playback.get_frames_available()
	var frames_to_push: int = min(frame_count, frames_available)
	for frame_index in range(frames_to_push):
		var sample: float = float(XR_AUDIO_CODEC.read_i16_le(stream_pending_audio_buffer, frame_index * 2)) / 32768.0
		stream_generator_playback.push_frame(Vector2(sample, sample))

	if frames_to_push > 0:
		stream_pending_audio_buffer = stream_pending_audio_buffer.slice(frames_to_push * 2)


func _play_collected_audio() -> void:
	if output_audio_buffer.is_empty():
		collecting_audio_output = false
		return

	var audio_bytes: PackedByteArray = output_audio_buffer.duplicate()
	output_audio_buffer.clear()
	collecting_audio_output = false
	_play_audio_bytes(audio_bytes)


func _play_audio_bytes(audio_bytes: PackedByteArray) -> void:
	var playback_data: PackedByteArray = audio_bytes
	var playback_rate: int = output_audio_rate
	var playback_stereo := output_audio_stereo
	if XR_AUDIO_CODEC.is_wav(audio_bytes):
		var wav_info := XR_AUDIO_CODEC.extract_wav_payload(audio_bytes, DEFAULT_OUTPUT_SAMPLE_RATE)
		var wav_data_value: Variant = wav_info.get("data", PackedByteArray())
		if wav_data_value is PackedByteArray and not (wav_data_value as PackedByteArray).is_empty():
			playback_data = wav_data_value as PackedByteArray
			playback_rate = int(wav_info.get("sample_rate", DEFAULT_OUTPUT_SAMPLE_RATE))
			playback_stereo = int(wav_info.get("channels", 1)) == 2

	var playback_duration_ms := XR_AUDIO_CODEC.estimate_pcm16_duration_ms(playback_data.size(), playback_rate, 2 if playback_stereo else 1)
	mic_suppressed_until_ms = Time.get_ticks_msec() + playback_duration_ms + playback_suppression_padding_ms
	_drain_capture_buffer()

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = playback_rate
	stream.stereo = playback_stereo
	stream.data = playback_data
	playback_player.stop()
	playback_player.stream = stream
	playback_player.play()
	audio_playback_started.emit(mouth_cues)
	playback_started_ms = Time.get_ticks_msec()
	playback_was_playing = true
	vad.reset_barge_watch()
	status_changed.emit("Speaking")


func _setup_audio_output() -> void:
	if playback_player == null:
		push_error("XRAgentClient requires a PlaybackPlayer child node.")


func _setup_microphone_capture() -> void:
	if OS.has_method("request_permissions"):
		OS.request_permissions()

	var bus_index := AudioServer.get_bus_index(capture_bus_name)
	if bus_index == -1:
		AudioServer.add_bus()
		bus_index = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(bus_index, capture_bus_name)

	AudioServer.set_bus_volume_db(bus_index, -80.0)
	capture_effect = _get_or_create_capture_effect(bus_index)

	if microphone_player == null:
		push_error("XRAgentClient requires a MicrophonePlayer child node.")
		return

	microphone_player.stream = AudioStreamMicrophone.new()
	microphone_player.bus = capture_bus_name
	microphone_player.play()


func _get_or_create_capture_effect(bus_index: int) -> AudioEffectCapture:
	for effect_index in range(AudioServer.get_bus_effect_count(bus_index)):
		var effect := AudioServer.get_bus_effect(bus_index, effect_index)
		if effect is AudioEffectCapture:
			return effect as AudioEffectCapture

	var new_capture := AudioEffectCapture.new()
	AudioServer.add_bus_effect(bus_index, new_capture, 0)
	return new_capture


func _stop_microphone() -> void:
	if microphone_player != null:
		microphone_player.stop()


func _ensure_microphone_running() -> void:
	if microphone_player == null:
		_setup_microphone_capture()
	elif not microphone_player.playing:
		microphone_player.play()

	vad.reset_mic_watch()


func _capture_and_stream_audio(_delta: float) -> void:
	if capture_effect == null:
		return
	if not transport.is_open() or not session_started:
		return

	var output_busy: bool = awaiting_response or collecting_audio_output or (playback_player != null and playback_player.playing)
	if output_busy:
		_capture_for_barge_in(_delta)
		return

	if Time.get_ticks_msec() < mic_suppressed_until_ms:
		_drain_capture_buffer()
		return

	vad.reset_barge_watch()
	var frames_available: int = capture_effect.get_frames_available()
	if frames_available < frames_per_chunk:
		vad.note_silence(_delta)
		return

	vad.reset_mic_watch()
	while capture_effect.get_frames_available() >= frames_per_chunk:
		var frames: PackedVector2Array = capture_effect.get_buffer(frames_per_chunk)
		var chunk := XR_AUDIO_CODEC.frames_to_float32_mono(frames, input_gain)
		var level := XR_AUDIO_CODEC.calculate_rms(frames, input_gain)
		if vad.turn_active and not _send_binary(chunk):
			_fail_realtime_send("Unable to stream microphone audio. Reconnecting.")
			return
		vad.process_chunk(chunk, level)


func _capture_for_barge_in(_delta: float) -> void:
	if not barge_in_enabled:
		_drain_capture_buffer()
		return
	if playback_player != null and playback_player.playing:
		var playback_age_ms: int = Time.get_ticks_msec() - playback_started_ms
		if playback_age_ms < barge_in_grace_ms:
			_drain_capture_buffer()
			return

	var frames_available: int = capture_effect.get_frames_available()
	if frames_available < frames_per_chunk:
		return

	while capture_effect.get_frames_available() >= frames_per_chunk:
		var frames: PackedVector2Array = capture_effect.get_buffer(frames_per_chunk)
		var chunk: PackedByteArray = XR_AUDIO_CODEC.frames_to_float32_mono(frames, input_gain)
		var level: float = XR_AUDIO_CODEC.calculate_rms(frames, input_gain)
		if vad.process_barge_chunk(chunk, level):
			return


func _on_turn_started(preroll: Array[PackedByteArray]) -> void:
	status_changed.emit("Listening")
	for buffered_chunk in preroll:
		if not _send_binary(buffered_chunk):
			_fail_realtime_send("Unable to stream buffered microphone audio. Reconnecting.")
			return


func _on_turn_committed() -> void:
	turn_committing.emit()
	if not _send_json({"type": "audio.commit"}):
		_fail_realtime_send("Unable to send voice turn. Reconnecting.")
		return

	_set_awaiting_response(true)
	status_changed.emit("Thinking")


func _on_turn_cancelled() -> void:
	status_changed.emit("Listening")
	_send_json({"type": "audio.cancel"})


func _on_barge_in() -> void:
	_stop_audio_output()
	output_audio_buffer.clear()
	collecting_audio_output = false
	awaiting_response = false
	response_started_ms = 0
	mic_suppressed_until_ms = 0
	_send_json({"type": "barge_in"})
	vad.begin_barge_in()
	status_changed.emit("Interrupted")


func _on_mic_silent() -> void:
	_ensure_microphone_running()
	error_received.emit("Microphone is not producing audio frames.")


func _stop_audio_output() -> void:
	mouth_cues.clear()
	audio_playback_stopped.emit()
	if playback_player != null:
		playback_player.stop()
		playback_player.stream = null
	stream_generator_playback = null
	streaming_audio_output = false
	streaming_audio_finished = false
	stream_pending_audio_buffer.clear()
	collecting_audio_output = false
	playback_was_playing = false
	playback_started_ms = 0


func _set_awaiting_response(is_awaiting: bool) -> void:
	awaiting_response = is_awaiting
	if is_awaiting:
		var now_ms := Time.get_ticks_msec()
		response_started_ms = now_ms
		last_server_event_ms = now_ms
	else:
		response_started_ms = 0


func _update_response_watchdog() -> void:
	if not awaiting_response or response_timeout_seconds <= 0.0:
		return

	var now_ms := Time.get_ticks_msec()
	var started_age_ms := now_ms - response_started_ms
	var event_age_ms := now_ms - last_server_event_ms
	var timeout_ms := int(response_timeout_seconds * 1000.0)
	if started_age_ms < timeout_ms and event_age_ms < timeout_ms:
		return

	awaiting_response = false
	response_started_ms = 0
	_stop_audio_output()
	vad.reset()
	transport.close()
	error_received.emit("Risposta AI non arrivata in tempo. Riconnessione al server in corso.")
	status_changed.emit("Offline")
	transport.schedule_reconnect()


func _update_playback_state() -> void:
	if playback_player == null:
		return
	if streaming_audio_output:
		_pump_streamed_audio()
		if streaming_audio_finished and stream_generator_playback != null:
			var frames_available := stream_generator_playback.get_frames_available()
			if stream_pending_audio_buffer.is_empty() and frames_available >= max(1, stream_generator_buffer_frames - frames_per_chunk):
				_stop_audio_output()
				if not awaiting_response and not vad.turn_active:
					status_changed.emit("Listening")
		return
	if playback_player.playing:
		playback_was_playing = true
		return
	if playback_was_playing:
		audio_playback_stopped.emit()
		mouth_cues.clear()
		playback_was_playing = false
		if not awaiting_response and not collecting_audio_output and not vad.turn_active:
			status_changed.emit("Listening")


func _drain_capture_buffer() -> void:
	if capture_effect == null:
		return

	var available: int = capture_effect.get_frames_available()
	while available > 0:
		var take_count: int = min(available, frames_per_chunk)
		capture_effect.get_buffer(take_count)
		available = capture_effect.get_frames_available()


func _fail_realtime_send(message: String) -> void:
	awaiting_response = false
	response_started_ms = 0
	vad.reset()
	_stop_audio_output()
	transport.close()
	error_received.emit(message)
	status_changed.emit("Offline")
	transport.schedule_reconnect()


func _send_json(payload: Dictionary) -> bool:
	return transport.send_json(payload)


func _send_binary(bytes: PackedByteArray) -> bool:
	return transport.send_binary(bytes)
