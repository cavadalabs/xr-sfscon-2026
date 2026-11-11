# XR NOI Tech — SFSCON 2026 demos

Godot/OpenXR prototype for the Meta Quest plus a Python realtime agent proxy,
built for the SFSCON 2026 presentations at NOI Techpark (Bolzano, Italy):
an industrial & furniture 3D catalog, a NOI digital twin with Open Data Hub
info, and a voice + vision assistant that talks to swappable local or cloud
AI providers.

This repository is the **public, curated export** of a private project. The
private repository is the source of truth; everything here is generated and
pushed automatically by its publish pipeline.

## What's inside

| Folder | What it is |
| --- | --- |
| `xr-demo-suite/` | Godot 4.7 OpenXR app: main menu, industrial catalog with GLB showcase, NOI twin demo, shared (multi-headset) room, voice assistant UI |
| `demo_industrial/` | Standalone build of the industrial catalog demo (no main menu, exits on "Esci") |
| `demo_opendata/` | Standalone build of the NOI digital twin / Open Data Hub demo |
| `demo_llm/` | Standalone build of the voice + vision assistant demo |
| `xr-demo-server/` | `xr-agent-proxy`: FastAPI/WebSocket proxy between the Quest and STT / LLM-Vision / TTS providers, including the XR "what am I looking at?" snapshot tool loop |
| `template-xr-hackathon-scenna/` | Small standalone Godot template used at the Val Gardena hackathon: a spatial dashboard over Open Data Hub parking data (three difficulty levels) |

## Quick start — the app

1. Install **Godot 4.7 stable** (Mobile renderer), plus the Android SDK/JDK
   and the export templates of the same Godot version for Quest builds.
2. Open `xr-demo-suite/project.godot` in Godot and press F5 for a desktop run
   (no headset needed to browse the catalog).
3. For Quest: `Project → Export → Android` (ARM64 preset) and install the APK,
   or use Remote Debug from Godot.

### Pointing the app at your agent server

The proxy URL is **never** baked into the project. Copy
`xr-demo-suite/agent_config.example.json` to the Godot user data directory
(`user://agent_config.json` — e.g. `~/.local/share/godot/app_userdata/<project>/`
on Linux, or push it to the Quest under `Android/data/<package>/files/`) and set:

```json
{ "ws_url": "ws://YOUR_SERVER_IP:8091/ws/realtime" }
```

## Quick start — the agent proxy

```bash
cd xr-demo-server
cp .env.example .env        # edit provider URLs and keys
uv sync --extra dev
uv run --extra dev python -m pytest -q          # sanity check
uv run uvicorn xr_agent_proxy.app:app --host 0.0.0.0 --port 8091
```

The server can run entirely against local models (any OpenAI-compatible
endpoints for STT/LLM/TTS on your GPU node) or against a cloud provider; see
[`xr-demo-server/README.md`](xr-demo-server/README.md) for the full matrix.

## Requirements

- Godot **4.7 stable** — Mobile renderer, OpenXR.
- Meta Quest 3 with developer mode (for on-device runs).
- Python ≥ 3.12 and [uv](https://docs.astral.sh/uv/) for the server.
- Optional: a GPU node exposing OpenAI-compatible speech + chat models.

## Documentation

- `xr-demo-suite/README.md` — environment, run, export, shared room setup
- `xr-demo-suite/docs/architecture.md` — components and scene structure
- `xr-demo-suite/docs/condivisione.md` — two headsets in one shared room
- `xr-demo-suite/docs/guida_editor.md` — editing scenes safely
- `xr-demo-server/README.md` — provider configuration and the vision tool loop
- `template-xr-hackathon-scenna/README.md` — standalone hackathon template
- `THIRD_PARTY.md` — asset and addon provenance and licenses

## License

Source code in this repository is released under the
**[Source-Available License 1.0](LICENSE)** — free to read, learn
from and build privately; redistribution or commercial use requires written
permission. Third-party assets and addons keep their own licenses, listed in
[`THIRD_PARTY.md`](THIRD_PARTY.md).
