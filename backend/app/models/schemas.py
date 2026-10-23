"""
Core data contracts. Every AI component consumes/produces these shapes,
so a real model implementation just needs to fill them in correctly —
nothing downstream needs to know it's not a mock anymore.
"""
from __future__ import annotations
from pydantic import BaseModel, Field
from typing import List, Optional
from enum import Enum
import time


class BoundingBox(BaseModel):
    x1: float
    y1: float
    x2: float
    y2: float


class Detection(BaseModel):
    track_id: Optional[int] = None
    label: str
    confidence: float
    bbox: BoundingBox
    distance_m: Optional[float] = None       # from DepthEstimator (relative proxy)
    direction: Optional[str] = None          # "left" | "center" | "right"
    in_path: Optional[bool] = None           # True if intersecting walking corridor
    risk_level: Optional[str] = None         # "imminent" | "potential" | "awareness" | "negligible"
    proximity_band: Optional[str] = None     # "immediate" | "near" | "mid" | "far" | "unknown"


class SceneDescription(BaseModel):
    caption: str
    tags: List[str] = Field(default_factory=list)


class OCRResult(BaseModel):
    text: str
    bbox: BoundingBox
    confidence: float


class TranscriptResult(BaseModel):
    text: str
    confidence: float
    language: str = "en"


class UrgencyLevel(str, Enum):
    info = "info"
    warn = "warn"
    urgent = "urgent"


class GuidanceMessage(BaseModel):
    """What ultimately gets spoken to the user."""
    text: str
    urgency: UrgencyLevel
    timestamp: float = Field(default_factory=time.time)
    related_detections: List[Detection] = Field(default_factory=list)
    is_degraded: bool = False


class FrameAnalysis(BaseModel):
    """Full output of one processed camera frame — the pipeline's result."""
    session_id: str
    frame_id: int
    detections: List[Detection] = Field(default_factory=list)
    scene: Optional[SceneDescription] = None
    ocr_results: List[OCRResult] = Field(default_factory=list)
    guidance: List[GuidanceMessage] = Field(default_factory=list)
    processing_time_ms: float = 0.0


class ImageFrameRequest(BaseModel):
    image_base64: str


class FindObjectRequest(BaseModel):
    image_base64: str
    query: str


class VoiceCommandRequest(BaseModel):
    session_id: str
    audio_base64: str


class VoiceCommandResponse(BaseModel):
    transcript: TranscriptResult
    action: str          # e.g. "describe_scene", "read_text", "find_object"
    guidance: GuidanceMessage
