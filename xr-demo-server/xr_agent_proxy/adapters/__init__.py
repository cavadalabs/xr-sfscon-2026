from xr_agent_proxy.adapters.local import LocalProvider
from xr_agent_proxy.config import Settings

LOCAL_PROVIDER_NAMES = {"local", "cavadalabs-local", "cavadalabs"}
GOOGLE_PROVIDER_NAMES = {"google", "google-live", "gemini", "gemini-live"}


def create_provider(settings: Settings):
    provider_name = normalized_provider_name(settings.agent_provider)
    if provider_name == "google":
        from xr_agent_proxy.adapters.google_live import GoogleLiveProvider

        return GoogleLiveProvider(settings)
    if provider_name == "local":
        return LocalProvider(settings)

    raise ValueError(
        "Unsupported XR_AGENT_PROVIDER=%r. Use one of: local, google." % settings.agent_provider
    )


def normalized_provider_name(provider_name: str) -> str:
    normalized = provider_name.strip().lower().replace("_", "-")
    if normalized in LOCAL_PROVIDER_NAMES:
        return "local"
    if normalized in GOOGLE_PROVIDER_NAMES:
        return "google"
    return normalized


__all__ = ["LocalProvider", "create_provider", "normalized_provider_name"]
