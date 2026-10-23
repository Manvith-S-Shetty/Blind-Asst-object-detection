"""
mDNS / DNS-SD publisher for the development backend.

When environment=development, this module advertises the FastAPI server as:
  _blindassist._tcp.local.  (service type)
  BlindAssistantDev         (service name)

on the LAN-accessible IP so that the Flutter app can resolve the address
without the developer manually entering an IP address.

LIMITATIONS (documented per spec):
  - Guest / isolated Wi-Fi networks that block multicast will prevent
    discovery.  Use manual configuration or QR code as fallback.
  - VPN tunnels and routers that block mDNS (port 5353 UDP multicast) will
    also prevent discovery.
  - If the host has multiple active network interfaces the publisher picks
    the first non-loopback IPv4 address; review the startup log if the
    wrong interface is selected.
  - This publisher is disabled automatically in production (environment != development).

Dependencies:
  pip install zeroconf
  Already listed in requirements.txt as optional; uncomment if mDNS is used.
"""
import socket
import threading
from typing import Optional

from app.core.logging_config import logger


def _get_lan_ip() -> str:
    """
    Return the first non-loopback IPv4 address that can reach the internet,
    which is typically the LAN IP visible to other devices on the same subnet.
    Falls back to 127.0.0.1 if no LAN interface is found.
    """
    try:
        # Create a UDP socket pointed at an external address (no packet sent).
        # The OS fills in the source address from the routing table.
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


class MdnsPublisher:
    """
    Lifecycle-managed mDNS / DNS-SD advertisement for the Blind Assistant
    development backend.  Call start() after the server binds and stop()
    on shutdown.  Thread-safe.
    """

    def __init__(self, service_type: str, service_name: str, port: int) -> None:
        self._service_type = service_type
        self._service_name = service_name
        self._port = port
        self._zeroconf: Optional[object] = None
        self._service_info: Optional[object] = None
        self._lock = threading.Lock()
        self._started = False

    def start(self) -> None:
        """Attempt to register the mDNS service.  Logs warnings and returns
        gracefully if zeroconf is not installed or if registration fails —
        the backend continues to operate normally; only discovery is unavailable."""
        with self._lock:
            if self._started:
                return
            try:
                from zeroconf import Zeroconf, ServiceInfo  # type: ignore
                import socket as _socket

                lan_ip = _get_lan_ip()
                logger.info(
                    f"mDNS: advertising {self._service_name!r} on {lan_ip}:{self._port} "
                    f"(type={self._service_type!r})"
                )

                self._service_info = ServiceInfo(
                    type_=self._service_type,
                    name=f"{self._service_name}.{self._service_type}",
                    addresses=[_socket.inet_aton(lan_ip)],
                    port=self._port,
                    properties={
                        b"version": b"1",
                        b"path": b"/api/v1",
                    },
                    server=f"{self._service_name}.local.",
                )
                self._zeroconf = Zeroconf()
                self._zeroconf.register_service(self._service_info)
                self._started = True
                logger.info(
                    "mDNS: service registered — Android app will auto-discover this backend. "
                    "Resolve: _blindassist._tcp.local."
                )
            except ImportError:
                logger.warning(
                    "mDNS: zeroconf package not installed.  "
                    "Run `pip install zeroconf` to enable automatic discovery.  "
                    "Falling back to manual IP configuration."
                )
            except Exception as exc:
                logger.warning(
                    f"mDNS: could not register service ({exc}).  "
                    "Falling back to manual IP configuration."
                )

    def stop(self) -> None:
        """Unregister the mDNS service and close the zeroconf instance."""
        with self._lock:
            if not self._started:
                return
            try:
                if self._zeroconf and self._service_info:
                    self._zeroconf.unregister_service(self._service_info)
                    self._zeroconf.close()
                    logger.info("mDNS: service unregistered.")
            except Exception as exc:
                logger.warning(f"mDNS: error during shutdown ({exc}).")
            finally:
                self._zeroconf = None
                self._service_info = None
                self._started = False

    @property
    def lan_ip(self) -> str:
        return _get_lan_ip()
