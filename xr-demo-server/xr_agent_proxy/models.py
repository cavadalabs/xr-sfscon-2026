from pydantic import BaseModel, Field


class SceneState(BaseModel):
    objects: list[str] = Field(default_factory=list)
    gaze_target: str | None = None
    active_demo: str | None = None
    metadata: dict = Field(default_factory=dict)


class SessionState(BaseModel):
    sample_rate: int = 48_000
    scene: SceneState = Field(default_factory=SceneState)


class TranscriptionResult(BaseModel):
    text: str = ""
    language: str | None = None


class VisionDecision(BaseModel):
    needs_snapshot: bool = False
    snapshot_prompt: str = ""
    reason: str = ""


class ProviderTurnResult(BaseModel):
    transcript: str = ""
    response_text: str = ""
    audio: bytes = b""
    output_sample_rate: int = 24_000
