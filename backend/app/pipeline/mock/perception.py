"""
Mock DepthEstimator, SceneDescriber, OpenVocabLocator, OCRReader, Segmenter.

Swap for real:
  DepthEstimator     -> Depth Anything V2 (HF transformers pipeline)
  SceneDescriber     -> Florence-2 Base
  OpenVocabLocator   -> NVIDIA Locate Anything-3B
  OCRReader          -> PaddleOCR
  Segmenter          -> SAM2 / FastSAM
"""
import numpy as np
from typing import List

from app.pipeline.interfaces import (
    DepthEstimator, SceneDescriber, OpenVocabLocator, OCRReader, Segmenter,
)
from app.models.schemas import Detection, SceneDescription, OCRResult, BoundingBox


class MockDepthEstimator(DepthEstimator):
    async def estimate(self, frame: np.ndarray, detections: List[Detection]) -> List[Detection]:
        h = frame.shape[0]
        for det in detections:
            # Larger / lower-in-frame bbox => closer object (rough heuristic,
            # same signal a real monocular depth model correlates with).
            bbox_h = det.bbox.y2 - det.bbox.y1
            bottom_y = det.bbox.y2
            size_factor = bbox_h / h
            position_factor = bottom_y / h
            closeness = (size_factor * 0.6 + position_factor * 0.4)
            det.distance_m = round(max(0.3, 6.0 * (1 - closeness)), 1)

            center_x = (det.bbox.x1 + det.bbox.x2) / 2
            frame_w = frame.shape[1]
            if center_x < frame_w * 0.4:
                det.direction = "left"
            elif center_x > frame_w * 0.6:
                det.direction = "right"
            else:
                det.direction = "center"
        return detections


class MockSceneDescriber(SceneDescriber):
    async def describe(self, frame: np.ndarray) -> SceneDescription:
        brightness = float(np.mean(frame))
        setting = "an indoor space" if brightness < 140 else "a bright outdoor or well-lit area"
        return SceneDescription(
            caption=f"You appear to be in {setting}.",
            tags=["indoor" if brightness < 140 else "outdoor"],
        )


class MockOpenVocabLocator(OpenVocabLocator):
    async def locate(self, frame: np.ndarray, query: str) -> List[Detection]:
        h, w = frame.shape[0], frame.shape[1]
        # Deterministic placeholder "found it" result near frame center.
        bw, bh = w * 0.2, h * 0.25
        x1, y1 = w * 0.4, h * 0.35
        return [Detection(
            label=query,
            confidence=0.72,
            bbox=BoundingBox(x1=x1, y1=y1, x2=x1 + bw, y2=y1 + bh),
        )]


class MockOCRReader(OCRReader):
    async def read_text(self, frame: np.ndarray) -> List[OCRResult]:
        h, w = frame.shape[0], frame.shape[1]
        return [OCRResult(
            text="Sample detected text",
            bbox=BoundingBox(x1=w * 0.1, y1=h * 0.1, x2=w * 0.5, y2=h * 0.2),
            confidence=0.88,
        )]


class MockSegmenter(Segmenter):
    async def segment(self, frame: np.ndarray, detections: List[Detection]) -> np.ndarray:
        h, w = frame.shape[0], frame.shape[1]
        mask = np.zeros((h, w), dtype=np.uint8)
        for i, det in enumerate(detections):
            x1, y1, x2, y2 = map(int, [det.bbox.x1, det.bbox.y1, det.bbox.x2, det.bbox.y2])
            mask[max(0, y1):y2, max(0, x1):x2] = i + 1
        return mask
