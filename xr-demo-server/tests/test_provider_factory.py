import pytest

from xr_agent_proxy.adapters import create_provider
from xr_agent_proxy.adapters.google_live import GoogleLiveProvider
from xr_agent_proxy.adapters.local import LocalProvider
from xr_agent_proxy.config import Settings
from xr_agent_proxy.models import SceneState


@pytest.mark.parametrize("provider_name", ["local", "cavadalabs-local", "cavadalabs"])
def test_provider_factory_creates_local_provider(provider_name: str) -> None:
    provider = create_provider(Settings(agent_provider=provider_name))

    assert isinstance(provider, LocalProvider)


@pytest.mark.parametrize("provider_name", ["google", "google-live", "gemini", "gemini-live"])
def test_provider_factory_creates_google_provider_lazily_without_token(provider_name: str) -> None:
    provider = create_provider(Settings(agent_provider=provider_name))

    assert isinstance(provider, GoogleLiveProvider)
    assert provider.client is None


def test_provider_factory_rejects_unknown_provider() -> None:
    with pytest.raises(ValueError, match="Unsupported XR_AGENT_PROVIDER"):
        create_provider(Settings(agent_provider="unknown"))


def test_google_provider_default_prompt_is_language_neutral() -> None:
    provider = GoogleLiveProvider(Settings(agent_provider="google"))

    prompt = provider._system_instruction(SceneState(active_demo="llm"))

    assert "Reply in the user's language" in prompt
    assert "Parla in italiano" not in prompt
    assert "answer in Italian" not in prompt
