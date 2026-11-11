extends RefCounted
## Voice-activity turn machine (issue #29): decides when speech opens a turn,
## buffers the preroll, times trailing silence, enforces the minimum turn and
## voice lengths and counts barge-in interruptions. Pure state: no socket,
## microphone or speaker here. The client feeds captured chunks and performs
## the network actions the signals ask for.


## The turn opened: send these preroll chunks (failure is the client's).
signal turn_started(preroll: Array[PackedByteArray])
## Trailing silence ended a long enough turn: the client sends audio.commit.
signal turn_committed
## The turn was too short to count: the client sends audio.cancel.
signal turn_cancelled
## Enough loud chunks while the agent speaks: the client stops the output,
## sends barge_in and calls begin_barge_in().
signal barge_in
## No capture frames for MIC_SILENT_MS: the client should restart the mic.
signal mic_silent

const FRAME_MS := 20.0
const MIC_SILENT_MS := 2500.0

## Mirrored from the client's exported tuning fields in _ready.
var voice_threshold := 0.018
var min_voice_chunks := 4
var silence_commit_ms := 600
var max_turn_seconds := 12.0
var preroll_chunk_count := 8
var min_turn_ms := 700
var min_voice_ms := 300
var barge_in_threshold_multiplier := 1.7
var barge_in_voice_chunks := 3

var turn_active := false
var voiced_chunks := 0
var silence_ms := 0.0
var turn_ms := 0.0
var turn_voice_ms := 0.0
var pending_chunks: Array[PackedByteArray] = []
var barge_in_chunks_seen := 0
var no_mic_frames_ms := 0.0
var mic_warning_sent := false


## One captured chunk while idle (buffered as preroll) or mid-turn. Mid-turn
## chunks must already be on the wire: the client sends them before calling.
func process_chunk(chunk: PackedByteArray, level: float) -> void:
	var has_voice := level >= voice_threshold
	if turn_active:
		turn_ms += FRAME_MS
		if has_voice:
			silence_ms = 0.0
			turn_voice_ms += FRAME_MS
		else:
			silence_ms += FRAME_MS
		if silence_ms >= float(silence_commit_ms) or turn_ms >= max_turn_seconds * 1000.0:
			_finish()
		return

	_append(chunk)
	if has_voice:
		voiced_chunks += 1
		if voiced_chunks >= min_voice_chunks:
			_begin()
	else:
		voiced_chunks = 0


## A chunk heard while the agent speaks: the stricter threshold decides
## whether the interruption counter grows or resets. Returns true when the
## barge_in event was raised: the client must stop draining more frames.
func process_barge_chunk(chunk: PackedByteArray, level: float) -> bool:
	if level < voice_threshold * barge_in_threshold_multiplier:
		barge_in_chunks_seen = 0
		return false
	_append(chunk)
	barge_in_chunks_seen += 1
	if barge_in_chunks_seen < barge_in_voice_chunks:
		return false
	voiced_chunks = barge_in_chunks_seen
	barge_in_chunks_seen = 0
	barge_in.emit()
	return true


## The client stopped the output and sent barge_in: open the turn carrying
## the voiced chunks that triggered the interruption.
func begin_barge_in() -> void:
	_begin()


## Called once per frame when the capture held less than one chunk.
func note_silence(delta: float) -> void:
	no_mic_frames_ms += delta * 1000.0
	if turn_active:
		silence_ms += delta * 1000.0
		turn_ms += delta * 1000.0
		if silence_ms >= float(silence_commit_ms) or turn_ms >= max_turn_seconds * 1000.0:
			_finish()
		return
	if no_mic_frames_ms >= MIC_SILENT_MS and not mic_warning_sent:
		mic_warning_sent = true
		mic_silent.emit()


## The client (re)started the microphone: the silent-mic window restarts.
func reset_mic_watch() -> void:
	no_mic_frames_ms = 0.0
	mic_warning_sent = false


## New agent output begins: stale barge-in counts must not leak into it.
func reset_barge_watch() -> void:
	barge_in_chunks_seen = 0


## Drop the turn bookkeeping (socket close, server events, send failures).
func reset() -> void:
	turn_active = false
	voiced_chunks = 0
	silence_ms = 0.0
	turn_ms = 0.0
	turn_voice_ms = 0.0
	pending_chunks.clear()


func _begin() -> void:
	turn_active = true
	silence_ms = 0.0
	turn_ms = float(pending_chunks.size()) * FRAME_MS
	turn_voice_ms = float(voiced_chunks) * FRAME_MS
	var preroll := pending_chunks.duplicate()
	pending_chunks.clear()
	turn_started.emit(preroll)


func _finish() -> void:
	if turn_ms < float(min_turn_ms) or turn_voice_ms < float(min_voice_ms):
		reset()
		turn_cancelled.emit()
		return
	reset()
	turn_committed.emit()


func _append(chunk: PackedByteArray) -> void:
	pending_chunks.append(chunk)
	while pending_chunks.size() > preroll_chunk_count:
		pending_chunks.pop_front()
