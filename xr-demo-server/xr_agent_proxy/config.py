from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="XR_", env_file=".env", extra="ignore")

    agent_host: str = "0.0.0.0"
    agent_port: int = 8091
    agent_provider: str = "local"
    demo_token: str = ""
    local_tls_verify: bool = True

    stt_url: str = "http://localhost:8011/transcribe"
    stt_health_url: str = "http://localhost:8011/healthz"
    stt_language: str = "auto"
    llm_url: str = "http://localhost:8015/v1/chat/completions"
    llm_health_url: str = "http://localhost:8015/v1/models"
    llm_model: str = "your-local-model"
    tts_url: str = "https://localhost:8020/v1/audio/speech"
    tts_health_url: str = "https://localhost:8020/health"
    tts_voice: str = "default"
    tts_default_language: str = "it"
    tts_voice_map: str = ""
    tts_response_format: str = "pcm16"
    tts_stream_enabled: bool = True

    input_sample_rate: int = 48_000
    output_sample_rate: int = 24_000
    request_timeout_seconds: float = 60.0
    health_timeout_seconds: float = 2.0
    llm_max_tokens: int = 0
    llm_enable_thinking: bool | None = None
    vision_decision_max_tokens: int = 120
    vision_snapshot_timeout_seconds: float = 10.0
    vision_agent_enabled: bool = True
    response_max_chars: int = 0
    audio_chunk_bytes: int = 16_384
    lipsync_package: str = ""
    lipsync_timeout_seconds: float = 12.0

    google_api_key: str = ""
    google_use_vertexai: bool = False
    google_project_id: str = ""
    google_location: str = "europe-west4"
    google_api_version: str = "v1beta"
    google_live_model: str = "gemini-3.1-flash-live-preview"
    google_text_model: str = "gemini-2.5-flash"
    google_voice_name: str = "Charon"
    google_language_code: str = "it-IT"
    google_input_sample_rate: int = 16_000
    google_output_sample_rate: int = 24_000
    google_audio_chunk_bytes: int = 3_200
    google_turn_timeout_seconds: float = 60.0
    google_temperature: float = 0.4
    google_snapshot_tool_enabled: bool = True
    google_video_stream_enabled: bool = False
    google_video_max_frame_age_seconds: float = 2.5
    google_system_instruction: str = ""


settings = Settings()
