from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.core.logging_config import logger
from app.api.routes import router as api_router
from app.api.websocket import router as ws_router
from app.services.mdns_publisher import MdnsPublisher

# Module-level publisher instance so lifespan can stop it cleanly.
_mdns_publisher: MdnsPublisher | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _mdns_publisher
    logger.info(f"{settings.app_name} backend starting up (env={settings.environment})")

    # Warm up the detector so the FIRST live request isn't slow
    try:
        import numpy as np
        from app.pipeline.factory import pipeline
        dummy_frame = np.zeros((480, 640, 3), dtype=np.uint8)
        await pipeline.detector.detect(dummy_frame)
        logger.info("Detector warmed up")
    except Exception as e:
        logger.warning(f"Detector warmup skipped: {e}")

    # Advertise via mDNS only in development — never in production
    if settings.is_development and settings.mdns_enabled:
        _mdns_publisher = MdnsPublisher(
            service_type=settings.mdns_service_type,
            service_name=settings.mdns_service_name,
            port=settings.bind_port,
        )
        _mdns_publisher.start()
        logger.info(
            f"Backend LAN address: http://{_mdns_publisher.lan_ip}:{settings.bind_port}"
        )
    else:
        logger.info("mDNS advertisement disabled (non-development environment or mdns_enabled=False)")

    yield

    # --- Shutdown ---
    if _mdns_publisher is not None:
        _mdns_publisher.stop()
    logger.info(f"{settings.app_name} backend shutting down")


app = FastAPI(
    title=settings.app_name,
    description="Object detection, scene understanding, and voice-guided "
                 "navigation assistant for blind and low-vision users.",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(api_router, prefix=settings.api_v1_prefix, tags=["api"])
app.include_router(ws_router, tags=["websocket"])


@app.get("/")
async def root():
    return {"app": settings.app_name, "docs": "/docs"}


@app.get("/ping")
async def ping():
    """
    Ultra-lightweight health probe — does NOT trigger model loading.
    Used by the Android connection manager to validate reachability before
    attempting a full session.  Returns 200 immediately on any request.
    """
    return {"status": "ok"}
