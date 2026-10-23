import base64
import io
import json
import os
import pytest
from httpx import AsyncClient, ASGITransport
from PIL import Image
import numpy as np

from app.main import app
from app.pipeline.factory import pipeline, UnavailableComponent, ModelUnavailableError


@pytest.fixture
def sample_image_base64():
    bus_path = os.path.join(
        os.path.dirname(__file__), "..", "..", "venv", "Lib", "site-packages", "ultralytics", "assets", "bus.jpg"
    )
    with open(bus_path, "rb") as f:
        return base64.b64encode(f.read()).decode("utf-8")


@pytest.mark.asyncio
async def test_rest_frame_analysis_end_to_end(sample_image_base64):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # 1. Start session
        start_res = await client.post("/api/v1/session/start")
        assert start_res.status_code == 200
        session_id = start_res.json()["session_id"]
        assert session_id

        # 2. Analyze frame over REST
        payload = {"image_base64": sample_image_base64}
        frame_res = await client.post(f"/api/v1/session/{session_id}/frame", json=payload)
        assert frame_res.status_code == 200
        data = frame_res.json()

        assert data["session_id"] == session_id
        assert data["frame_id"] == 1
        assert len(data["detections"]) > 0

        # Check real perception fields
        for d in data["detections"]:
            assert "label" in d
            assert "confidence" in d
            assert "bbox" in d
            # Tracking assigns track_id
            assert d.get("track_id") is not None
            # Depth estimator assigns distance_m and direction
            assert d.get("distance_m") is not None
            assert d.get("direction") in ["left", "center", "right"]

        # Decision engine guidance generated
        assert "guidance" in data
        assert len(data["guidance"]) > 0
        assert data["processing_time_ms"] > 0

        # 3. End session
        end_res = await client.post(f"/api/v1/session/{session_id}/end")
        assert end_res.status_code == 200


@pytest.mark.asyncio
async def test_rest_malformed_image_frame():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        payload = {"image_base64": "not_valid_base64!!!"}
        res = await client.post("/api/v1/session/sess_test/frame", json=payload)
        assert res.status_code == 400
        assert "Invalid image data" in res.json()["detail"]


@pytest.mark.asyncio
async def test_websocket_navigation_stream(sample_image_base64):
    from fastapi.testclient import TestClient
    from app.core.config import settings

    orig_interval = settings.frame_process_interval_s
    settings.frame_process_interval_s = 0.0
    try:
        client = TestClient(app)
        with client.websocket_connect("/ws/navigate/test_ws_session") as ws:
            # Frame 1: Valid frame
            ws.send_json({"image_base64": sample_image_base64})
            resp1 = ws.receive_json()
            assert "frame_id" in resp1
            assert resp1["frame_id"] == 1
            assert len(resp1["detections"]) > 0
            assert len(resp1["guidance"]) > 0

            # Malformed payload: missing image_base64
            ws.send_text("not json at all")
            err1 = ws.receive_json()
            assert err1.get("error") == "invalid_payload"

            # Malformed image: bad base64
            ws.send_json({"image_base64": "corrupt_data_here"})
            err2 = ws.receive_json()
            assert err2.get("error") == "invalid_image_data"
    finally:
        settings.frame_process_interval_s = orig_interval


@pytest.mark.asyncio
async def test_explicit_unavailable_state_when_model_fails():
    unavail = UnavailableComponent("depth_estimator", "Missing model weights")
    with pytest.raises(ModelUnavailableError) as exc_info:
        await unavail.estimate(None, [])
    assert exc_info.value.component_key == "depth_estimator"
    assert "Missing model weights" in exc_info.value.reason


@pytest.mark.asyncio
async def test_websocket_timestamps_and_latency(sample_image_base64):
    from fastapi.testclient import TestClient
    from app.core.config import settings

    orig_interval = settings.frame_process_interval_s
    settings.frame_process_interval_s = 0.0
    try:
        client = TestClient(app)
        with client.websocket_connect("/ws/navigate/test_timestamp_session") as ws:
            ws.send_json({
                "image_base64": sample_image_base64,
                "client_timestamp_ms": 1729620000000,
                "frame_seq": 42,
            })
            resp = ws.receive_json()
            assert resp["client_timestamp_ms"] == 1729620000000
            assert resp["frame_seq"] == 42
            assert "processing_time_ms" in resp
            assert resp["processing_time_ms"] > 0
    finally:
        settings.frame_process_interval_s = orig_interval


@pytest.mark.asyncio
async def test_trim_memory_endpoint():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        res = await client.post("/api/v1/system/trim-memory")
        assert res.status_code == 200
        assert res.json()["status"] == "ok"


def test_production_security_validators():
    from app.core.config import Settings
    import pytest

    # Reject short or default jwt_secret in production
    with pytest.raises(ValueError, match="JWT_SECRET must be set"):
        Settings(environment="production", jwt_secret="too-short")

    # Reject wildcard CORS in production
    with pytest.raises(ValueError, match="Wildcard CORS"):
        Settings(
            environment="production",
            jwt_secret="a" * 32,
            cors_origins=["*"]
        )

    # Reject weak admin_api_key in production
    with pytest.raises(ValueError, match="ADMIN_API_KEY must be at least 16 characters"):
        Settings(
            environment="production",
            jwt_secret="a" * 32,
            cors_origins=["https://blindassistant.example.com"],
            admin_api_key="short"
        )

    # Valid production settings pass
    valid_cfg = Settings(
        environment="production",
        jwt_secret="a" * 32,
        cors_origins=["https://blindassistant.example.com"],
        admin_api_key="super-secret-admin-key-32chars!"
    )
    assert valid_cfg.environment == "production"


@pytest.mark.asyncio
async def test_trim_memory_admin_authorization():
    from app.core.config import settings

    orig_key = settings.admin_api_key
    settings.admin_api_key = "secure-admin-passphrase-key-123"
    transport = ASGITransport(app=app)
    try:
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            # Without key -> 403
            res1 = await client.post("/api/v1/system/trim-memory")
            assert res1.status_code == 403

            # With wrong key -> 403
            res2 = await client.post("/api/v1/system/trim-memory", headers={"X-Admin-Key": "wrong-key"})
            assert res2.status_code == 403

            # With valid key -> 200
            res3 = await client.post("/api/v1/system/trim-memory", headers={"X-Admin-Key": "secure-admin-passphrase-key-123"})
            assert res3.status_code == 200
    finally:
        settings.admin_api_key = orig_key


@pytest.mark.asyncio
async def test_websocket_oversized_dimensions_rejection(sample_image_base64):
    from fastapi.testclient import TestClient
    from app.core.config import settings

    orig_dim = settings.max_image_dimension
    orig_interval = settings.frame_process_interval_s
    settings.max_image_dimension = 20  # Sample image is > 20px
    settings.frame_process_interval_s = 0.0
    try:
        client = TestClient(app)
        with client.websocket_connect("/ws/navigate/test_oversized_dim_session") as ws:
            ws.send_json({"image_base64": sample_image_base64})
            resp = ws.receive_json()
            assert resp.get("error") == "image_dimension_too_large"
    finally:
        settings.max_image_dimension = orig_dim
        settings.frame_process_interval_s = orig_interval
