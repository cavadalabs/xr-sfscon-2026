import json

import httpx

from xr_agent_proxy.adapters.local import LocalProvider
from xr_agent_proxy.config import Settings
from xr_agent_proxy.models import SceneState


def test_local_provider_passes_whisper_language_to_tts() -> None:
    requests: list[httpx.Request] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if str(request.url).endswith("/transcribe"):
            return httpx.Response(200, json={"text": "hello", "language": "en"})
        if str(request.url).endswith("/speech"):
            body = json.loads(request.content.decode("utf-8"))
            assert body["language"] == "en"
            assert body["response_format"] == "pcm16"
            return httpx.Response(200, content=b"pcm")
        return httpx.Response(200, json={})

    provider = LocalProvider(
        Settings(
            stt_url="http://local/transcribe",
            tts_url="http://local/speech",
            stt_language="auto",
            tts_default_language="it",
        )
    )
    provider.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))

    async def scenario() -> None:
        transcription = await provider.transcribe_float32(b"\x00" * 16, 48_000)
        audio = await provider.synthesize("hello", transcription.language)
        assert transcription.text == "hello"
        assert transcription.language == "en"
        assert audio == b"pcm"
        assert len(requests) == 2
        assert b'name="language"' not in requests[0].content
        await provider.close()

    import asyncio

    asyncio.run(scenario())


def test_local_provider_injects_detected_language_into_llm_prompt() -> None:
    requests: list[dict] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content.decode("utf-8"))
        requests.append(body)
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "content": "I answer in English.",
                        }
                    }
                ]
            },
        )

    provider = LocalProvider(Settings(llm_url="http://local/chat"))
    provider.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))

    async def scenario() -> None:
        response = await provider.chat("Who are you?", SceneState(active_demo="llm"), response_language="en")
        assert response == "I answer in English."
        system_prompt = requests[0]["messages"][0]["content"]
        user_content = requests[0]["messages"][1]["content"]
        assert "Reply ONLY in English" in system_prompt
        assert "Reply ONLY in English" in user_content
        assert "Do not offer translation or language switching" in system_prompt
        assert "Italian" not in system_prompt
        assert "Italian" not in user_content
        await provider.close()

    import asyncio

    asyncio.run(scenario())


def test_local_model_timeout_gives_an_actionable_error() -> None:
    import asyncio
    import pytest

    async def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("", request=request)

    async def scenario() -> None:
        provider = LocalProvider(Settings(llm_url="http://local/chat"))
        await provider.client.aclose()
        provider.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        try:
            with pytest.raises(RuntimeError, match="Il modello AI locale non ha risposto in tempo"):
                await provider.chat("Qual è la temperatura?", SceneState(active_demo="llm"))
        finally:
            await provider.close()

    asyncio.run(scenario())


def test_local_thinking_override_is_opt_in_for_planner_and_answer() -> None:
    import asyncio

    async def scenario() -> None:
        for thinking in (None, False):
            requests = []

            async def handler(request: httpx.Request) -> httpx.Response:
                requests.append(json.loads(request.content))
                return httpx.Response(200, json={"choices": [{"message": {"content": '{"needs_snapshot":false}'}}]})

            provider = LocalProvider(Settings(llm_enable_thinking=thinking, llm_max_tokens=192))
            await provider.client.aclose()
            provider.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
            try:
                decision = await provider.decide_vision("Ciao", SceneState(active_demo="llm"))
                await provider.chat("Ciao", SceneState(active_demo="llm"), response_language="it")
                assert not decision.needs_snapshot and len(requests) == 2
                assert requests[0]["max_tokens"] == provider.settings.vision_decision_max_tokens
                assert requests[1]["max_tokens"] == 192
                for body in requests:
                    if thinking is None:
                        assert "chat_template_kwargs" not in body
                    else:
                        assert body["chat_template_kwargs"] == {"enable_thinking": False}
            finally:
                await provider.close()

    asyncio.run(scenario())
