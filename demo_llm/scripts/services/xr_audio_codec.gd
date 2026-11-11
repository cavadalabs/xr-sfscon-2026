class_name XRAudioCodec
extends RefCounted


static func frames_to_float32_mono(frames: PackedVector2Array, gain: float) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(frames.size() * 4)
	for frame_index in range(frames.size()):
		var frame: Vector2 = frames[frame_index]
		var mono: float = clamp(((frame.x + frame.y) * 0.5) * gain, -1.0, 1.0)
		bytes.encode_float(frame_index * 4, mono)
	return bytes


static func calculate_rms(frames: PackedVector2Array, gain: float) -> float:
	if frames.is_empty():
		return 0.0

	var total := 0.0
	for frame in frames:
		var mono: float = ((frame.x + frame.y) * 0.5) * gain
		total += mono * mono
	return sqrt(total / float(frames.size()))


static func estimate_pcm16_duration_ms(byte_count: int, playback_rate: int, channel_count: int) -> int:
	if byte_count <= 0 or playback_rate <= 0 or channel_count <= 0:
		return 0

	var frame_count := float(byte_count) / float(2 * channel_count)
	return int(round((frame_count / float(playback_rate)) * 1000.0))


static func is_wav(bytes: PackedByteArray) -> bool:
	return bytes.size() >= 12 \
		and bytes[0] == 82 \
		and bytes[1] == 73 \
		and bytes[2] == 70 \
		and bytes[3] == 70 \
		and bytes[8] == 87 \
		and bytes[9] == 65 \
		and bytes[10] == 86 \
		and bytes[11] == 69


static func extract_wav_payload(bytes: PackedByteArray, default_sample_rate: int) -> Dictionary:
	var info := {
		"data": PackedByteArray(),
		"sample_rate": default_sample_rate,
		"channels": 1,
	}
	if bytes.size() < 44:
		return info

	info["channels"] = read_u16_le(bytes, 22)
	info["sample_rate"] = read_u32_le(bytes, 24)

	var offset := 12
	while offset + 8 <= bytes.size():
		var chunk_id := String.chr(bytes[offset]) + String.chr(bytes[offset + 1]) + String.chr(bytes[offset + 2]) + String.chr(bytes[offset + 3])
		var chunk_size := read_u32_le(bytes, offset + 4)
		var chunk_start := offset + 8
		var chunk_end: int = min(bytes.size(), chunk_start + chunk_size)
		if chunk_id == "data":
			info["data"] = bytes.slice(chunk_start, chunk_end)
			return info
		offset = chunk_end + (chunk_size % 2)

	return info


static func read_i16_le(bytes: PackedByteArray, offset: int) -> float:
	var value := read_u16_le(bytes, offset)
	if value >= 32768:
		value -= 65536
	return float(value)


static func read_u16_le(bytes: PackedByteArray, offset: int) -> int:
	if offset + 1 >= bytes.size():
		return 0
	return int(bytes[offset]) | (int(bytes[offset + 1]) << 8)


static func read_u32_le(bytes: PackedByteArray, offset: int) -> int:
	if offset + 3 >= bytes.size():
		return 0
	return int(bytes[offset]) \
		| (int(bytes[offset + 1]) << 8) \
		| (int(bytes[offset + 2]) << 16) \
		| (int(bytes[offset + 3]) << 24)
