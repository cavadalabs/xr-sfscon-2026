class_name NoiBotController
extends Node3D
## Pivot rig rigido + visemi. Nessuna dipendenza dall'LLM o dalle demo XR.
## play_speech(stream, cues) usa cue [{start, end, value}] in secondi.
## Il parametro format distingue i nomi NoiBot da A-H/X di Rhubarb.
signal speech_finished

const RHUBARB := {"A":"PP", "B":"SS", "C":"E", "D":"AA", "E":"O", "F":"U", "G":"FF", "H":"L", "X":"rest"}
var model: Node3D
var mouth: MeshInstance3D
var lids: Array[MeshInstance3D] = []
var pivots: Dictionary = {}
var rest_rotation: Dictionary = {}
var rest_quaternion: Dictionary = {}
var motion: Dictionary
var gestures: Array = []
@export_range(0.0, 1.0, 0.1) var motion_intensity := 1.0
@onready var player: AudioStreamPlayer3D = $Player
var external_player: AudioStreamPlayer
var cues: Array = []
var cue_format := "rhubarb"
var cue_index := 0
var elapsed := 0.0
var wave_time := -1.0
var manual_viseme := "rest"
var listening := false
var audio_level := 0.0
var voice_level_mode := false

func _ready() -> void:
	motion = JSON.parse_string(FileAccess.get_file_as_string("res://data/noibot-motion.json"))
	# The XR viewer supplies its asynchronously loaded instance.
	assert(model != null)
	player.finished.connect(_finished)
	for n in model.find_children("*", "Node3D", true, false):
		if n.name == "Mouth": mouth = n as MeshInstance3D
		if str(n.name).begins_with("Lid_") and n is MeshInstance3D: lids.append(n)
		if motion.rest.has(str(n.name)):
			pivots[str(n.name)] = n
			rest_rotation[str(n.name)] = n.rotation
			rest_quaternion[str(n.name)] = n.quaternion
	assert(mouth != null and mouth.get_blend_shape_count() == 13)
	assert(lids.size() == 4 and pivots.size() == motion.rest.size())

func valid_cues(input: Array, format: String = "rhubarb") -> bool:
	if format not in ["rhubarb", "noibot"]: return false
	var previous_end := 0.0
	for item in input:
		if not item is Dictionary or not item.has_all(["start", "end", "value"]): return false
		if not (item.start is float or item.start is int) or not (item.end is float or item.end is int): return false
		if not item.value is String: return false
		var start := float(item.start)
		var end := float(item.end)
		if format == "rhubarb" and not RHUBARB.has(item.value): return false
		var shape := str(RHUBARB[item.value]) if format == "rhubarb" else str(item.value)
		if not is_finite(start) or not is_finite(end) or start < previous_end - 0.001 or end <= start: return false
		if shape != "rest" and mouth.find_blend_shape_by_name(shape) < 0: return false
		previous_end = end
	return true

func play_speech(stream: AudioStream, input: Array, format: String = "rhubarb") -> bool:
	if stream == null or not valid_cues(input,format): return false
	stop_speech()
	cue_format = format
	cues = input.duplicate(true)
	gestures = speech_gestures(cues)
	player.stream = stream
	player.play()
	return true

func follow_speech(source: AudioStreamPlayer, input: Array, format: String = "rhubarb") -> bool:
	# Follow the existing client player: one audio stream, one playback clock.
	if source == null or not valid_cues(input, format): return false
	stop_speech()
	external_player = source
	cue_format = format
	cues = input.duplicate(true)
	gestures = speech_gestures(cues)
	return true

func stop_speech() -> void:
	external_player = null
	player.stop()
	cues.clear()
	gestures.clear()
	cue_index = 0
	voice_level_mode = false
	audio_level = 0.0
	manual_viseme = "rest"
	if mouth:
		for i in mouth.get_blend_shape_count(): mouth.set_blend_shape_value(i, 0.0)

func _finished() -> void:
	stop_speech()
	speech_finished.emit()

func set_viseme(shape: String) -> bool:
	if shape != "rest" and mouth.find_blend_shape_by_name(shape) < 0: return false
	stop_speech()
	manual_viseme = shape
	return true

func set_voice_level(level: float) -> void:
	# ponytail: fallback a una vocale; usare cue temporali per articolazione fonetica.
	if not is_finite(level): return
	voice_level_mode = true
	audio_level = clampf(level, 0.0, 1.0)

func wave() -> void:
	wave_time = 0.0

func _process(delta: float) -> void:
	elapsed += delta
	var target := manual_viseme
	var speech_time := -1.0
	var playback: Node = external_player if is_instance_valid(external_player) else player
	if playback.playing:
		var t := maxf(0.0, playback.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency())
		if external_player != null and cues.is_empty():
			# Fallback only: amplitude follows sound, without pretending to infer phonemes.
			var stream := playback.stream as AudioStreamWAV
			var energy := 0.0
			var samples := 0
			if stream != null and stream.format == AudioStreamWAV.FORMAT_16_BITS:
				var pcm := stream.data
				var cursor := int(t * stream.mix_rate) * (2 if stream.stereo else 1) * 2
				for offset in range(cursor, mini(pcm.size() - 1, cursor + 960), 20):
					var sample := float(pcm.decode_s16(offset)) / 32768.0
					energy += sample * sample
					samples += 1
			set_voice_level(sqrt(energy / maxi(samples, 1)) * 5.0)
		speech_time = t
		while cue_index < cues.size() and t >= float(cues[cue_index].end): cue_index += 1
		target = "rest"
		if cue_index < cues.size() and t >= float(cues[cue_index].start): target = str(RHUBARB[cues[cue_index].value]) if cue_format == "rhubarb" else str(cues[cue_index].value)
	for i in mouth.get_blend_shape_count():
		var key := str(mouth.mesh.get_blend_shape_name(i))
		var value := 1.0 if key == target else 0.0
		if voice_level_mode: value = audio_level if key == "AA" else 0.0
		mouth.set_blend_shape_value(i, lerpf(mouth.get_blend_shape_value(i), value, 1.0-exp(-30.0*delta)))
	var blink_phase := fmod(elapsed, 4.1)
	var blink := maxf(0.0, 1.0-absf(blink_phase-3.8)/0.10)
	for lid in lids: lid.set_blend_shape_value(0, blink)
	if wave_time >= 0.0:
		wave_time += delta
		if wave_time > 4.4: wave_time = -1.0
	apply_body(delta, speech_time)

func speech_gestures(input: Array) -> Array:
	# ponytail: pause e durata guidano i gesti; nessuna interpretazione semantica.
	var groups: Array = []
	for cue in input:
		if cue.value in ["X", "rest"]: continue
		if groups.is_empty() or float(cue.start)-float(groups[-1].end) > .28 or float(cue.end)-float(groups[-1].start) > 3.6:
			groups.append({"start":float(cue.start),"end":float(cue.end)})
		else: groups[-1].end = float(cue.end)
	var result: Array = []
	for group in groups:
		if group.end-group.start <= .35: continue
		group.clip = ["right","left","open","left"][result.size()%4]
		result.append(group)
	for i in result.size():
		result[i].end = minf(result[i].end+.25,result[i+1].start if i+1 < result.size() else INF)
	return result

func sample_clip(clip: String, time: float, joint: String) -> Vector3:
	var frames: Array = motion.clips[clip]
	if time < 0.0 or time > float(frames[-1][0]): return Vector3.ZERO
	var i := 0
	while i < frames.size()-2 and time > float(frames[i+1][0]): i += 1
	var a: Array = frames[i]
	var b: Array = frames[i+1]
	var u := clampf((time-float(a[0]))/(float(b[0])-float(a[0])),0.0,1.0)
	var blend := u*u*u*(u*(u*6.0-15.0)+10.0)
	var va: Array = motion.poses[a[1]].get(joint,[0,0,0])
	var vb: Array = motion.poses[b[1]].get(joint,[0,0,0])
	return Vector3(va[0],va[1],va[2]).lerp(Vector3(vb[0],vb[1],vb[2]),blend)

func body_pose(speech_time: float) -> Dictionary:
	var clip := ""
	var time := 0.0
	var strength := 1.0
	for g in gestures:
		if speech_time >= g.start and speech_time <= g.end:
			clip = g.clip
			time = (speech_time-g.start)/(g.end-g.start)
			strength = minf(1.0,(g.end-g.start)/1.5)
			break
	if voice_level_mode and audio_level > .02:
		clip = ["right","left","open"][int(elapsed/4.0)%3]
		time = fmod(elapsed,4.0)/4.0
	if wave_time >= 0.0:
		clip = "wave"
		time = wave_time
		strength = 1.0
	var pose: Dictionary = {}
	for joint in motion.rest:
		var base: Array = motion.rest[joint]
		var v := sample_clip("idle",fmod(elapsed,16.0),joint)
		if clip != "": v += sample_clip(clip,time,joint)*strength
		if joint == "Head" and listening: v.z += .025
		pose[joint] = Vector3(base[0],base[1],base[2])+v*clampf(motion_intensity,0.0,1.0)
	return pose

func apply_body(delta: float, speech_time: float) -> void:
	var pose := body_pose(speech_time)
	for joint in pose:
		var offset := Basis.from_euler(pose[joint],EULER_ORDER_XYZ).get_rotation_quaternion()
		var goal: Quaternion = rest_quaternion[joint]*offset
		var angle: float = pivots[joint].quaternion.angle_to(goal)
		var blend := minf(1.0-exp(-9.0*delta),2.4*delta/maxf(angle,.00001))
		pivots[joint].quaternion = pivots[joint].quaternion.slerp(goal,blend)
