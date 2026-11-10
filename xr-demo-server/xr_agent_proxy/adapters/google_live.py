import asyncio
import base64
import json
import logging
from contextlib import suppress
from collections.abc import Awaitable, Callable
from typing import Any

from google import genai
from google.genai import types

from xr_agent_proxy.audio import float32_pcm_to_pcm16_bytes
from xr_agent_proxy.config import Settings
from xr_agent_proxy.models import ProviderTurnResult, SceneState, VisionDecision

logger = logging.getLogger("uvicorn.error")

SnapshotRequester = Callable[[str, float], Awaitable[dict]]
EventSender = Callable[[str, Any], Awaitable[bool]]
AudioChunkSender = Callable[[bytes, int], Awaitable[None]]
VideoFrameSource = Callable[[float], Awaitable[dict | None]]


class GoogleLiveProvider:
    supports_audio_turn = True

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.client: genai.Client | None = None

    async def health(self) -> dict:
        return {
            "provider": self.settings.agent_provider,
            "mode": "google-live-speech-to-speech",
            "live_model": self.settings.google_live_model,
            "text_model": self.settings.google_text_model,
            "location": self.settings.google_location,
            "use_vertexai": self.settings.google_use_vertexai,
            "voice": self.settings.google_voice_name,
            "language_code": self.settings.google_language_code,
            "input_sample_rate": self.settings.google_input_sample_rate,
            "output_sample_rate": self.settings.google_output_sample_rate,
            "snapshot_tool_enabled": self.settings.google_snapshot_tool_enabled,
            "video_stream_enabled": self.settings.google_video_stream_enabled,
            "configured": bool(self.settings.google_api_key or self.settings.google_use_vertexai),
        }

    async def generate_audio_turn(
        self,
        pcm_bytes: bytes,
        sample_rate: int,
        scene: SceneState,
        request_snapshot: SnapshotRequester,
        send_event: EventSender,
        send_audio_chunk: AudioChunkSender | None = None,
        initial_video_frame: dict | None = None,
        next_video_frame: VideoFrameSource | None = None,
    ) -> ProviderTurnResult:
        google_pcm = float32_pcm_to_pcm16_bytes(
            pcm_bytes,
            source_sample_rate=sample_rate,
            target_sample_rate=self.settings.google_input_sample_rate,
        )
        if not google_pcm:
            return ProviderTurnResult(output_sample_rate=self.settings.google_output_sample_rate)

        audio_output = bytearray()
        input_transcript_parts: list[str] = []
        output_transcript_parts: list[str] = []
        config = self._live_config(scene, enable_tools=True)

        async with asyncio.timeout(self.settings.google_turn_timeout_seconds):
            async with self._client().aio.live.connect(model=self.settings.google_live_model, config=config) as session:
                video_task: asyncio.Task | None = None
                if self.settings.google_video_stream_enabled:
                    if initial_video_frame is not None:
                        await self._send_video_frame(session, initial_video_frame)
                    if next_video_frame is not None:
                        video_task = asyncio.create_task(self._pump_video_frames(session, next_video_frame))

                await self._send_audio_turn(session, google_pcm)

                try:
                    async for response in session.receive():
                        server_content = response.server_content
                        if server_content is not None:
                            await self._collect_server_content(
                                server_content,
                                audio_output,
                                input_transcript_parts,
                                output_transcript_parts,
                                send_event,
                                send_audio_chunk,
                            )
                            if server_content.turn_complete:
                                break

                        tool_call = response.tool_call
                        if tool_call is not None:
                            await self._handle_tool_call(tool_call, session, request_snapshot, send_event)
                finally:
                    if video_task is not None:
                        video_task.cancel()
                        with suppress(asyncio.CancelledError):
                            await video_task

        response_text = self._clean_text("".join(output_transcript_parts))
        transcript = self._clean_text("".join(input_transcript_parts))
        return ProviderTurnResult(
            transcript=transcript,
            response_text=response_text,
            audio=bytes(audio_output),
            output_sample_rate=self.settings.google_output_sample_rate,
        )

    async def transcribe_float32(self, pcm_bytes: bytes, sample_rate: int) -> str:
        result = await self.generate_audio_turn(
            pcm_bytes,
            sample_rate,
            SceneState(),
            self._empty_snapshot_requester,
            self._ignore_event,
        )
        return result.transcript

    async def decide_vision(self, user_text: str, scene: SceneState) -> VisionDecision:
        if not self.settings.vision_agent_enabled:
            return VisionDecision()

        prompt = (
            "Decidi se per rispondere serve una nuova immagine reale dalla camera del visore Quest. "
            "Rispondi solo JSON valido: "
            '{"needs_snapshot":true|false,"snapshot_prompt":"...","reason":"..."}\n\n'
            f"Domanda utente: {user_text}\n"
            f"Contesto XR: {scene.model_dump()}"
        )
        text = await self._generate_text(
            prompt,
            system_instruction=(
                "Sei un planner strumenti per un assistente XR. "
                "Usa needs_snapshot=true solo quando serve vedere l'ambiente fisico corrente."
            ),
            max_tokens=self.settings.vision_decision_max_tokens,
        )
        return self._parse_vision_decision(text, user_text)

    async def chat(
        self,
        user_text: str,
        scene: SceneState,
        image_jpeg_base64: str | None = None,
        response_language: str | None = None,
    ) -> str:
        contents: list[Any] = [
            f"{user_text}\n\nScene context: {scene.model_dump()}",
        ]
        if image_jpeg_base64:
            contents.append(types.Part(inlineData=types.Blob(data=base64.b64decode(image_jpeg_base64), mimeType="image/jpeg")))

        text = await self._generate_text(
            contents,
            system_instruction=self._system_instruction(scene),
            max_tokens=self.settings.llm_max_tokens if self.settings.llm_max_tokens > 0 else None,
        )
        return self._clip_for_voice(text)

    async def synthesize(self, text: str, _language: str | None = None) -> bytes:
        result = await self._run_text_audio_turn(text)
        return result.audio

    def _create_client(self) -> genai.Client:
        http_options = {"api_version": self.settings.google_api_version}
        if self.settings.google_use_vertexai:
            return genai.Client(
                vertexai=True,
                project=self.settings.google_project_id or None,
                location=self.settings.google_location or None,
                http_options=http_options,
            )
        if self.settings.google_api_key:
            return genai.Client(api_key=self.settings.google_api_key, http_options=http_options)
        return genai.Client(http_options=http_options)

    def _live_config(self, scene: SceneState, enable_tools: bool) -> types.LiveConnectConfig:
        tools: list[types.Tool] | None = None
        if enable_tools and self.settings.google_snapshot_tool_enabled:
            tools = [self._snapshot_tool()]

        return types.LiveConnectConfig(
            responseModalities=[types.Modality.AUDIO],
            temperature=self.settings.google_temperature,
            speechConfig=types.SpeechConfig(
                languageCode=self.settings.google_language_code,
                voiceConfig=types.VoiceConfig(
                    prebuiltVoiceConfig=types.PrebuiltVoiceConfig(
                        voiceName=self.settings.google_voice_name,
                    )
                ),
            ),
            systemInstruction=self._system_instruction(scene),
            inputAudioTranscription=types.AudioTranscriptionConfig(),
            outputAudioTranscription=types.AudioTranscriptionConfig(),
            realtimeInputConfig=types.RealtimeInputConfig(
                activityHandling=types.ActivityHandling.START_OF_ACTIVITY_INTERRUPTS,
                turnCoverage=types.TurnCoverage.TURN_INCLUDES_ONLY_ACTIVITY,
            ),
            tools=tools,
        )

    def _snapshot_tool(self) -> types.Tool:
        return types.Tool(
            functionDeclarations=[
                types.FunctionDeclaration(
                    name="get_what_user_is_seeing",
                    description=(
                        "Capture exactly one current Quest camera snapshot when the user asks what they see, "
                        "asks about visible real-world objects or text, or when the answer depends on the "
                        "physical room around the headset. Use this instead of guessing."
                    ),
                    parametersJsonSchema={
                        "type": "object",
                        "properties": {
                            "prompt": {
                                "type": "string",
                                "description": "Short instruction for what to inspect in the snapshot.",
                            }
                        },
                        "required": ["prompt"],
                    },
                )
            ]
        )

    async def _send_audio_turn(self, session: Any, google_pcm: bytes) -> None:
        chunk_size = max(640, self.settings.google_audio_chunk_bytes)
        for offset in range(0, len(google_pcm), chunk_size):
            await session.send_realtime_input(
                audio=types.Blob(
                    data=google_pcm[offset : offset + chunk_size],
                    mimeType=f"audio/pcm;rate={self.settings.google_input_sample_rate}",
                )
            )
        await session.send_realtime_input(audio_stream_end=True)

    async def _send_video_frame(self, session: Any, frame: dict) -> None:
        image = str(frame.get("image_jpeg_base64") or "")
        if image.strip() == "":
            return
        await session.send_realtime_input(
            video=types.Blob(
                data=base64.b64decode(image),
                mimeType="image/jpeg",
            )
        )

    async def _pump_video_frames(self, session: Any, next_video_frame: VideoFrameSource) -> None:
        while True:
            frame = await next_video_frame(1.0)
            if frame is None:
                continue
            await self._send_video_frame(session, frame)

    async def _collect_server_content(
        self,
        server_content: Any,
        audio_output: bytearray,
        input_transcript_parts: list[str],
        output_transcript_parts: list[str],
        send_event: EventSender,
        send_audio_chunk: AudioChunkSender | None = None,
    ) -> None:
        if server_content.model_turn:
            for part in server_content.model_turn.parts:
                inline_data = part.inline_data
                if inline_data and isinstance(inline_data.data, bytes):
                    chunk = inline_data.data
                    audio_output.extend(chunk)
                    if send_audio_chunk is not None:
                        await send_audio_chunk(chunk, self.settings.google_output_sample_rate)

        if server_content.input_transcription and server_content.input_transcription.text:
            input_transcript_parts.append(server_content.input_transcription.text)

        if server_content.output_transcription and server_content.output_transcription.text:
            delta_text = server_content.output_transcription.text
            output_transcript_parts.append(delta_text)
            await send_event(
                "llm.delta",
                delta=delta_text,
                text=self._clean_text("".join(output_transcript_parts)),
            )

        if server_content.interrupted:
            await send_event("interrupted")

    async def _handle_tool_call(
        self,
        tool_call: Any,
        session: Any,
        request_snapshot: SnapshotRequester,
        send_event: EventSender,
    ) -> None:
        function_responses: list[types.FunctionResponse] = []
        for function_call in tool_call.function_calls:
            function_name = str(function_call.name or "")
            if function_name != "get_what_user_is_seeing":
                function_responses.append(
                    types.FunctionResponse(
                        id=function_call.id,
                        name=function_name,
                        response={"error": f"Unsupported tool: {function_name}"},
                    )
                )
                continue

            args = dict(function_call.args or {})
            prompt = str(args.get("prompt") or "Describe what the user sees and answer in the user's language.")
            try:
                snapshot = await request_snapshot(prompt, self.settings.vision_snapshot_timeout_seconds)
                image = str(snapshot.get("image_jpeg_base64") or "")
                metadata = dict(snapshot.get("metadata") or {})
                if image:
                    await session.send_realtime_input(
                        video=types.Blob(
                            data=base64.b64decode(image),
                            mimeType="image/jpeg",
                        )
                    )
                function_responses.append(
                    types.FunctionResponse(
                        id=function_call.id,
                        name=function_name,
                        response={
                            "snapshot_sent": bool(image),
                            "metadata": metadata,
                            "prompt": prompt,
                            "instruction": "Use the image sent as realtime input to answer in the user's language.",
                        },
                    )
                )
                await send_event("vision.ready", request_id=str(snapshot.get("request_id") or ""), metadata_keys=sorted(metadata.keys()))
            except Exception as exc:
                logger.exception("google live snapshot tool failed")
                function_responses.append(
                    types.FunctionResponse(
                        id=function_call.id,
                        name=function_name,
                        response={"error": str(exc)},
                    )
                )
                await send_event("vision.error", message=str(exc))

        if function_responses:
            await session.send_tool_response(function_responses=function_responses)

    async def _run_text_audio_turn(self, text: str) -> ProviderTurnResult:
        audio_output = bytearray()
        output_text_parts: list[str] = []
        async with asyncio.timeout(self.settings.google_turn_timeout_seconds):
            async with self._client().aio.live.connect(model=self.settings.google_live_model, config=self._live_config(SceneState(), enable_tools=False)) as session:
                await session.send_client_content(turns=types.Content(role="user", parts=[types.Part(text=text)]), turn_complete=True)
                async for response in session.receive():
                    server_content = response.server_content
                    if server_content is None:
                        continue
                    await self._collect_server_content(server_content, audio_output, [], output_text_parts, self._ignore_event)
                    if server_content.turn_complete:
                        break

        return ProviderTurnResult(
            response_text=self._clean_text("".join(output_text_parts)),
            audio=bytes(audio_output),
            output_sample_rate=self.settings.google_output_sample_rate,
        )

    async def _generate_text(self, contents: Any, system_instruction: str, max_tokens: int | None = None) -> str:
        config = types.GenerateContentConfig(
            systemInstruction=system_instruction,
            temperature=self.settings.google_temperature,
            maxOutputTokens=max_tokens,
        )
        response = await self._client().aio.models.generate_content(
            model=self.settings.google_text_model,
            contents=contents,
            config=config,
        )
        return self._clean_text(response.text or "")

    def _client(self) -> genai.Client:
        if self.client is None:
            self.client = self._create_client()
        return self.client

    def _system_instruction(self, scene: SceneState) -> str:
        if self.settings.google_system_instruction.strip():
            return self.settings.google_system_instruction.strip()

        return (
            "You are the official XR assistant for NOI Techpark. "
            "Reply in the user's language when it is detectable from speech or text. "
            "Do not offer translation or language switching unless explicitly requested. "
            "Use a clear, competent, concrete, slightly energetic tone. "
            "You are inside an XR demo with scene context available; use it only when useful. "
            "Usually reply in 1 or 2 compact sentences suitable for voice. "
            "Avoid long lists and long explanations unless explicitly requested. "
            "If you need to inspect the current physical environment, use the get_what_user_is_seeing tool. "
            "Do not pretend to see the room unless you received a snapshot. "
            "If you receive an image, describe what is visible and answer directly. "
            "Do not mention date or time unless explicitly asked. "
            f"Current XR context: {scene.model_dump()}"
        )

    def _clip_for_voice(self, text: str) -> str:
        clean_text = self._clean_text(text)
        if self.settings.response_max_chars <= 0 or len(clean_text) <= self.settings.response_max_chars:
            return clean_text

        clipped = clean_text[: self.settings.response_max_chars].rsplit(" ", 1)[0].strip()
        sentence_end = max(clipped.rfind("."), clipped.rfind("!"), clipped.rfind("?"))
        if sentence_end >= 80:
            clipped = clipped[: sentence_end + 1]
        return clipped.rstrip(" ,;:") + "."

    def _parse_vision_decision(self, content: str, user_text: str) -> VisionDecision:
        data = self._extract_json_object(content)
        if not data:
            return VisionDecision(reason="vision planner returned invalid JSON")
        needs_snapshot = bool(data.get("needs_snapshot", False))
        snapshot_prompt = str(data.get("snapshot_prompt") or "").strip()
        if needs_snapshot and not snapshot_prompt:
            snapshot_prompt = f"Answer the user's question in their language using this Quest image: {user_text}"
        return VisionDecision(
            needs_snapshot=needs_snapshot,
            snapshot_prompt=snapshot_prompt,
            reason=str(data.get("reason") or "").strip(),
        )

    def _extract_json_object(self, content: str) -> dict:
        text = content.strip()
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            start = text.find("{")
            end = text.rfind("}")
            if start < 0 or end <= start:
                return {}
            try:
                parsed = json.loads(text[start : end + 1])
            except json.JSONDecodeError:
                return {}
        return parsed if isinstance(parsed, dict) else {}

    def _clean_text(self, text: str) -> str:
        return " ".join(text.split())

    async def _empty_snapshot_requester(self, _prompt: str, _timeout_seconds: float) -> dict:
        return {}

    async def _ignore_event(self, _event_type: str, **_payload: Any) -> bool:
        return True
