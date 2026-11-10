# XR Demo Server

`xr-agent-proxy` is the realtime XR agent between the Quest app and swappable AI providers.

The Quest should only talk to this proxy. The proxy then calls STT, LLM/Vision and TTS providers.
It also owns the XR vision tool loop: when a user turn needs the current physical view, the proxy asks the connected Quest for one snapshot, then calls the vision-capable LLM with the image and XR context.

The current LangChain tool is:

```text
get_what_user_is_seeing(prompt: str) -> dict
```

The tool docstring tells the agent to use it for questions about what the user is seeing, visible objects/text or the physical room. It returns `image_jpeg_base64`, `metadata`, `request_id` and `prompt`.

## Local Provider

Select the local CavadaLabs provider with:

```text
XR_AGENT_PROVIDER=local
XR_LOCAL_TLS_VERIFY=false
```

Default endpoints:

```text
STT: http://127.0.0.1:8011/transcribe
LLM: http://127.0.0.1:8015/v1/chat/completions
TTS: https://127.0.0.1:8020/v1/audio/speech
model: ministral-3-14b-vision-local
```

`/healthz` checks the configured local health endpoints:

```text
XR_STT_HEALTH_URL=http://127.0.0.1:8011/healthz
XR_LLM_HEALTH_URL=http://127.0.0.1:8015/v1/models
XR_TTS_HEALTH_URL=https://127.0.0.1:8020/health
```

`XR_LOCAL_TLS_VERIFY=false` is needed for the current local LiveTTS HTTPS certificate.

For the November voice demo, the local LLM is the Ministral service on your GPU node
port `8015`: set `XR_LLM_URL=http://127.0.0.1:8015/v1/chat/completions`,
`XR_LLM_HEALTH_URL=http://127.0.0.1:8015/health` and `XR_LLM_MODEL=your-model`
in the local `.env`. If the endpoint exposes a thinking model instead, also set
`XR_LLM_ENABLE_THINKING=false` and `XR_LLM_MAX_TOKENS=192`.
This applies the [llama.cpp per-request template option](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md#post-v1chatcompletions-openai-compatible-chat-completions-api)
to both the vision decision and the answer, without changing the shared model server.
Omit `XR_LLM_ENABLE_THINKING` for endpoints that do not support this option.

Agent vision settings:

```text
XR_VISION_AGENT_ENABLED=true
XR_VISION_SNAPSHOT_TIMEOUT_SECONDS=10
XR_VISION_DECISION_MAX_TOKENS=120
```

## Google Gemini Live Provider

Set this in `.env` to switch the backend to Google speech-to-speech without changing Godot/Quest:

```text
XR_AGENT_PROVIDER=google
XR_GOOGLE_API_KEY=...
XR_GOOGLE_API_VERSION=v1beta
XR_GOOGLE_LIVE_MODEL=gemini-3.1-flash-live-preview
XR_GOOGLE_TEXT_MODEL=gemini-2.5-flash
XR_GOOGLE_VOICE_NAME=Charon
XR_GOOGLE_LANGUAGE_CODE=it-IT
XR_GOOGLE_LOCATION=europe-west4
XR_GOOGLE_VIDEO_STREAM_ENABLED=false
```

Vertex/Enterprise mode is also supported. In that mode the GA native-audio model documented for Gemini Enterprise Agent Platform can be used:

```text
XR_AGENT_PROVIDER=google
XR_GOOGLE_USE_VERTEXAI=true
XR_GOOGLE_PROJECT_ID=your-gcp-project
XR_GOOGLE_LOCATION=europe-west4
XR_GOOGLE_LIVE_MODEL=gemini-live-2.5-flash-native-audio
```

The Quest protocol stays the same:

```text
Quest Float32 PCM 48 kHz -> xr-agent-proxy -> Google Live PCM16 16 kHz
Google Live PCM16 24 kHz -> xr-agent-proxy -> Quest
```

For `google`, the proxy uses a single Live API turn for speech-to-speech. It still emits the same Quest-facing state events (`stt.done`, `llm.done`, `tts.start`, binary audio, `tts.done`) so the headset does not need provider-specific code.

The provider also exposes a Gemini function tool named `get_what_user_is_seeing`. When Gemini asks for it, the proxy requests one snapshot from the connected Quest, sends that JPEG to the Live session, and returns metadata to the tool call. Vision remains snapshot-only, not continuous video.

Experimental video mode can be enabled with `XR_GOOGLE_VIDEO_STREAM_ENABLED=true`. The Quest can then send small JPEG frames to the proxy while the LLM demo is open; the proxy forwards fresh frames only during an active Google Live turn. Keep it disabled unless explicitly testing cost and latency.

## Run

```bash
cp .env.example .env
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
uvicorn xr_agent_proxy.app:app --host 0.0.0.0 --port 8091
```

Health:

```bash
curl http://127.0.0.1:8091/healthz
```

WebSocket:

```text
ws://<server-ip>:8091/ws/realtime
```

The Quest app should keep pointing to the proxy URL, for example:

```text
ws://<server-ip>:8091/ws/realtime
```

Provider changes are server-side only. Switch `XR_AGENT_PROVIDER` in `.env` and restart the proxy; Godot does not need scene or script changes.

## Protocol MVP

JSON text messages:

```json
{"type":"session.start","sample_rate":48000}
{"type":"scene.state","objects":["robot_arm","panel"],"gaze_target":"panel"}
{"type":"audio.commit"}
{"type":"barge_in"}
{"type":"vision.snapshot","request_id":"...","image_jpeg_base64":"..."}
{"type":"vision.snapshot.request","request_id":"...","prompt":"...","timeout_seconds":8}
```

Binary WebSocket frames are raw mono Float32 PCM from the Quest. The proxy buffers those frames until `audio.commit`, then starts an async turn:

```text
STT -> vision decision -> optional LangChain tool get_what_user_is_seeing -> LLM/Vision -> TTS -> Quest audio
```

The proxy returns JSON state events such as `session.ready`, `stt.done`, `vision.decision`, `vision.start`, `vision.ready`, `llm.done`, `tts.start`, `tts.done` and `error`.

Vision is snapshot-only for now. No continuous video.

The backend agent can ask the connected Quest for one camera frame through the proxy:

```bash
curl -X POST http://127.0.0.1:8091/vision/snapshot/request \
  -H 'content-type: application/json' \
  -d '{"prompt":"Analizza quello che vede l utente e rispondi in italiano.","timeout_seconds":8}'
```

The HTTP response contains `request_id`, `image_jpeg_base64`, `prompt` and `metadata`. If no Quest realtime session is connected, the endpoint returns `503`.

## NoiBot lip sync (local TTS)

When the Quest sends `metadata.avatar = "noibot"` (legacy `"milo"` also accepted),
the proxy analyzes the exact
completed TTS audio and includes `mouth_cues` (Rhubarb A–H/X, seconds) in
`audio.output.start`. Other turns skip the analysis. Configure
`XR_LIPSYNC_PACKAGE` with the directory of the existing
`rhubarb-lip-sync-wasm` **0.1.8** package; Node.js and FFmpeg must be on PATH.
`tools/noibot_lipsync.mjs` is reused from the Milo delivery. No recognizer is sent
to the Quest. Analysis times out after `XR_LIPSYNC_TIMEOUT_SECONDS` (12 by default)
and is cancelled with the turn. Without cues, audio continues and NoiBot uses
amplitude animation. Rhubarb's Italian articulation is approximate. The current
integration targets completed local TTS responses, not Google live streaming.
The client follows its existing audio player and clears cues on interruption.
