"""
Live navigation stream. Mobile app sends base64 JPEG frames as they're
captured; server responds with structured guidance in near-real-time.
This is the primary interface the Flutter app should use (lower latency,
lower overhead than per-frame REST calls).
"""
import base64
import io
import json
import time

import numpy as np
from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from PIL import Image

from app.pipeline.factory import pipeline, ModelUnavailableError
from app.services.session_manager import session_manager
from app.core.config import settings
from app.core.logging_config import logger

router = APIRouter()


@router.websocket("/ws/navigate/{session_id}")
async def navigate_stream(websocket: WebSocket, session_id: str):
    await websocket.accept()
    session = session_manager.get_or_create(session_id)
    logger.info(f"WebSocket session started: {session_id}")

    last_processed = 0.0
    try:
        while True:
            raw = await websocket.receive_text()

            # Throttle: don't run full inference on every single frame if
            # the client is sending faster than frame_process_interval_s.
            now = time.time()
            if now - last_processed < settings.frame_process_interval_s:
                continue
            last_processed = now

            try:
                payload = json.loads(raw)
                image_b64 = payload["image_base64"]
                client_timestamp_ms = payload.get("client_timestamp_ms")
                frame_seq = payload.get("frame_seq")
            except (json.JSONDecodeError, KeyError, TypeError):
                await websocket.send_json({"error": "invalid_payload", "detail": "expected JSON with 'image_base64'"})
                continue
            if len(image_b64) > int(settings.max_image_payload_bytes * 1.4):
                logger.warning(f"Oversized frame payload received in session {session_id}")
                await websocket.send_json({
                    "error": "payload_too_large",
                    "detail": f"Image frame exceeds maximum limit of {settings.max_image_payload_bytes} bytes."
                })
                continue

            t_start = time.perf_counter()

            try:
                img_bytes = base64.b64decode(image_b64)
                img = Image.open(io.BytesIO(img_bytes)).convert("RGB")
                if img.width > settings.max_image_dimension or img.height > settings.max_image_dimension:
                    logger.warning(f"Oversized frame dimensions received in session {session_id}: {img.width}x{img.height}")
                    await websocket.send_json({
                        "error": "image_dimension_too_large",
                        "detail": f"Image dimensions ({img.width}x{img.height}) exceed maximum allowed ({settings.max_image_dimension}px)."
                    })
                    continue
                frame = np.array(img)
            except Exception as e:
                logger.warning(f"Malformed image data received in session {session_id}: {e}")
                await websocket.send_json({"error": "invalid_image_data", "detail": str(e)})
                continue

            try:
                detections = await pipeline.detector.detect(frame)
                detections = await pipeline.tracker.update(detections)
                detections = await pipeline.depth_estimator.estimate(frame, detections)
                h, w = frame.shape[0], frame.shape[1]
                guidance = session.decision_engine.generate_guidance(detections, frame_width=w, frame_height=h)
            except ModelUnavailableError as e:
                logger.error(f"Model unavailable in session {session_id}: {e}")
                await websocket.send_json({
                    "session_id": session_id,
                    "error": "model_unavailable",
                    "component": e.component_key,
                    "detail": e.reason,
                    "detections": [],
                    "guidance": [],
                })
                continue
            except Exception as e:
                logger.error(f"Inference error in session {session_id}: {e}", exc_info=True)
                await websocket.send_json({
                    "session_id": session_id,
                    "error": "inference_error",
                    "detail": str(e),
                    "detections": [],
                    "guidance": [],
                })
                continue

            proc_ms = round((time.perf_counter() - t_start) * 1000, 2)
            session.frame_count += 1
            resp_payload = {
                "session_id": session_id,
                "frame_id": session.frame_count,
                "detections": [d.model_dump() for d in detections],
                "guidance": [g.model_dump() for g in guidance],
                "processing_time_ms": proc_ms,
            }
            if client_timestamp_ms is not None:
                resp_payload["client_timestamp_ms"] = client_timestamp_ms
            if frame_seq is not None:
                resp_payload["frame_seq"] = frame_seq

            await websocket.send_json(resp_payload)

    except WebSocketDisconnect:
        logger.info(f"WebSocket session ended: {session_id}")
        session_manager.remove(session_id)
