"""
Central configuration with hardened production validation.
Toggle USE_REAL_MODELS per-component to switch a pipeline stage from
the deterministic mock implementation to a real one.
"""
from typing import Dict, List, Optional
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import model_validator
from app.core.logging_config import logger


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_nested_delimiter="__", extra="ignore")

    app_name: str = "Blind Assistant AI"
    api_v1_prefix: str = "/api/v1"
    environment: str = "development"  # "development" | "staging" | "production"

    # Server bind address (set via BIND_HOST / BIND_PORT env vars or .env)
    # Use 0.0.0.0 to accept connections from the local network (phone + laptop on same Wi-Fi).
    bind_host: str = "0.0.0.0"
    bind_port: int = 8000

    # mDNS / DNS-SD advertisement (development only — never enabled in production)
    # The Android app resolves _blindassist._tcp.local. to find the backend automatically.
    mdns_service_type: str = "_blindassist._tcp.local."
    mdns_service_name: str = "BlindAssistantDev"
    mdns_enabled: bool = True  # overridden to False when environment != "development"

    # Database
    database_url: str = "sqlite+aiosqlite:///./blind_assistant.db"

    # Security & Secrets (Admin / Maintenance only — mobile app is anonymous/session-based)
    jwt_secret: Optional[str] = None
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 60 * 24
    admin_api_key: Optional[str] = None

    # CORS configuration
    cors_origins: List[str] = ["*"]

    # Request size guards (prevents memory exhaustion from oversized payloads)
    max_image_payload_bytes: int = 10 * 1024 * 1024  # 10 MB limit
    max_image_dimension: int = 4096

    # Per-stage toggle: False = mock implementation, True = real model
    use_real_models: Dict[str, bool] = {
        "detector": True,           # YOLOv11 — real
        "tracker": True,            # ByteTrack — real
        "depth_estimator": True,    # Depth Anything V2 — real
        "scene_describer": True,    # BLIP / Florence-2 — real
        "open_vocab_locator": True, # YOLO-World — real
        "ocr_reader": True,         # RapidOCR (PP-OCRv4) — real
        "segmenter": True,          # YOLOv11n-seg — real
        "speech_to_text": False,    # Whisper (on-device preferred for mobile)
        "text_to_speech": False,    # Piper (on-device preferred for mobile)
    }

    # Decision engine thresholds
    obstacle_warn_distance_m: float = 2.0
    obstacle_urgent_distance_m: float = 0.8
    frame_process_interval_s: float = 0.3  # throttle processing rate

    @model_validator(mode="after")
    def validate_production_security(self) -> "Settings":
        if self.environment == "production":
            if not self.jwt_secret or self.jwt_secret == "change-me-in-production" or len(self.jwt_secret) < 32:
                raise ValueError(
                    "CRITICAL SECURITY CONFIGURATION ERROR: In production, JWT_SECRET must be set "
                    "via environment variables to a high-entropy secret of at least 32 characters."
                )
            if "*" in self.cors_origins:
                raise ValueError(
                    "CRITICAL SECURITY CONFIGURATION ERROR: Wildcard CORS ('*') is forbidden in production. "
                    "Configure explicit origins via CORS_ORIGINS."
                )
            if self.admin_api_key and len(self.admin_api_key) < 16:
                raise ValueError(
                    "CRITICAL SECURITY CONFIGURATION ERROR: In production, ADMIN_API_KEY must be at least 16 characters."
                )
            # mDNS advertisement must never run in production
            object.__setattr__(self, "mdns_enabled", False)
        elif not self.jwt_secret:
            # Safe developmental fallback with explicit warning
            self.jwt_secret = "dev-insecure-secret-key-32chars-min-length-only!"
            logger.warning("Using ephemeral developmental JWT secret. Set JWT_SECRET in production.")
        return self

    @property
    def is_development(self) -> bool:
        return self.environment == "development"


settings = Settings()
