import base64
import io
import secrets
import time

import numpy as np
from typing import Optional
from fastapi import APIRouter, HTTPException, Header
from PIL import Image

from app.core.config import settings
from app.models.schemas import (
    FrameAnalysis, VoiceCommandRequest, VoiceCommandResponse, GuidanceMessage, UrgencyLevel,
    ImageFrameRequest, FindObjectRequest,
)
from app.pipeline.factory import pipeline, ModelUnavailableError
from app.services.session_manager import session_manager
from app.core.logging_config import logger

router = APIRouter()


@router.get("/health")
async def health():
    return {"status": "ok", "app": "Blind Assistant AI"}


@router.post("/system/trim-memory")
async def trim_memory(x_admin_key: Optional[str] = Header(None)):
    """
    Explicitly releases idle on-demand vision-language models and runs GC.
    Protected by X-Admin-Key if configured or in production environments.
    """
    if settings.admin_api_key:
        if not x_admin_key or not secrets.compare_digest(x_admin_key, settings.admin_api_key):
            raise HTTPException(status_code=403, detail="Unauthorized: invalid or missing admin key.")
    elif settings.environment == "production":
        raise HTTPException(status_code=403, detail="Admin operations disabled in production without admin_api_key.")

    import gc
    if hasattr(pipeline.scene_describer, "unload"):
        pipeline.scene_describer.unload()
    if hasattr(pipeline.open_vocab_locator, "unload"):
        pipeline.open_vocab_locator.unload()
    gc.collect()
    return {"status": "ok", "message": "On-demand model memory trimmed"}


@router.post("/session/start")
async def start_session():
    session = session_manager.create()
    return {"session_id": session.session_id}


@router.post("/session/{session_id}/end")
async def end_session(session_id: str):
    session_manager.remove(session_id)
    return {"status": "ended"}


def _decode_image(image_base64: str) -> np.ndarray:
    if len(image_base64) > int(settings.max_image_payload_bytes * 1.4):
        raise HTTPException(
            status_code=413,
            detail=f"Image payload exceeds maximum limit of {settings.max_image_payload_bytes} bytes."
        )
    try:
        img_bytes = base64.b64decode(image_base64)
        if len(img_bytes) > settings.max_image_payload_bytes:
            raise HTTPException(
                status_code=413,
                detail=f"Decoded image exceeds limit of {settings.max_image_payload_bytes} bytes."
            )
        img = Image.open(io.BytesIO(img_bytes)).convert("RGB")
        if img.width > settings.max_image_dimension or img.height > settings.max_image_dimension:
            raise HTTPException(
                status_code=400,
                detail=f"Image dimensions ({img.width}x{img.height}) exceed maximum allowed ({settings.max_image_dimension}px)."
            )
        return np.array(img)
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid image data")


@router.post("/session/{session_id}/frame", response_model=FrameAnalysis)
async def analyze_frame(session_id: str, body: ImageFrameRequest):
    """One-shot frame analysis over REST (for clients not using the
    WebSocket stream — e.g. testing from the docs UI)."""
    start = time.time()
    session = session_manager.get_or_create(session_id)
    frame = _decode_image(body.image_base64)

    try:
        detections = await pipeline.detector.detect(frame)
        detections = await pipeline.tracker.update(detections)
        detections = await pipeline.depth_estimator.estimate(frame, detections)
        h, w = frame.shape[0], frame.shape[1]
        guidance = session.decision_engine.generate_guidance(detections, frame_width=w, frame_height=h)
    except ModelUnavailableError as e:
        logger.error(f"Model unavailable in analyze_frame: {e}")
        raise HTTPException(status_code=503, detail=f"Model unavailable: {e.component_key} - {e.reason}")
    except Exception as e:
        logger.error(f"Inference error in analyze_frame: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Inference error: {str(e)}")

    session.frame_count += 1
    return FrameAnalysis(
        session_id=session_id,
        frame_id=session.frame_count,
        detections=detections,
        guidance=guidance,
        processing_time_ms=round((time.time() - start) * 1000, 1),
    )


@router.post("/session/{session_id}/describe-scene")
async def describe_scene(session_id: str, body: ImageFrameRequest):
    frame = _decode_image(body.image_base64)
    try:
        scene = await pipeline.scene_describer.describe(frame)
        return scene
    except ModelUnavailableError as e:
        logger.error(f"Scene describer unavailable: {e}")
        raise HTTPException(status_code=503, detail=f"Scene describer unavailable: {e.reason}")
    except Exception as e:
        logger.error(f"Error in describe_scene: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Scene description error: {str(e)}")


@router.post("/session/{session_id}/read-text")
async def read_text(session_id: str, body: ImageFrameRequest):
    frame = _decode_image(body.image_base64)
    try:
        results = await pipeline.ocr_reader.read_text(frame)
        extracted_text = " ".join([r.text for r in results]) if results else ""
        return {
            "results": results,
            "extracted_text": extracted_text,
            "count": len(results),
        }
    except ModelUnavailableError as e:
        logger.error(f"OCR reader unavailable: {e}")
        raise HTTPException(status_code=503, detail=f"OCR reader unavailable: {e.reason}")
    except Exception as e:
        logger.error(f"Error in read_text: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"OCR error: {str(e)}")


@router.post("/session/{session_id}/find-object")
async def find_object(session_id: str, body: FindObjectRequest):
    query_clean = body.query.strip()
    if not query_clean:
        raise HTTPException(status_code=400, detail="Search query cannot be empty.")

    frame = _decode_image(body.image_base64)
    try:
        matches = await pipeline.open_vocab_locator.locate(frame, query_clean)
    except ModelUnavailableError as e:
        logger.error(f"Locator unavailable: {e}")
        raise HTTPException(status_code=503, detail=f"Object locator unavailable: {e.reason}")
    except Exception as e:
        logger.error(f"Error in find_object: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Object location error: {str(e)}")

    if matches:
        first = matches[0]
        dir_hint = f"to your {first.direction}" if first.direction in ("left", "right") else "directly ahead"
        message = f"Found {query_clean} {dir_hint}."
        status = "found"
    else:
        message = f"{query_clean} is not currently detected in the camera view."
        status = "not_detected"

    return {
        "status": status,
        "query": query_clean,
        "matches": matches,
        "message": message,
    }


def route_voice_intent(raw_text: str) -> tuple[str, str, str]:
    """
    Parses spoken voice command into (action, target_query, confirmation_speech).
    Actions: 'read_text', 'find_object', 'describe_scene', 'unknown'
    """
    text = raw_text.strip().lower()
    if not text:
        return "unknown", "", "I did not detect any speech. Please try again."

    if any(k in text for k in ["read", "text", "sign", "words", "label"]):
        return "read_text", "", "Okay, reading text in view."

    if any(k in text for k in ["find", "locate", "where is", "search for", "look for"]):
        # Extract target object by stripping command words
        target = text
        for prefix in ["find my", "find a", "find", "locate my", "locate a", "locate", "where is my", "where is a", "where is", "search for", "look for"]:
            if target.startswith(prefix):
                target = target[len(prefix):].strip()
                break
        target = target.rstrip(".?!").strip()
        if not target:
            target = "object"
        return "find_object", target, f"Searching for {target}."

    if any(k in text for k in ["describe", "what do you see", "what's around", "what is around", "what is in front", "scene"]):
        return "describe_scene", "", "Okay, describing the scene."

    return "unknown", "", "I can read text, describe the scene, or find an object. Try saying 'describe the scene' or 'find my bag'."


@router.post("/voice-command", response_model=VoiceCommandResponse)
async def voice_command(req: VoiceCommandRequest):
    audio_bytes = base64.b64decode(req.audio_base64)
    transcript = await pipeline.speech_to_text.transcribe(audio_bytes)

    action, _, confirmation_text = route_voice_intent(transcript.text)

    guidance = GuidanceMessage(
        text=confirmation_text,
        urgency=UrgencyLevel.info,
    )
    logger.info(f"Voice command routed to action={action} (transcript='{transcript.text}')")
    return VoiceCommandResponse(transcript=transcript, action=action, guidance=guidance)

