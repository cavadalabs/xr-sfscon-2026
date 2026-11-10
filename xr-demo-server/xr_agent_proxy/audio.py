import io
import math
import struct
import wave


def float32_pcm_to_wav_bytes(pcm_bytes: bytes, sample_rate: int) -> bytes:
    if not pcm_bytes:
        return b""

    pcm16 = bytearray()
    usable_length = len(pcm_bytes) - (len(pcm_bytes) % 4)
    for (sample,) in struct.iter_unpack("<f", pcm_bytes[:usable_length]):
        clamped = max(-1.0, min(1.0, sample))
        pcm16.extend(struct.pack("<h", int(clamped * 32767.0)))

    with io.BytesIO() as output:
        with wave.open(output, "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(sample_rate)
            wav_file.writeframes(bytes(pcm16))
        return output.getvalue()


def float32_pcm_to_pcm16_bytes(pcm_bytes: bytes, source_sample_rate: int, target_sample_rate: int | None = None) -> bytes:
    if not pcm_bytes:
        return b""

    samples = _float32_samples(pcm_bytes)
    if not samples:
        return b""

    output_samples = samples
    if target_sample_rate is not None and target_sample_rate > 0 and target_sample_rate != source_sample_rate:
        output_samples = _resample_mono(samples, source_sample_rate, target_sample_rate)

    return _pack_pcm16(output_samples)


def _float32_samples(pcm_bytes: bytes) -> list[float]:
    usable_length = len(pcm_bytes) - (len(pcm_bytes) % 4)
    if usable_length <= 0:
        return []
    return [max(-1.0, min(1.0, sample)) for (sample,) in struct.iter_unpack("<f", pcm_bytes[:usable_length])]


def _resample_mono(samples: list[float], source_sample_rate: int, target_sample_rate: int) -> list[float]:
    if source_sample_rate <= 0 or target_sample_rate <= 0 or source_sample_rate == target_sample_rate:
        return samples
    if len(samples) <= 1:
        return samples

    target_count = max(1, int(math.ceil(len(samples) * target_sample_rate / source_sample_rate)))
    source_step = source_sample_rate / target_sample_rate
    resampled: list[float] = []

    for target_index in range(target_count):
        source_position = target_index * source_step
        left_index = min(int(source_position), len(samples) - 1)
        right_index = min(left_index + 1, len(samples) - 1)
        fraction = source_position - left_index
        left = samples[left_index]
        right = samples[right_index]
        resampled.append(left + (right - left) * fraction)

    return resampled


def _pack_pcm16(samples: list[float]) -> bytes:
    pcm16 = bytearray()
    for sample in samples:
        clamped = max(-1.0, min(1.0, sample))
        pcm16.extend(struct.pack("<h", int(clamped * 32767.0)))
    return bytes(pcm16)
