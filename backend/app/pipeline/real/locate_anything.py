import gc
import numpy as np
from typing import List, Optional
from ultralytics import YOLO

from app.pipeline.interfaces import OpenVocabLocator
from app.models.schemas import Detection, BoundingBox
from app.core.logging_config import logger


class LocateAnythingLocator(OpenVocabLocator):
    """
    Open-vocabulary object locator using YOLO-World (yolov8s-worldv2.pt)
    with CLIP text conditioning (AGPL-3.0 license).
    Supports free-text queries, lazy loading on first demand, and explicit unload()
    to release memory when idle.
    """
    def __init__(self, model_path: str = "yolov8s-worldv2.pt", confidence_threshold: float = 0.25, lazy_load: bool = True):
        self.model_path = model_path
        self.confidence_threshold = confidence_threshold
        self._model: Optional[YOLO] = None
        if not lazy_load:
            self._ensure_loaded()

    def _ensure_loaded(self):
        if self._model is not None:
            return
        try:
            logger.info(f"Loading YOLO-World open-vocabulary model: {self.model_path}...")
            self._model = YOLO(self.model_path)
            logger.info("LocateAnythingLocator loaded successfully.")
        except Exception as e:
            logger.error(f"Failed to load YOLO-World model '{self.model_path}': {e}", exc_info=True)
            raise RuntimeError(f"YOLO-World initialization failed: {e}")

    def unload(self):
        """Releases model weights and frees system RAM."""
        if self._model is not None:
            logger.info("Unloading LocateAnythingLocator to reclaim system memory.")
            self._model = None
            gc.collect()

    async def locate(self, frame: np.ndarray, query: str) -> List[Detection]:
        if frame is None or not isinstance(frame, np.ndarray) or frame.size == 0:
            return []

        clean_query = query.strip().lower()
        if not clean_query:
            return []

        # Expand common synonyms to maximize recall while staying accurate
        search_classes = [clean_query]
        synonym_map = {
            "bag": ["bag", "backpack", "handbag", "purse"],
            "backpack": ["backpack", "bag", "handbag"],
            "bottle": ["bottle", "water bottle", "flask"],
            "keys": ["keys", "keychain", "car keys"],
            "phone": ["cell phone", "phone", "mobile phone"],
            "cup": ["cup", "mug", "coffee cup"],
            "chair": ["chair", "seat", "couch"],
            "glasses": ["glasses", "sunglasses", "eyeglasses"],
            "laptop": ["laptop", "computer", "notebook"],
        }
        if clean_query in synonym_map:
            search_classes = synonym_map[clean_query]

        try:
            self._ensure_loaded()
            h, w = frame.shape[:2]
            # Set target classes for zero-shot text-conditioned detection
            self._model.set_classes(search_classes)
            results = self._model(frame, verbose=False, conf=self.confidence_threshold)

            matches: List[Detection] = []
            for r in results:
                for box in r.boxes:
                    conf = float(box.conf[0])
                    cls_id = int(box.cls[0])
                    detected_label = self._model.names.get(cls_id, clean_query)

                    coords = box.xyxy[0].tolist()
                    x1 = max(0.0, float(coords[0]))
                    y1 = max(0.0, float(coords[1]))
                    x2 = min(float(w), float(coords[2]))
                    y2 = min(float(h), float(coords[3]))

                    # Determine horizontal direction relative to user camera
                    center_x = (x1 + x2) / 2.0
                    if center_x < w * 0.35:
                        direction = "left"
                    elif center_x > w * 0.65:
                        direction = "right"
                    else:
                        direction = "center"

                    matches.append(
                        Detection(
                            label=detected_label,
                            confidence=round(conf, 3),
                            bbox=BoundingBox(x1=x1, y1=y1, x2=x2, y2=y2),
                            direction=direction,
                        )
                    )

            # Sort matches by highest confidence first
            matches.sort(key=lambda d: d.confidence, reverse=True)
            return matches

        except Exception as e:
            logger.error(f"Error during open-vocabulary object location for query '{query}': {e}", exc_info=True)
            return []
