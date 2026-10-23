"""
Real object detector using YOLOv11 (via the ultralytics package).
Implements the same Detector interface as MockDetector — nothing else
in the app needs to change to use this.

Model weights (yolo11n.pt, ~5MB) auto-download from Ultralytics/GitHub
on first run and are cached locally afterward (~/.cache or the project
dir, wherever ultralytics puts it — no action needed from you).
"""
import asyncio
import numpy as np
from typing import List

from ultralytics import YOLO

from app.pipeline.interfaces import Detector
from app.models.schemas import Detection, BoundingBox
from app.core.logging_config import logger

# COCO class names YOLOv11 recognizes that are relevant obstacles for
# navigation. Everything else it detects (e.g. "kite", "toaster") is
# filtered out below — a blind-navigation assistant doesn't need to
# announce unrelated objects.
RELEVANT_CLASSES = {
    "person", "bicycle", "car", "motorcycle", "bus", "train", "truck",
    "traffic light", "fire hydrant", "stop sign", "bench", "backpack",
    "umbrella", "handbag", "suitcase", "chair", "couch", "potted plant",
    "bed", "dining table", "toilet", "tv", "laptop", "microwave",
    "oven", "sink", "refrigerator", "book", "dog", "cat",
}


class YoloDetector(Detector):
    def __init__(self, model_path: str = "yolo11n.pt", confidence_threshold: float = 0.4):
        logger.info(f"Loading YOLOv11 model: {model_path}")
        self.model = YOLO(model_path)
        self.confidence_threshold = confidence_threshold
        logger.info("YOLOv11 model loaded successfully")

    async def detect(self, frame: np.ndarray) -> List[Detection]:
        # ultralytics inference is CPU/GPU-bound sync work; run it in a
        # thread so it doesn't block the FastAPI event loop.
        results = await asyncio.to_thread(
            self.model, frame, verbose=False, conf=self.confidence_threshold
        )

        detections: List[Detection] = []
        for r in results:
            for box in r.boxes:
                label = self.model.names[int(box.cls[0])]
                if label not in RELEVANT_CLASSES:
                    continue
                x1, y1, x2, y2 = box.xyxy[0].tolist()
                detections.append(Detection(
                    label=label,
                    confidence=round(float(box.conf[0]), 2),
                    bbox=BoundingBox(x1=x1, y1=y1, x2=x2, y2=y2),
                ))
        return detections
