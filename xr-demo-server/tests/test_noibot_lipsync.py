import asyncio
from types import SimpleNamespace

from xr_agent_proxy.config import Settings
from xr_agent_proxy.lipsync import mouth_cues
from xr_agent_proxy.session import RealtimeSession


def test_cues_travel_with_the_exact_audio_only_when_noibot_is_enabled(monkeypatch):
    events, chunks, analyzed = [], [], []

    async def send_json(event):
        events.append(event)

    async def send_bytes(chunk):
        chunks.append(chunk)

    async def analyze(audio, rate, settings):
        analyzed.append((audio, rate))
        return [{"start": 0, "end": 0.2, "value": "D"}]

    monkeypatch.setattr("xr_agent_proxy.session.mouth_cues", analyze)
    session = RealtimeSession(SimpleNamespace(send_json=send_json, send_bytes=send_bytes),
                              SimpleNamespace(settings=Settings(_env_file=None)))
    audio = b"\0\0" * 10000
    asyncio.run(session._send_audio_chunks(audio))
    assert not analyzed and events[0]["mouth_cues"] == []
    session.state.scene.metadata["avatar"] = "noibot"
    events.clear()
    chunks.clear()
    asyncio.run(session._send_audio_chunks(audio, "turn-2"))
    assert analyzed == [(audio, 24000)]
    assert b"".join(chunks) == audio
    assert events[0]["request_id"] == "turn-2"
    assert events[0]["mouth_cues"] == [{"start": 0, "end": 0.2, "value": "D"}]


def test_optional_analysis_fails_open_for_voice():
    settings = Settings(_env_file=None, lipsync_package="")
    assert asyncio.run(mouth_cues(b"\0\0", 24000, settings)) == []
    settings.lipsync_package = "/missing/rhubarb"
    assert asyncio.run(mouth_cues(b"odd", 24000, settings)) == []
    assert asyncio.run(mouth_cues(b"\0\0", 0, settings)) == []
    assert asyncio.run(mouth_cues(b"RIFFinvalid", 24000, settings)) == []
