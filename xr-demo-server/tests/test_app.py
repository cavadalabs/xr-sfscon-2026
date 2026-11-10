from fastapi.testclient import TestClient

import xr_agent_proxy.app as app_module


class FakeHealthProvider:
    async def health(self) -> dict:
        return {"ready": True, "provider": "test"}


def test_healthz_reports_provider_status(monkeypatch) -> None:
    monkeypatch.setattr(app_module, "provider", FakeHealthProvider())
    monkeypatch.setattr(app_module, "active_session", None)

    with TestClient(app_module.app) as client:
        response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {
        "ok": True,
        "quest_connected": False,
        "provider": {"ready": True, "provider": "test"},
    }


def test_websocket_realtime_handshake(monkeypatch) -> None:
    monkeypatch.setattr(app_module, "provider", FakeHealthProvider())
    monkeypatch.setattr(app_module, "active_session", None)

    with TestClient(app_module.app) as client:
        with client.websocket_connect("/ws/realtime") as websocket:
            assert websocket.receive_json() == {"type": "session.connected"}
