import json

import httpx

from xr_agent_proxy.audio import float32_pcm_to_wav_bytes
from xr_agent_proxy.config import Settings
from xr_agent_proxy.models import SceneState, TranscriptionResult, VisionDecision


class LocalProvider:
    supports_tts_stream = True

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.timeout = httpx.Timeout(settings.request_timeout_seconds)
        self.client = httpx.AsyncClient(timeout=self.timeout, verify=settings.local_tls_verify)

    async def health(self) -> dict:
        services = {
            "stt": await self._endpoint_health(self.settings.stt_health_url),
            "llm": await self._endpoint_health(self.settings.llm_health_url),
            "tts": await self._endpoint_health(self.settings.tts_health_url),
        }
        return {
            "provider": "local",
            "stt_url": self.settings.stt_url,
            "llm_url": self.settings.llm_url,
            "tts_url": self.settings.tts_url,
            "services": services,
            "ready": all(service["ok"] for service in services.values()),
            "vision_agent_enabled": self.settings.vision_agent_enabled,
            "vision_snapshot_timeout_seconds": self.settings.vision_snapshot_timeout_seconds,
        }

    async def transcribe_float32(self, pcm_bytes: bytes, sample_rate: int) -> TranscriptionResult:
        wav_bytes = float32_pcm_to_wav_bytes(pcm_bytes, sample_rate)
        if not wav_bytes:
            return TranscriptionResult()

        files = {
            "file": ("quest_audio.wav", wav_bytes, "audio/wav"),
        }
        data = {
            "sample_rate": str(sample_rate),
        }
        stt_language = self.settings.stt_language.strip()
        if stt_language and stt_language.lower() != "auto":
            data["language"] = stt_language
        try:
            response = await self.client.post(self.settings.stt_url, files=files, data=data)
            response.raise_for_status()
        except httpx.RequestError as exc:
            raise RuntimeError(f"Local STT unavailable at {self.settings.stt_url}: {exc}") from exc
        except httpx.HTTPStatusError as exc:
            raise RuntimeError(f"Local STT returned HTTP {exc.response.status_code}: {exc.response.text[:200]}") from exc

        payload = response.json()
        return TranscriptionResult(
            text=str(payload.get("text") or payload.get("transcript") or payload.get("result") or ""),
            language=self._normalize_language(payload.get("language") or payload.get("lang") or payload.get("detected_language")),
        )

    async def decide_vision(self, user_text: str, scene: SceneState) -> VisionDecision:
        if not self.settings.vision_agent_enabled:
            return VisionDecision()

        scene_context = scene.model_dump()
        body = {
            "model": self.settings.llm_model,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "You are the tool planner for an XR assistant. "
                        "Decide whether answering requires one fresh real-world image from the Quest headset camera. "
                        "Reply with exactly one line of valid JSON, with no markdown: "
                        '{"needs_snapshot":true|false,"snapshot_prompt":"...","reason":"..."} '
                        "reason must be at most 12 words. "
                        "Use needs_snapshot=true when the answer depends on what the user currently sees, "
                        "reading real-world text/objects, or describing the physical environment. "
                        "If the user asks what they are looking at/seeing and the context does not already answer it, "
                        "needs_snapshot must be true. "
                        "Use needs_snapshot=false for greetings, generic questions, known scene data, "
                        "date/time, or virtual objects already present in context. "
                        "When a snapshot is needed, snapshot_prompt must ask the vision model to answer in the user's language. "
                        'True example: {"needs_snapshot":true,"snapshot_prompt":"Describe what the user sees and answer in the user language.","reason":"Needs current image"} '
                        'False example: {"needs_snapshot":false,"snapshot_prompt":"","reason":"Text context is enough"}'
                    ),
                },
                {
                    "role": "user",
                    "content": (
                        f"Domanda utente: {user_text}\n\n"
                        f"Contesto XR disponibile: {scene_context}\n\n"
                        "If a snapshot is needed, snapshot_prompt must ask the vision model to answer "
                        "the user question in the same language as the user, using the image and XR context."
                    ),
                },
            ],
            "temperature": 0.0,
            "max_tokens": self.settings.vision_decision_max_tokens,
        }
        payload = await self._post_llm(body)
        content = self._extract_message_content(payload)
        return self._parse_vision_decision(content, user_text)

    async def chat(
        self,
        user_text: str,
        scene: SceneState,
        image_jpeg_base64: str | None = None,
        response_language: str | None = None,
    ) -> str:
        content: str | list[dict]
        scene_context = scene.model_dump()
        language_instruction = self._language_instruction(response_language)

        if image_jpeg_base64:
            content = [
                {
                    "type": "text",
                    "text": f"{language_instruction}\n\nUser request:\n{user_text}\n\nScene context: {scene_context}",
                },
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/jpeg;base64,{image_jpeg_base64}",
                    },
                },
            ]
        else:
            content = f"{language_instruction}\n\nUser request:\n{user_text}\n\nScene context: {scene_context}"

        body = {
            "model": self.settings.llm_model,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "You are the assistant for the XR NOI Techpark project demos. "
                        "The language rule below is mandatory and overrides the language of this system prompt, "
                        "the XR context, object names, and any internal notes. "
                        "Help the user understand demos, objects, data, and the XR environment. "
                        "Use a clear, competent, concrete, slightly energetic tone. "
                        "Because this is a voice assistant in XR, always reply in 1 or 2 short spoken sentences "
                        "and never exceed about 40 words. "
                        "Avoid markdown, introductions, final summaries, and lists unless explicitly requested. "
                        "Do not add unsolicited examples, follow-up offers, or suggestions after the answer. "
                        "If the user asks for a long explanation, ask whether they want to go deeper. "
                        "Use scene context only when useful and do not mention it as a technical detail. "
                        "For selected products, use the supplied catalog facts and distinguish declared dimensions from model bounds. "
                        "For environmental data, report only supplied measurements with their timestamp; never invent missing readings or call unavailable readings live. "
                        "Respect the stated source and scope: an XR reconstruction is not an official BIM or manufacturer model unless explicitly identified as such. "
                        "If you receive an image, describe what is visible and answer the user's question. "
                        "Do not mention date or time unless the user explicitly asks. "
                        "If the user asks for date or time, use runtime_time from scene context. "
                        "Do not offer to translate or switch languages unless the user explicitly asks for that. "
                        "Be natural and get straight to the point. "
                        f"{language_instruction}"
                    ),
                },
                {
                    "role": "user",
                    "content": content,
                },
            ],
            "temperature": 0.4,
        }
        if self.settings.llm_max_tokens > 0:
            body["max_tokens"] = self.settings.llm_max_tokens
        payload = await self._post_llm(body)
        return self._clip_for_voice(self._extract_message_content(payload))

    async def synthesize(self, text: str, language: str | None = None) -> bytes:
        if not text.strip():
            return b""

        tts_language = self._normalize_language(language) or self._normalize_language(self.settings.tts_default_language) or "it"
        body = {
            "input": text,
            "voice": self._voice_for_language(tts_language),
            "language": tts_language,
            "format": self.settings.tts_response_format,
            "response_format": self.settings.tts_response_format,
            "sample_rate": self.settings.output_sample_rate,
        }
        try:
            response = await self.client.post(self.settings.tts_url, json=body)
            response.raise_for_status()
        except httpx.RequestError as exc:
            raise RuntimeError(f"Local TTS unavailable at {self.settings.tts_url}: {exc}") from exc
        except httpx.HTTPStatusError as exc:
            raise RuntimeError(f"Local TTS returned HTTP {exc.response.status_code}: {exc.response.text[:200]}") from exc
        return response.content

    async def synthesize_stream(self, text: str, language: str | None, on_chunk) -> int:
        """POST with stream=true; call on_chunk(bytes) as PCM16 parts arrive. Return total bytes."""
        if not text.strip():
            return 0

        tts_language = self._normalize_language(language) or self._normalize_language(self.settings.tts_default_language) or "it"
        body = {
            "input": text,
            "voice": self._voice_for_language(tts_language),
            "language": tts_language,
            "format": "pcm16",
            "response_format": "pcm16",
            "sample_rate": self.settings.output_sample_rate,
            "stream": True,
        }
        total = 0
        try:
            async with self.client.stream("POST", self.settings.tts_url, json=body) as response:
                if response.status_code != 200:
                    detail = (await response.aread())[:200].decode("utf-8", errors="replace")
                    raise RuntimeError(f"Local TTS returned HTTP {response.status_code}: {detail}")
                async for chunk in response.aiter_bytes():
                    if not chunk:
                        continue
                    total += len(chunk)
                    await on_chunk(chunk)
        except httpx.RequestError as exc:
            raise RuntimeError(f"Local TTS unavailable at {self.settings.tts_url}: {exc}") from exc
        return total

    async def close(self) -> None:
        await self.client.aclose()

    def _clip_for_voice(self, text: str) -> str:
        clean_text = " ".join(text.split())
        clean_text = clean_text.replace("**", "").replace("__", "").replace("`", "").replace("*", "")
        if self.settings.response_max_chars <= 0:
            return clean_text
        if len(clean_text) <= self.settings.response_max_chars:
            return clean_text

        clipped = clean_text[: self.settings.response_max_chars].rsplit(" ", 1)[0].strip()
        sentence_end = max(clipped.rfind("."), clipped.rfind("!"), clipped.rfind("?"))
        if sentence_end >= 80:
            clipped = clipped[: sentence_end + 1]
        return clipped.rstrip(" ,;:") + "."

    async def _post_llm(self, body: dict) -> dict:
        if self.settings.llm_enable_thinking is not None:
            body = {**body, "chat_template_kwargs": {"enable_thinking": self.settings.llm_enable_thinking}}
        try:
            response = await self.client.post(self.settings.llm_url, json=body)
            response.raise_for_status()
        except httpx.TimeoutException as exc:
            raise RuntimeError("Il modello AI locale non ha risposto in tempo. Riprova quando il server è disponibile.") from exc
        except httpx.RequestError as exc:
            raise RuntimeError(f"Local LLM unavailable at {self.settings.llm_url}: {exc}") from exc
        except httpx.HTTPStatusError as exc:
            raise RuntimeError(f"Local LLM returned HTTP {exc.response.status_code}: {exc.response.text[:200]}") from exc
        return response.json()

    async def _endpoint_health(self, url: str) -> dict:
        if not url.strip():
            return {"ok": True, "url": "", "status_code": None}

        try:
            response = await self.client.get(url, timeout=self.settings.health_timeout_seconds)
            return {
                "ok": 200 <= response.status_code < 300,
                "url": url,
                "status_code": response.status_code,
            }
        except httpx.RequestError as exc:
            return {
                "ok": False,
                "url": url,
                "status_code": None,
                "error": str(exc),
            }

    def _extract_message_content(self, payload: dict) -> str:
        choices = payload.get("choices") or []
        if not choices:
            return ""
        message = choices[0].get("message") or {}
        content = message.get("content") or ""
        if isinstance(content, list):
            parts: list[str] = []
            for item in content:
                if isinstance(item, dict):
                    parts.append(str(item.get("text") or ""))
            return "".join(parts)
        return str(content)

    def _parse_vision_decision(self, content: str, user_text: str) -> VisionDecision:
        data = self._extract_json_object(content)
        if not data:
            return VisionDecision(reason="vision planner returned invalid JSON")

        raw_needs_snapshot = data.get("needs_snapshot", False)
        needs_snapshot = self._parse_bool(raw_needs_snapshot)
        snapshot_prompt = str(data.get("snapshot_prompt") or "").strip()
        if needs_snapshot and not snapshot_prompt:
            snapshot_prompt = (
                "Use this Quest image and XR context to answer the user's original question."
            )
        return VisionDecision(
            needs_snapshot=needs_snapshot,
            snapshot_prompt=snapshot_prompt,
            reason=str(data.get("reason") or "").strip(),
        )

    def _extract_json_object(self, content: str) -> dict:
        text = content.strip()
        if text.startswith("```"):
            text = text.strip("`").strip()
            if text.lower().startswith("json"):
                text = text[4:].strip()

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

    def _parse_bool(self, value: object) -> bool:
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            return value.strip().lower() in {"true", "1", "yes", "si", "sì"}
        if isinstance(value, int | float):
            return value != 0
        return False

    def _normalize_language(self, value: object) -> str | None:
        language = str(value or "").strip().lower().replace("_", "-")
        if not language or language == "auto":
            return None
        return language.split("-", 1)[0]

    def _voice_for_language(self, language: str) -> str:
        voices = self._parse_voice_map(self.settings.tts_voice_map)
        return voices.get(language, self.settings.tts_voice)

    def _language_instruction(self, language: str | None) -> str:
        normalized = self._normalize_language(language)
        if normalized is None:
            return (
                "LANGUAGE RULE: Reply in the same language as the user's request. "
                "Do not offer translation or language switching unless the user explicitly asks."
            )

        language_names = {
            "it": "Italian",
            "en": "English",
            "de": "German",
            "fr": "French",
            "es": "Spanish",
            "pt": "Portuguese",
            "nl": "Dutch",
        }
        language_name = language_names.get(normalized, normalized)
        return (
            f"LANGUAGE RULE: The speech transcription detected {language_name} ({normalized}). "
            f"Reply ONLY in {language_name}. "
            "Do not offer translation or language switching unless the user explicitly asks. "
            "Do not mention this language rule. "
            f"If scene context, object names, or previous instructions use another language, still answer in {language_name}."
        )

    def _parse_voice_map(self, raw_map: str) -> dict[str, str]:
        raw_map = raw_map.strip()
        if not raw_map:
            return {}

        try:
            parsed = json.loads(raw_map)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict):
            return {
                str(key).strip().lower().split("-", 1)[0]: str(value).strip()
                for key, value in parsed.items()
                if str(key).strip() and str(value).strip()
            }

        voices: dict[str, str] = {}
        for item in raw_map.replace(";", ",").split(","):
            if "=" not in item:
                continue
            key, value = item.split("=", 1)
            language = self._normalize_language(key)
            voice = value.strip()
            if language and voice:
                voices[language] = voice
        return voices
