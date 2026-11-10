import logging
import asyncio
import uuid
from time import perf_counter
from typing import Any

from fastapi import WebSocket
from starlette.websockets import WebSocketDisconnect

from xr_agent_proxy.models import ProviderTurnResult, SceneState, SessionState, TranscriptionResult, VisionDecision
from xr_agent_proxy.tools import create_get_what_user_is_seeing_tool
from xr_agent_proxy.lipsync import mouth_cues

logger = logging.getLogger("uvicorn.error")


class RealtimeSession:
    def __init__(self, websocket: WebSocket, provider: Any) -> None:
        self.websocket = websocket
        self.provider = provider
        self.state = SessionState()
        self.audio_buffer = bytearray()
        self.audio_chunk_count = 0
        self.pending_snapshots: dict[str, asyncio.Future[dict]] = {}
        self.turn_task: asyncio.Task | None = None
        self.send_lock = asyncio.Lock()
        self.latest_video_frame: dict | None = None
        self.latest_video_frame_at = 0.0
        self.video_frame_queue: asyncio.Queue[dict] = asyncio.Queue(maxsize=2)

    async def send_event(self, event_type: str, **payload) -> None:
        async with self.send_lock:
            await self.websocket.send_json({"type": event_type, **payload})

    async def try_send_event(self, event_type: str, **payload) -> bool:
        try:
            await self.send_event(event_type, **payload)
            return True
        except (RuntimeError, WebSocketDisconnect):
            return False

    async def handle_json(self, message: dict) -> None:
        message_type = str(message.get("type", ""))

        if message_type == "session.start":
            self.state.sample_rate = int(message.get("sample_rate") or self.state.sample_rate)
            self.audio_buffer.clear()
            self.audio_chunk_count = 0
            logger.info("session.start sample_rate=%s", self.state.sample_rate)
            await self.send_event("session.ready", sample_rate=self.state.sample_rate)
            return

        if message_type == "scene.state":
            self.state.scene = SceneState(
                objects=list(message.get("objects") or []),
                gaze_target=message.get("gaze_target"),
                active_demo=message.get("active_demo"),
                metadata=dict(message.get("metadata") or {}),
            )
            await self.send_event("scene.updated")
            return

        if message_type == "audio.commit":
            await self._start_audio_turn()
            return

        if message_type == "audio.cancel":
            self.audio_buffer.clear()
            self.audio_chunk_count = 0
            self._cancel_turn_task()
            logger.info("audio.cancel")
            await self.send_event("audio.cancelled")
            return

        if message_type == "barge_in":
            self.audio_buffer.clear()
            self.audio_chunk_count = 0
            self._cancel_turn_task()
            await self.send_event("barge_in.ack")
            return

        if message_type == "vision.snapshot":
            request_id = str(message.get("request_id") or "")
            if request_id in self.pending_snapshots:
                future = self.pending_snapshots.pop(request_id)
                if not future.done():
                    future.set_result(message)
                return

            if request_id.startswith("auto_"):
                logger.info("ignored orphan automatic vision.snapshot request_id=%s", request_id)
                return

            await self._handle_snapshot(message)
            return

        if message_type == "vision.snapshot.error":
            request_id = str(message.get("request_id") or "")
            message_text = str(message.get("message") or "Quest snapshot failed.")
            if request_id in self.pending_snapshots:
                future = self.pending_snapshots.pop(request_id)
                if not future.done():
                    future.set_exception(RuntimeError(message_text))
                return
            if request_id.startswith("auto_"):
                logger.info("ignored orphan automatic vision.snapshot.error request_id=%s message=%s", request_id, message_text)
                return
            logger.warning("vision.snapshot.error request_id=%s message=%s", request_id, message_text)
            return

        if message_type == "vision.video_frame":
            await self._handle_video_frame(message)
            return

        await self.send_event("error", message=f"Unsupported message type: {message_type}")

    async def handle_audio(self, audio_bytes: bytes) -> None:
        self.audio_buffer.extend(audio_bytes)
        self.audio_chunk_count += 1

    async def _start_audio_turn(self) -> None:
        if self.turn_task is not None and not self.turn_task.done():
            await self.send_event("turn.busy")
            return

        self.turn_task = asyncio.create_task(self._commit_audio_turn())
        self.turn_task.add_done_callback(self._log_turn_task_result)

    def _cancel_turn_task(self) -> None:
        if self.turn_task is not None and not self.turn_task.done():
            self.turn_task.cancel()

    def _log_turn_task_result(self, task: asyncio.Task) -> None:
        if task.cancelled():
            logger.info("turn task cancelled")
            return

        error = task.exception()
        if error is not None:
            logger.error("turn task failed", exc_info=(type(error), error, error.__traceback__))

    async def _commit_audio_turn(self) -> None:
        audio_bytes = bytes(self.audio_buffer)
        self.audio_buffer.clear()
        chunk_count = self.audio_chunk_count
        self.audio_chunk_count = 0

        if not audio_bytes:
            await self.send_event("error", message="No audio buffered.")
            return

        try:
            started_at = perf_counter()
            logger.info("audio.commit bytes=%s chunks=%s sample_rate=%s", len(audio_bytes), chunk_count, self.state.sample_rate)
            if bool(getattr(self.provider, "supports_audio_turn", False)):
                await self._commit_provider_audio_turn(audio_bytes, started_at)
                return

            await self.send_event("stt.start")
            transcription = self._normalize_transcription(
                await self.provider.transcribe_float32(audio_bytes, self.state.sample_rate)
            )
            transcript = transcription.text
            logger.info("turn.metric stage=stt_done ms=%.0f", self._elapsed_ms(started_at))
            logger.info("stt.done chars=%s language=%s text=%r", len(transcript), transcription.language, transcript[:120])
            await self.send_event("stt.done", text=transcript, language=transcription.language)

            if not transcript.strip():
                await self.send_event("turn.empty")
                return

            await self._answer(transcript, started_at=started_at, response_language=transcription.language)
            logger.info("turn.metric stage=turn_done ms=%.0f", self._elapsed_ms(started_at))
        except asyncio.CancelledError:
            await self.try_send_event("turn.cancelled")
            raise
        except Exception as exc:
            logger.exception("audio turn failed")
            await self.try_send_event("error", message=str(exc))

    async def _commit_provider_audio_turn(self, audio_bytes: bytes, started_at: float) -> None:
        await self.send_event("stt.start")
        await self.send_event("llm.start")
        output_sample_rate = int(getattr(self.provider.settings, "google_output_sample_rate", self.provider.settings.output_sample_rate))
        await self.send_event("tts.start", sample_rate=output_sample_rate)
        streamed_audio_started = False
        streamed_audio_bytes = 0
        first_audio_logged = False

        async def send_streamed_audio(audio_chunk: bytes, sample_rate: int) -> None:
            nonlocal streamed_audio_started, streamed_audio_bytes, first_audio_logged
            if not audio_chunk:
                return
            if not streamed_audio_started:
                streamed_audio_started = True
                await self.send_event(
                    "audio.output.start",
                    bytes=0,
                    chunk_bytes=max(4096, self.provider.settings.audio_chunk_bytes),
                    sample_rate=sample_rate,
                    encoding="pcm16",
                    streaming=True,
                )
            if not first_audio_logged:
                first_audio_logged = True
                logger.info("turn.metric stage=first_audio_chunk ms=%.0f", self._elapsed_ms(started_at))
            streamed_audio_bytes += len(audio_chunk)
            await self._send_binary(audio_chunk)

        async def next_video_frame(timeout_seconds: float) -> dict | None:
            return await self._wait_for_video_frame(timeout_seconds)

        result: ProviderTurnResult = await self.provider.generate_audio_turn(
            audio_bytes,
            self.state.sample_rate,
            self.state.scene,
            self._request_provider_snapshot,
            self.try_send_event,
            send_streamed_audio,
            self._fresh_latest_video_frame(),
            next_video_frame if self._video_stream_enabled() else None,
        )
        logger.info("turn.metric stage=provider_done ms=%.0f", self._elapsed_ms(started_at))

        if result.transcript:
            logger.info("stt.done chars=%s text=%r", len(result.transcript), result.transcript[:120])
            await self.send_event("stt.done", text=result.transcript)
        if result.response_text:
            logger.info("llm.done chars=%s", len(result.response_text))
            await self.send_event("llm.done", text=result.response_text)

        if streamed_audio_started:
            await self.send_event("audio.output.done", bytes=streamed_audio_bytes)
        elif result.audio:
            await self._send_audio_chunks(result.audio, sample_rate=result.output_sample_rate)
        await self.send_event("tts.done", bytes=streamed_audio_bytes if streamed_audio_started else len(result.audio))
        logger.info("turn.metric stage=turn_done ms=%.0f", self._elapsed_ms(started_at))

    async def _request_provider_snapshot(self, prompt: str, timeout_seconds: float) -> dict:
        fresh_frame = self._fresh_latest_video_frame()
        if fresh_frame is not None:
            return {
                "request_id": str(fresh_frame.get("request_id") or "video_latest"),
                "prompt": prompt,
                "image_jpeg_base64": str(fresh_frame.get("image_jpeg_base64") or ""),
                "metadata": dict(fresh_frame.get("metadata") or {}),
            }

        request_id = f"auto_{uuid.uuid4().hex}"
        await self.send_event("vision.start", request_id=request_id, reason="provider tool request")
        snapshot = await self.request_snapshot(request_id, prompt, timeout_seconds)
        return {
            "request_id": request_id,
            "prompt": prompt,
            "image_jpeg_base64": str(snapshot.get("image_jpeg_base64") or ""),
            "metadata": dict(snapshot.get("metadata") or {}),
        }

    async def _handle_snapshot(self, message: dict) -> None:
        request_id = str(message.get("request_id") or "")
        image = str(message.get("image_jpeg_base64") or "")
        prompt = str(message.get("prompt") or "Look at this snapshot and explain what matters.")
        await self.send_event("vision.start", request_id=request_id)
        await self._answer(prompt, image_jpeg_base64=image, request_id=request_id)

    async def _handle_video_frame(self, message: dict) -> None:
        if not self._video_stream_enabled():
            return

        image = str(message.get("image_jpeg_base64") or "")
        if image.strip() == "":
            return

        metadata = dict(message.get("metadata") or {})
        frame = {
            "request_id": str(message.get("request_id") or f"video_{uuid.uuid4().hex}"),
            "image_jpeg_base64": image,
            "metadata": metadata,
            "captured_at_ms": message.get("captured_at_ms"),
        }
        self.latest_video_frame = frame
        self.latest_video_frame_at = perf_counter()

        if self.video_frame_queue.full():
            try:
                self.video_frame_queue.get_nowait()
            except asyncio.QueueEmpty:
                pass
        try:
            self.video_frame_queue.put_nowait(frame)
        except asyncio.QueueFull:
            pass

    async def _answer(
        self,
        user_text: str,
        image_jpeg_base64: str | None = None,
        request_id: str | None = None,
        started_at: float | None = None,
        response_language: str | None = None,
    ) -> None:
        try:
            if started_at is None:
                started_at = perf_counter()
            await self.send_event("llm.start", request_id=request_id)
            response_text = await self._generate_response_text(user_text, image_jpeg_base64, response_language)
        except Exception as exc:
            logger.exception("llm failed")
            await self.try_send_event("error", message=str(exc), request_id=request_id)
            return

        logger.info("turn.metric stage=llm_done ms=%.0f", self._elapsed_ms(started_at))
        logger.info("llm.done chars=%s", len(response_text))
        await self.send_event("llm.done", text=response_text, request_id=request_id)

        try:
            await self.send_event("tts.start", sample_rate=self.provider.settings.output_sample_rate)
            streamed = False
            if (
                getattr(self.provider, "supports_tts_stream", False)
                and getattr(self.provider.settings, "tts_stream_enabled", True)
                and self.state.scene.metadata.get("avatar") not in ("noibot", "milo")
            ):
                streamed = await self._stream_local_tts(response_text, response_language, request_id, started_at)
            if not streamed:
                audio = await self.provider.synthesize(response_text, response_language)
                logger.info("turn.metric stage=tts_done ms=%.0f", self._elapsed_ms(started_at))
                logger.info("tts.done bytes=%s", len(audio))
                if audio:
                    await self._send_audio_chunks(audio, request_id)
                await self.send_event("tts.done", bytes=len(audio), request_id=request_id)
        except Exception as exc:
            logger.exception("tts failed")
            await self.try_send_event("error", message=str(exc), request_id=request_id)
            await self.try_send_event("tts.done", bytes=0, request_id=request_id)

    async def _stream_local_tts(
        self,
        response_text: str,
        response_language: str | None,
        request_id: str | None,
        started_at: float,
    ) -> bool:
        """Stream local TTS PCM16 parts to the client as they are synthesized.

        Returns True if any audio was streamed; False means nothing was sent yet
        and the caller should fall back to buffered synthesis. Failures after the
        first chunk are re-raised (partial audio already reached the client).
        """
        chunk_size = max(4096, self.provider.settings.audio_chunk_bytes)
        sample_rate = int(self.provider.settings.output_sample_rate)
        buffer = bytearray()
        started = False
        first_logged = False
        total = 0

        async def flush(force: bool) -> None:
            nonlocal started, first_logged, total
            while len(buffer) >= chunk_size or (force and buffer):
                payload = bytes(buffer[:chunk_size])
                del buffer[:chunk_size]
                if not started:
                    started = True
                    await self.send_event(
                        "audio.output.start",
                        bytes=0,
                        chunk_bytes=chunk_size,
                        sample_rate=sample_rate,
                        encoding="pcm16",
                        streaming=True,
                        request_id=request_id,
                    )
                if not first_logged:
                    first_logged = True
                    logger.info("turn.metric stage=first_audio_chunk ms=%.0f", self._elapsed_ms(started_at))
                total += len(payload)
                await self._send_binary(payload)

        async def on_chunk(chunk: bytes) -> None:
            buffer.extend(chunk)
            await flush(False)

        try:
            await self.provider.synthesize_stream(response_text, response_language, on_chunk)
        except Exception as exc:
            if started:
                raise
            logger.warning("tts stream unavailable, falling back to buffered synthesis: %s", exc)
            return False
        await flush(True)
        if not started:
            return False
        logger.info("turn.metric stage=tts_done ms=%.0f", self._elapsed_ms(started_at))
        logger.info("tts.done bytes=%s streamed=1", total)
        await self.send_event("audio.output.done", bytes=total, request_id=request_id)
        await self.send_event("tts.done", bytes=total, request_id=request_id)
        return True

    async def _generate_response_text(
        self,
        user_text: str,
        image_jpeg_base64: str | None = None,
        response_language: str | None = None,
    ) -> str:
        if image_jpeg_base64:
            return await self.provider.chat(user_text, self.state.scene, image_jpeg_base64, response_language)

        if not self.provider.settings.vision_agent_enabled:
            return await self.provider.chat(user_text, self.state.scene, response_language=response_language)

        decision = await self.provider.decide_vision(user_text, self.state.scene)
        await self.send_event(
            "vision.decision",
            needs_snapshot=decision.needs_snapshot,
            reason=decision.reason,
        )
        logger.info(
            "vision.decision needs_snapshot=%s reason=%r",
            decision.needs_snapshot,
            decision.reason,
        )

        if not decision.needs_snapshot:
            return await self.provider.chat(user_text, self.state.scene, response_language=response_language)

        return await self._answer_with_snapshot(user_text, decision, response_language)

    def _normalize_transcription(self, value: object) -> TranscriptionResult:
        if isinstance(value, TranscriptionResult):
            return value
        if isinstance(value, dict):
            return TranscriptionResult(
                text=str(value.get("text") or value.get("transcript") or value.get("result") or ""),
                language=str(value.get("language") or value.get("lang") or value.get("detected_language") or "") or None,
            )
        return TranscriptionResult(text=str(value or ""))

    async def _answer_with_snapshot(
        self,
        user_text: str,
        decision: VisionDecision,
        response_language: str | None = None,
    ) -> str:
        snapshot_prompt = "Capture the current Quest camera view for the user's original request."
        active_request_id = ""

        async def request_current_view(prompt: str) -> dict:
            nonlocal active_request_id
            active_request_id = f"auto_{uuid.uuid4().hex}"
            await self.send_event("vision.start", request_id=active_request_id, reason=decision.reason)
            snapshot = await self.request_snapshot(
                active_request_id,
                prompt,
                self.provider.settings.vision_snapshot_timeout_seconds,
            )
            return {
                "request_id": active_request_id,
                "prompt": prompt,
                "image_jpeg_base64": str(snapshot.get("image_jpeg_base64") or ""),
                "metadata": dict(snapshot.get("metadata") or {}),
            }

        seeing_tool = create_get_what_user_is_seeing_tool(request_current_view)

        try:
            logger.info("agent.tool.invoke name=%s", seeing_tool.name)
            snapshot = await seeing_tool.ainvoke({"prompt": snapshot_prompt})
        except Exception as exc:
            logger.exception("vision snapshot request failed")
            await self.try_send_event("vision.error", request_id=active_request_id, message=str(exc))
            return await self.provider.chat(
                (
                    f"{user_text}\n\n"
                    "Technical note: the system tried to request a Quest camera snapshot, "
                    f"but the request failed: {exc}. "
                    "Answer the original user request without pretending to see the environment."
                ),
                self.state.scene,
                response_language=response_language,
            )

        image = str(snapshot.get("image_jpeg_base64") or "")
        if not image:
            await self.try_send_event(
                "vision.error",
                request_id=str(snapshot.get("request_id") or active_request_id),
                message="Quest snapshot was empty.",
            )
            return await self.provider.chat(
                (
                    f"{user_text}\n\n"
                    "Technical note: the Quest camera returned an empty snapshot. "
                    "Answer the original user request without pretending to see the environment."
                ),
                self.state.scene,
                response_language=response_language,
            )

        snapshot_scene = self._scene_from_snapshot(snapshot)
        request_id = str(snapshot.get("request_id") or active_request_id)
        await self.send_event(
            "vision.ready",
            request_id=request_id,
            image_base64_chars=len(image),
            metadata_keys=sorted(snapshot_scene.metadata.keys()),
        )
        logger.info("vision.ready request_id=%s image_base64_chars=%s", request_id, len(image))
        return await self.provider.chat(user_text, snapshot_scene, image, response_language)

    def _scene_from_snapshot(self, snapshot: dict) -> SceneState:
        metadata = dict(snapshot.get("metadata") or {})
        if not metadata:
            return self.state.scene

        objects_value = metadata.get("objects")
        objects = objects_value if isinstance(objects_value, list) else self.state.scene.objects
        return SceneState(
            objects=[str(item) for item in objects],
            gaze_target=str(metadata.get("selected_object_id") or self.state.scene.gaze_target or "") or None,
            active_demo=str(metadata.get("active_demo_id") or self.state.scene.active_demo or "") or None,
            metadata=metadata,
        )

    async def _send_audio_chunks(self, audio: bytes, request_id: str | None = None, sample_rate: int | None = None) -> None:
        chunk_size = max(4096, self.provider.settings.audio_chunk_bytes)
        audio_sample_rate = sample_rate or self.provider.settings.output_sample_rate
        cues = []
        if self.state.scene.metadata.get("avatar") in ("noibot", "milo"):
            cues = await mouth_cues(audio, audio_sample_rate, self.provider.settings)
        await self.send_event(
            "audio.output.start",
            bytes=len(audio),
            chunk_bytes=chunk_size,
            sample_rate=audio_sample_rate,
            encoding="wav",
            mouth_cues=cues,
            request_id=request_id,
        )
        for offset in range(0, len(audio), chunk_size):
            await self._send_binary(audio[offset : offset + chunk_size])
        await self.send_event("audio.output.done", bytes=len(audio), request_id=request_id)

    async def _send_binary(self, payload: bytes) -> None:
        async with self.send_lock:
            await self.websocket.send_bytes(payload)

    def _elapsed_ms(self, started_at: float) -> float:
        return (perf_counter() - started_at) * 1000.0

    def _video_stream_enabled(self) -> bool:
        return bool(getattr(self.provider.settings, "google_video_stream_enabled", False))

    def _fresh_latest_video_frame(self) -> dict | None:
        if not self._video_stream_enabled() or self.latest_video_frame is None:
            return None
        max_age = float(getattr(self.provider.settings, "google_video_max_frame_age_seconds", 2.5))
        if perf_counter() - self.latest_video_frame_at > max_age:
            return None
        return self.latest_video_frame

    async def _wait_for_video_frame(self, timeout_seconds: float) -> dict | None:
        if not self._video_stream_enabled():
            return None
        try:
            return await asyncio.wait_for(self.video_frame_queue.get(), timeout=timeout_seconds)
        except asyncio.TimeoutError:
            return None

    async def request_snapshot(self, request_id: str, prompt: str, timeout_seconds: float) -> dict:
        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict] = loop.create_future()
        self.pending_snapshots[request_id] = future

        try:
            await self.send_event(
                "vision.snapshot.request",
                request_id=request_id,
                prompt=prompt,
                timeout_seconds=timeout_seconds,
            )
            return await asyncio.wait_for(future, timeout=timeout_seconds)
        finally:
            self.pending_snapshots.pop(request_id, None)
