import json
import uuid
import asyncio

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from xr_agent_proxy.adapters import create_provider
from xr_agent_proxy.config import settings
from xr_agent_proxy.session import RealtimeSession

app = FastAPI(title="XR Agent Proxy")
provider = create_provider(settings)
active_session: RealtimeSession | None = None


## Demo token: accepted as X-XR-Demo-Token header or ?token= query parameter
## (the Quest app carries it in the websocket URL).
## Empty token disables the guard (LAN development stays token-free).
def _token_ok(token: str | None) -> bool:
    return not settings.demo_token or token == settings.demo_token


@app.middleware("http")
async def demo_token_guard(request, call_next):
    if request.url.path != "/healthz" and not _token_ok(request.headers.get("x-xr-demo-token") or request.query_params.get("token")):
        return JSONResponse({"detail": "Invalid or missing demo token."}, status_code=401)
    return await call_next(request)


class SnapshotRequest(BaseModel):
    request_id: str | None = None
    prompt: str = "Analyze what the user sees and answer in the user's language."
    timeout_seconds: float = Field(default=8.0, ge=1.0, le=30.0)


@app.get("/healthz")
async def healthz() -> dict:
    return {
        "ok": True,
        "quest_connected": active_session is not None,
        "provider": await provider.health(),
    }


@app.on_event("shutdown")
async def shutdown() -> None:
    close = getattr(provider, "close", None)
    if close is not None:
        await close()


@app.post("/vision/snapshot/request")
async def request_snapshot(body: SnapshotRequest) -> dict:
    if active_session is None:
        raise HTTPException(status_code=503, detail="No Quest realtime session connected.")

    request_id = body.request_id or uuid.uuid4().hex
    try:
        result = await active_session.request_snapshot(request_id, body.prompt, body.timeout_seconds)
    except asyncio.TimeoutError as exc:
        raise HTTPException(status_code=504, detail="Quest snapshot request timed out.") from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    return {
        "request_id": request_id,
        "image_jpeg_base64": str(result.get("image_jpeg_base64") or ""),
        "prompt": result.get("prompt"),
        "metadata": dict(result.get("metadata") or {}),
    }


@app.websocket("/ws/realtime")
async def realtime(websocket: WebSocket) -> None:
    global active_session

    if not _token_ok(websocket.headers.get("x-xr-demo-token") or websocket.query_params.get("token")):
        await websocket.close(code=1008)
        return
    await websocket.accept()
    session = RealtimeSession(websocket, provider)

    try:
        await session.send_event("session.connected")
        active_session = session
        while True:
            message = await websocket.receive()
            if message.get("type") == "websocket.disconnect":
                return
            if "text" in message and message["text"] is not None:
                await session.handle_json(json.loads(message["text"]))
            elif "bytes" in message and message["bytes"] is not None:
                await session.handle_audio(message["bytes"])
    except WebSocketDisconnect:
        return
    except Exception as exc:
        await session.try_send_event("error", message=str(exc))
    finally:
        if active_session is session:
            active_session = None
