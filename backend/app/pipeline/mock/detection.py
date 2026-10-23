"""
Mock Detector + Tracker. Produces realistic, varying detections from a
frame's pixel statistics (deterministic per-frame, not random noise) so
demos look consistent frame-to-frame rather than flickering nonsense.

Swap for real: app/pipeline/real/yolo_detector.py implementing Detector
via `ultralytics.YOLO("yolo11n.pt")`, and ByteTrack for Tracker.
"""
import numpy as np
from typing import List, Dict
import hashlib

from app.pipeline.interfaces import Detector, Tracker
from app.models.schemas import Detection, BoundingBox

COMMON_OBSTACLES = [
    "person", "chair", "table", "door", "stairs", "pole",
    "bicycle", "car", "trash can", "curb", "bench",
]


class MockDetector(Detector):
    async def detect(self, frame: np.ndarray) -> List[Detection]:
        h, w = frame.shape[0], frame.shape[1]
        # Derive a stable "seed" from frame content so repeated frames
        # give repeated (not random) detections — mimics real inference.
        seed = int(hashlib.md5(frame.tobytes()[:2048]).hexdigest(), 16) % (2**32)
        rng = np.random.default_rng(seed)

        n_objects = rng.integers(1, 4)
        detections = []
        for i in range(n_objects):
            label = COMMON_OBSTACLES[rng.integers(0, len(COMMON_OBSTACLES))]
            bw, bh = rng.uniform(0.1, 0.35) * w, rng.uniform(0.15, 0.5) * h
            x1 = rng.uniform(0, w - bw)
            y1 = rng.uniform(0, h - bh)
            detections.append(Detection(
                label=label,
                confidence=round(float(rng.uniform(0.55, 0.97)), 2),
                bbox=BoundingBox(x1=x1, y1=y1, x2=x1 + bw, y2=y1 + bh),
            ))
        return detections


class MockTracker(Tracker):
    """Assigns stable-ish track IDs by matching label + rough position
    against the previous frame, similar in spirit to ByteTrack's IOU match."""

    def __init__(self):
        self._next_id = 1
        self._prev: List[Detection] = []

    async def update(self, detections: List[Detection]) -> List[Detection]:
        for det in detections:
            match = self._find_match(det)
            det.track_id = match.track_id if match else self._assign_new_id()
        self._prev = detections
        return detections

    def _find_match(self, det: Detection):
        for prev in self._prev:
            if prev.label != det.label:
                continue
            if self._center_distance(prev.bbox, det.bbox) < 80:
                return prev
        return None

    @staticmethod
    def _center_distance(a: BoundingBox, b: BoundingBox) -> float:
        ax, ay = (a.x1 + a.x2) / 2, (a.y1 + a.y2) / 2
        bx, by = (b.x1 + b.x2) / 2, (b.y1 + b.y2) / 2
        return ((ax - bx) ** 2 + (ay - by) ** 2) ** 0.5

    def _assign_new_id(self) -> int:
        tid = self._next_id
        self._next_id += 1
        return tid
