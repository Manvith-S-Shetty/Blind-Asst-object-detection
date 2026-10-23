"""
One abstract interface per model in the stack. A "real" implementation
(YOLOv11 via ultralytics, Depth Anything V2 via HF transformers, etc.)
just needs to subclass the matching interface and return the same
Pydantic schema — the rest of the system never has to change.
"""
from abc import ABC, abstractmethod
from typing import List
import numpy as np

from app.models.schemas import (
    Detection, SceneDescription, OCRResult, TranscriptResult,
)


class Detector(ABC):
    """Object detection — real impl: YOLOv11."""
    @abstractmethod
    async def detect(self, frame: np.ndarray) -> List[Detection]:
        ...


class Tracker(ABC):
    """Multi-object tracking across frames — real impl: ByteTrack."""
    @abstractmethod
    async def update(self, detections: List[Detection]) -> List[Detection]:
        ...


class DepthEstimator(ABC):
    """Monocular depth estimation — real impl: Depth Anything V2."""
    @abstractmethod
    async def estimate(self, frame: np.ndarray, detections: List[Detection]) -> List[Detection]:
        """Returns detections annotated with distance_m."""
        ...


class SceneDescriber(ABC):
    """Whole-scene captioning — real impl: Florence-2 Base."""
    @abstractmethod
    async def describe(self, frame: np.ndarray) -> SceneDescription:
        ...


class OpenVocabLocator(ABC):
    """Free-text object search, e.g. 'find my keys' — real impl: NVIDIA Locate Anything-3B."""
    @abstractmethod
    async def locate(self, frame: np.ndarray, query: str) -> List[Detection]:
        ...


class OCRReader(ABC):
    """Text reading — real impl: PaddleOCR."""
    @abstractmethod
    async def read_text(self, frame: np.ndarray) -> List[OCRResult]:
        ...


class Segmenter(ABC):
    """Instance/region segmentation — real impl: SAM2 / FastSAM."""
    @abstractmethod
    async def segment(self, frame: np.ndarray, detections: List[Detection]) -> np.ndarray:
        """Returns a mask array aligned with detections."""
        ...


class SpeechToText(ABC):
    """Voice command transcription — real impl: Whisper Large-v3."""
    @abstractmethod
    async def transcribe(self, audio_bytes: bytes) -> TranscriptResult:
        ...


class TextToSpeech(ABC):
    """Spoken guidance output — real impl: Piper TTS."""
    @abstractmethod
    async def synthesize(self, text: str) -> bytes:
        """Returns audio bytes (e.g. WAV)."""
        ...
