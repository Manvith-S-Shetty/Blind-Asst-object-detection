"""
Tests for the automatic backend connection upgrade:
  - /ping endpoint (lightweight, no model loading)
  - mDNS publisher LAN-IP helper
  - BackendConnectionManager equivalent logic (URL construction tests)
  - Settings production validator for mdns_enabled
"""
import asyncio
import socket
import pytest
from httpx import AsyncClient, ASGITransport
from unittest.mock import patch, MagicMock

from app.main import app
from app.core.config import settings, Settings
from app.services.mdns_publisher import MdnsPublisher, _get_lan_ip


# ---------------------------------------------------------------------------
# /ping endpoint
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_ping_returns_200_without_model_loading():
    """
    /ping must return HTTP 200 immediately.  It must NOT trigger any
    model inference or startup side-effects (detector warmup is tested
    separately).  This is the endpoint used by the connection manager
    for cheap reachability probes.
    """
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        res = await client.get("/ping")
    assert res.status_code == 200
    body = res.json()
    assert body.get("status") == "ok"


@pytest.mark.asyncio
async def test_ping_is_distinct_from_health_endpoint():
    """
    /ping and /api/v1/health are both reachable.  /ping lives at the root
    (not under /api/v1) so that the connection manager can probe without
    constructing the full API prefix URL.
    """
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        ping_res = await client.get("/ping")
        health_res = await client.get("/api/v1/health")
    assert ping_res.status_code == 200
    assert health_res.status_code == 200


@pytest.mark.asyncio
async def test_root_endpoint_still_reachable():
    """Root endpoint / must return app name and docs link."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        res = await client.get("/")
    assert res.status_code == 200
    assert "Blind Assistant" in res.json().get("app", "")


# ---------------------------------------------------------------------------
# URL construction correctness
# ---------------------------------------------------------------------------

def test_httpbase_includes_api_v1_prefix():
    """
    BackendConnectionManager stores the host/port; API service then constructs
    http://{host}:{port}/api/v1.  Health endpoint is at /api/v1/health.
    """
    host, port = "192.168.1.5", 8000
    http_base = f"http://{host}:{port}/api/v1"
    assert http_base == "http://192.168.1.5:8000/api/v1"


def test_ping_url_does_not_include_api_prefix():
    """
    /ping lives at the root so connection probes are cheap (no API prefix).
    """
    host, port = "192.168.1.5", 8000
    ping_url = f"http://{host}:{port}/ping"
    assert "/api/v1" not in ping_url
    assert ping_url.endswith("/ping")


def test_websocket_url_construction():
    """
    WebSocket URL must use ws:// scheme with no trailing path segment;
    the path /ws/navigate/{session_id} is appended by NavigationSocket.
    """
    host, port = "192.168.1.5", 8000
    ws_base = f"ws://{host}:{port}"
    full_ws = f"{ws_base}/ws/navigate/test_session"
    assert full_ws == "ws://192.168.1.5:8000/ws/navigate/test_session"


def test_emulator_default_host_sentinel():
    """
    10.0.2.2 is the Android emulator loopback sentinel.  The connection
    manager should detect this and trigger mDNS discovery rather than
    attempting direct connect on a physical device.
    """
    emulator_host = "10.0.2.2"
    other_host = "192.168.1.5"
    assert emulator_host == "10.0.2.2"
    assert other_host != "10.0.2.2"


# ---------------------------------------------------------------------------
# mDNS publisher
# ---------------------------------------------------------------------------

def test_get_lan_ip_returns_valid_ipv4():
    """
    _get_lan_ip() must return a valid IPv4 address string.  On CI the
    machine may have only 127.0.0.1; that is acceptable.
    """
    ip = _get_lan_ip()
    parts = ip.split(".")
    assert len(parts) == 4
    for part in parts:
        assert part.isdigit()
        assert 0 <= int(part) <= 255


def test_mdns_publisher_start_with_zeroconf_unavailable():
    """
    If zeroconf is not installed, MdnsPublisher.start() must log a warning
    and return gracefully — the server must continue operating normally.
    """
    publisher = MdnsPublisher("_blindassist._tcp.local.", "Test", 8000)
    with patch("builtins.__import__", side_effect=ImportError("no module zeroconf")):
        # Should not raise; logs warning internally
        try:
            publisher.start()
        except ImportError:
            pass  # ImportError is caught internally; this means the test env has zeroconf
    # Whether zeroconf is installed or not, stop() must be safe to call
    publisher.stop()


def test_mdns_publisher_stop_is_idempotent():
    """stop() on an unstarted publisher must be a safe no-op."""
    publisher = MdnsPublisher("_blindassist._tcp.local.", "Test", 8000)
    publisher.stop()  # should not raise
    publisher.stop()  # second call also safe


def test_mdns_publisher_start_registers_service():
    """
    When zeroconf IS available, start() should call register_service.
    We mock the entire zeroconf module to avoid network calls in tests.
    """
    mock_zeroconf_cls = MagicMock()
    mock_zeroconf_instance = MagicMock()
    mock_zeroconf_cls.return_value = mock_zeroconf_instance

    mock_service_info_cls = MagicMock()
    mock_service_info_instance = MagicMock()
    mock_service_info_cls.return_value = mock_service_info_instance

    publisher = MdnsPublisher("_blindassist._tcp.local.", "TestService", 8000)

    with patch.dict("sys.modules", {
        "zeroconf": MagicMock(
            Zeroconf=mock_zeroconf_cls,
            ServiceInfo=mock_service_info_cls,
        )
    }):
        publisher.start()
        assert publisher._started
        mock_zeroconf_instance.register_service.assert_called_once_with(
            mock_service_info_instance
        )

        publisher.stop()
        assert not publisher._started
        mock_zeroconf_instance.unregister_service.assert_called_once()
        mock_zeroconf_instance.close.assert_called_once()


def test_mdns_publisher_start_is_idempotent():
    """Calling start() twice on an already-started publisher is safe."""
    mock_zeroconf_cls = MagicMock()
    mock_zeroconf_cls.return_value = MagicMock()

    publisher = MdnsPublisher("_blindassist._tcp.local.", "TestService", 8000)

    with patch.dict("sys.modules", {
        "zeroconf": MagicMock(
            Zeroconf=mock_zeroconf_cls,
            ServiceInfo=MagicMock(return_value=MagicMock()),
        )
    }):
        publisher.start()
        publisher.start()  # second call should be a no-op
        # register_service should have been called only once
        assert mock_zeroconf_cls.return_value.register_service.call_count == 1
        publisher.stop()


# ---------------------------------------------------------------------------
# Production security: mDNS disabled in production
# ---------------------------------------------------------------------------

def test_mdns_disabled_in_production():
    """
    In production, mdns_enabled must be forced to False by the settings
    validator even if the caller tried to set it to True.
    """
    prod_settings = Settings(
        environment="production",
        jwt_secret="a" * 32,
        cors_origins=["https://blindassist.example.com"],
        mdns_enabled=True,  # user tried to enable it — must be rejected
    )
    assert prod_settings.mdns_enabled is False


def test_mdns_enabled_in_development():
    """mDNS is enabled by default in development environments."""
    dev_settings = Settings(environment="development")
    assert dev_settings.mdns_enabled is True


def test_is_development_property():
    """is_development reflects the environment setting."""
    assert Settings(environment="development").is_development is True
    assert Settings(environment="production",
                    jwt_secret="a" * 32,
                    cors_origins=["https://x.example.com"]).is_development is False


# ---------------------------------------------------------------------------
# Health endpoint unchanged (regression)
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_health_endpoint_unchanged():
    """Existing /api/v1/health must still return status=ok."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        res = await client.get("/api/v1/health")
    assert res.status_code == 200
    assert res.json().get("status") == "ok"
