import asyncio
from types import SimpleNamespace

from xr_agent_proxy.models import ProviderTurnResult, SceneState, TranscriptionResult, VisionDecision
from xr_agent_proxy.session import RealtimeSession


class FakeWebSocket:
    def __init__(self) -> None:
        self.sent_json: list[dict] = []
        self.sent_bytes: list[bytes] = []

    async def send_json(self, payload: dict) -> None:
        self.sent_json.append(payload)

    async def send_bytes(self, payload: bytes) -> None:
        self.sent_bytes.append(payload)


class FakeProvider:
    def __init__(self, decision: VisionDecision) -> None:
        self.settings = SimpleNamespace(
            audio_chunk_bytes=4096,
            output_sample_rate=24_000,
            vision_agent_enabled=True,
            vision_snapshot_timeout_seconds=1.0,
        )
        self.decision = decision
        self.chat_calls: list[dict] = []

    async def transcribe_float32(self, _pcm_bytes: bytes, _sample_rate: int) -> TranscriptionResult:
        return TranscriptionResult(text="cosa vedi?", language="it")

    async def decide_vision(self, user_text: str, scene: SceneState) -> VisionDecision:
        assert user_text == "cosa vedi?"
        assert scene.active_demo == "llm"
        return self.decision

    async def chat(
        self,
        user_text: str,
        scene: SceneState,
        image_jpeg_base64: str | None = None,
        response_language: str | None = None,
    ) -> str:
        self.chat_calls.append(
            {
                "user_text": user_text,
                "active_demo": scene.active_demo,
                "image": image_jpeg_base64,
                "language": response_language,
            }
        )
        return "vedo lo snapshot" if image_jpeg_base64 else "risposta testuale"

    async def synthesize(self, _text: str, _language: str | None = None) -> bytes:
        return b"audio"


class FakeTurnProvider:
    supports_audio_turn = True

    def __init__(self) -> None:
        self.settings = SimpleNamespace(
            audio_chunk_bytes=4096,
            output_sample_rate=24_000,
            google_output_sample_rate=24_000,
        )

    async def generate_audio_turn(
        self,
        _pcm_bytes: bytes,
        _sample_rate: int,
        scene: SceneState,
        _request_snapshot,
        _send_event,
        _send_audio_chunk=None,
        _initial_video_frame=None,
        _next_video_frame=None,
    ) -> ProviderTurnResult:
        assert scene.active_demo == "llm"
        return ProviderTurnResult(
            transcript="ciao",
            response_text="ciao dal provider",
            audio=b"pcm16",
            output_sample_rate=24_000,
        )


class FakeStreamingTurnProvider(FakeTurnProvider):
    async def generate_audio_turn(
        self,
        _pcm_bytes: bytes,
        _sample_rate: int,
        scene: SceneState,
        _request_snapshot,
        _send_event,
        send_audio_chunk=None,
        _initial_video_frame=None,
        _next_video_frame=None,
    ) -> ProviderTurnResult:
        assert scene.active_demo == "llm"
        assert send_audio_chunk is not None
        await send_audio_chunk(b"chunk1", 24_000)
        await send_audio_chunk(b"chunk2", 24_000)
        return ProviderTurnResult(
            transcript="ciao",
            response_text="risposta streaming",
            audio=b"chunk1chunk2",
            output_sample_rate=24_000,
        )


class FakeVideoTurnProvider(FakeTurnProvider):
    def __init__(self) -> None:
        super().__init__()
        self.settings.google_video_stream_enabled = True
        self.settings.google_video_max_frame_age_seconds = 2.5
        self.initial_video_frame: dict | None = None
        self.queued_video_frame: dict | None = None

    async def generate_audio_turn(
        self,
        _pcm_bytes: bytes,
        _sample_rate: int,
        scene: SceneState,
        _request_snapshot,
        _send_event,
        _send_audio_chunk=None,
        initial_video_frame=None,
        next_video_frame=None,
    ) -> ProviderTurnResult:
        assert scene.active_demo == "llm"
        self.initial_video_frame = initial_video_frame
        assert next_video_frame is not None
        self.queued_video_frame = await next_video_frame(0.01)
        return ProviderTurnResult(
            transcript="ciao",
            response_text="video ok",
            audio=b"pcm16",
            output_sample_rate=24_000,
        )


class FakeSlowProvider(FakeProvider):
    async def transcribe_float32(self, _pcm_bytes: bytes, _sample_rate: int) -> TranscriptionResult:
        await asyncio.sleep(10.0)
        return TranscriptionResult(text="late", language="en")


def test_audio_turn_can_request_snapshot_without_blocking_websocket_loop() -> None:
    async def scenario() -> None:
        websocket = FakeWebSocket()
        provider = FakeProvider(
            VisionDecision(
                needs_snapshot=True,
                snapshot_prompt="Descrivi cosa si vede nello snapshot.",
                reason="La domanda richiede visione corrente.",
            )
        )
        session = RealtimeSession(websocket, provider)
        session.state.scene.active_demo = "llm"

        await session.handle_audio(b"\x00" * 64)
        await session.handle_json({"type": "audio.commit"})

        snapshot_request = await _wait_for_event(websocket, "vision.snapshot.request")
        assert snapshot_request["request_id"].startswith("auto_")
        assert snapshot_request["prompt"] == "Capture the current Quest camera view for the user's original request."

        await session.handle_json(
            {
                "type": "vision.snapshot",
                "request_id": snapshot_request["request_id"],
                "image_jpeg_base64": "fake_jpeg",
                "metadata": {"active_demo_id": "llm", "objects": ["panel"]},
            }
        )
        assert session.turn_task is not None
        await asyncio.wait_for(session.turn_task, timeout=1.0)

        assert provider.chat_calls[-1]["image"] == "fake_jpeg"
        assert provider.chat_calls[-1]["user_text"] == "cosa vedi?"
        assert _has_event(websocket, "vision.ready")
        assert _has_event(websocket, "llm.done")
        assert _has_event(websocket, "audio.output.start")

    asyncio.run(scenario())


def test_barge_in_cancels_running_audio_turn() -> None:
    async def scenario() -> None:
        websocket = FakeWebSocket()
        provider = FakeSlowProvider(VisionDecision(needs_snapshot=False))
        session = RealtimeSession(websocket, provider)
        session.state.scene.active_demo = "llm"

        await session.handle_audio(b"\x00" * 64)
        await session.handle_json({"type": "audio.commit"})
        await _wait_for_event(websocket, "stt.start")

        await session.handle_json({"type": "barge_in"})
        assert _has_event(websocket, "barge_in.ack")

        assert session.turn_task is not None
        try:
            await asyncio.wait_for(session.turn_task, timeout=1.0)
        except asyncio.CancelledError:
            pass

        assert session.turn_task.cancelled()
        assert _has_event(websocket, "turn.cancelled")

    asyncio.run(scenario())


def test_audio_turn_skips_snapshot_when_planner_says_text_is_enough() -> None:
    async def scenario() -> None:
        websocket = FakeWebSocket()
        provider = FakeProvider(VisionDecision(needs_snapshot=False, reason="No vision needed."))
        session = RealtimeSession(websocket, provider)
        session.state.scene.active_demo = "llm"

        await session.handle_audio(b"\x00" * 64)
        await session.handle_json({"type": "audio.commit"})

        assert session.turn_task is not None
        await asyncio.wait_for(session.turn_task, timeout=1.0)

        assert not _has_event(websocket, "vision.snapshot.request")
        assert provider.chat_calls[-1]["image"] is None
        assert _has_event(websocket, "llm.done")

    asyncio.run(scenario())


def test_audio_turn_provider_keeps_quest_protocol_events() -> None:
    async def scenario() -> None:
        websocket = FakeWebSocket()
        provider = FakeTurnProvider()
        session = RealtimeSession(websocket, provider)
        session.state.scene.active_demo = "llm"

        await session.handle_audio(b"\x00" * 64)
        await session.handle_json({"type": "audio.commit"})

        assert session.turn_task is not None
        await asyncio.wait_for(session.turn_task, timeout=1.0)

        assert _has_event(websocket, "stt.done")
        assert _has_event(websocket, "llm.done")
        assert _has_event(websocket, "tts.start")
        assert _has_event(websocket, "audio.output.start")
        assert _has_event(websocket, "tts.done")
        assert websocket.sent_bytes == [b"pcm16"]

    asyncio.run(scenario())


def test_streaming_audio_turn_sends_chunks_without_duplicate_full_audio() -> None:
    async def scenario() -> None:
        websocket = FakeWebSocket()
        provider = FakeStreamingTurnProvider()
        session = RealtimeSession(websocket, provider)
        session.state.scene.active_demo = "llm"

        await session.handle_audio(b"\x00" * 64)
        await session.handle_json({"type": "audio.commit"})

        assert session.turn_task is not None
        await asyncio.wait_for(session.turn_task, timeout=1.0)

        output_start = next(payload for payload in websocket.sent_json if payload.get("type") == "audio.output.start")
        assert output_start["streaming"] is True
        assert websocket.sent_bytes == [b"chunk1", b"chunk2"]
        tts_done = next(payload for payload in websocket.sent_json if payload.get("type") == "tts.done")
        assert tts_done["bytes"] == len(b"chunk1chunk2")

    asyncio.run(scenario())


def test_video_frame_is_available_to_audio_turn_provider() -> None:
    async def scenario() -> None:
        websocket = FakeWebSocket()
        provider = FakeVideoTurnProvider()
        session = RealtimeSession(websocket, provider)
        session.state.scene.active_demo = "llm"

        await session.handle_json(
            {
                "type": "vision.video_frame",
                "image_jpeg_base64": "fake_frame",
                "metadata": {"active_demo_id": "llm"},
            }
        )
        await session.handle_audio(b"\x00" * 64)
        await session.handle_json({"type": "audio.commit"})

        assert session.turn_task is not None
        await asyncio.wait_for(session.turn_task, timeout=1.0)

        assert provider.initial_video_frame is not None
        assert provider.initial_video_frame["image_jpeg_base64"] == "fake_frame"
        assert provider.queued_video_frame is not None
        assert provider.queued_video_frame["image_jpeg_base64"] == "fake_frame"

    asyncio.run(scenario())


async def _wait_for_event(websocket: FakeWebSocket, event_type: str) -> dict:
    for _index in range(100):
        for payload in websocket.sent_json:
            if payload.get("type") == event_type:
                return payload
        await asyncio.sleep(0.01)
    raise AssertionError(f"event not found: {event_type}")


def _has_event(websocket: FakeWebSocket, event_type: str) -> bool:
    return any(payload.get("type") == event_type for payload in websocket.sent_json)
