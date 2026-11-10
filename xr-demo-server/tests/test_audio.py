import wave
from io import BytesIO

from xr_agent_proxy.audio import float32_pcm_to_pcm16_bytes, float32_pcm_to_wav_bytes


def test_float32_pcm_to_wav_bytes() -> None:
    wav_bytes = float32_pcm_to_wav_bytes(b"\x00" * 16, 48_000)

    with wave.open(BytesIO(wav_bytes), "rb") as wav_file:
        assert wav_file.getnchannels() == 1
        assert wav_file.getsampwidth() == 2
        assert wav_file.getframerate() == 48_000


def test_float32_pcm_to_pcm16_resamples_to_target_rate() -> None:
    pcm16 = float32_pcm_to_pcm16_bytes(b"\x00" * 48_000 * 4, 48_000, 16_000)

    assert len(pcm16) == 16_000 * 2
