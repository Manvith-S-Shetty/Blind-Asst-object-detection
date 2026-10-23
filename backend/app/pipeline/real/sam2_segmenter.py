"""
Real instance segmentation and free-space candidate estimation using YOLOv11n-seg (AGPL-3.0).
Provides pixel-level obstacle masks mapped directly to camera image dimensions (H, W)
and estimates tentative free space in the navigable forward corridor.

SAFETY GUARANTEE:
Perception cannot prove a path is safe to walk. Segmentation results identify detected
obstacle boundaries only; transparent glass, drop-offs, hanging obstacles, or unmodeled
hazards may still be present. Free-space ratio is an unverified proxy.
"""
import asyncio
from typing import List, Dict, Any, Optional
import numpy as np
import cv2
from ultralytics import YOLO

from app.pipeline.interfaces import Segmenter
from app.models.schemas import Detection
from app.core.logging_config import logger


class SAM2Segmenter(Segmenter):
    """Real segmenter and forward corridor candidate estimator."""

    def __init__(self, model_path: str = "yolo11n-seg.pt", conf_thresh: float = 0.35):
        logger.info(f"Loading segmentation model: {model_path}")
        self.model = YOLO(model_path)
        self.conf_thresh = conf_thresh
        logger.info("Segmentation model loaded successfully")

    def _infer_sync(self, frame: np.ndarray) -> Any:
        return self.model(frame, verbose=False, conf=self.conf_thresh)

    async def segment(self, frame: np.ndarray, detections: List[Detection]) -> np.ndarray:
        """Returns an integer mask array of shape (H, W) where 0 is background/unclassified,
        and (i + 1) corresponds to the i-th detection's segmented obstacle footprint.
        """
        if frame is None or frame.size == 0 or frame.ndim != 3:
            logger.warning("Segmenter rejected frame: invalid shape or empty")
            return np.zeros((0, 0), dtype=np.uint8)

        h, w = frame.shape[0], frame.shape[1]
        mask = np.zeros((h, w), dtype=np.uint8)

        if not detections:
            return mask

        try:
            results = await asyncio.to_thread(self._infer_sync, frame)
            r = results[0]

            if r.masks is not None and len(r.masks) > 0:
                # Resize and map masks to frame (h, w)
                seg_masks = r.masks.data.cpu().numpy()  # (N, mh, mw)
                seg_boxes = r.boxes.xyxy.cpu().numpy()  # (N, 4)

                for i, det in enumerate(detections):
                    det_box = np.array([det.bbox.x1, det.bbox.y1, det.bbox.x2, det.bbox.y2])
                    # Find matching predicted mask via bounding box IoU
                    best_match = -1
                    best_iou = 0.3  # minimum IoU overlap threshold

                    for m_idx, sb in enumerate(seg_boxes):
                        xA = max(det_box[0], sb[0])
                        yA = max(det_box[1], sb[1])
                        xB = min(det_box[2], sb[2])
                        yB = min(det_box[3], sb[3])
                        interArea = max(0.0, xB - xA) * max(0.0, yB - yA)
                        boxAArea = (det_box[2] - det_box[0]) * (det_box[3] - det_box[1])
                        boxBArea = (sb[2] - sb[0]) * (sb[3] - sb[1])
                        iou = interArea / float(boxAArea + boxBArea - interArea + 1e-6)
                        if iou > best_iou:
                            best_iou = iou
                            best_match = m_idx

                    if best_match >= 0:
                        raw_mask = seg_masks[best_match]
                        resized_mask = cv2.resize(raw_mask, (w, h), interpolation=cv2.INTER_NEAREST)
                        mask[resized_mask > 0.5] = i + 1
                    else:
                        # Fallback to bounded rectangle if mask not extracted
                        x1 = int(np.clip(det.bbox.x1, 0, w - 1))
                        y1 = int(np.clip(det.bbox.y1, 0, h - 1))
                        x2 = int(np.clip(det.bbox.x2, x1 + 1, w))
                        y2 = int(np.clip(det.bbox.y2, y1 + 1, h))
                        mask[y1:y2, x1:x2] = i + 1
            else:
                # No instance masks detected; fill bounding boxes
                for i, det in enumerate(detections):
                    x1 = int(np.clip(det.bbox.x1, 0, w - 1))
                    y1 = int(np.clip(det.bbox.y1, 0, h - 1))
                    x2 = int(np.clip(det.bbox.x2, x1 + 1, w))
                    y2 = int(np.clip(det.bbox.y2, y1 + 1, h))
                    mask[y1:y2, x1:x2] = i + 1

        except Exception as e:
            logger.error(f"Segmentation inference error: {e}", exc_info=True)
            # Safe fallback: fill bounding boxes without crashing
            for i, det in enumerate(detections):
                x1 = int(np.clip(det.bbox.x1, 0, w - 1))
                y1 = int(np.clip(det.bbox.y1, 0, h - 1))
                x2 = int(np.clip(det.bbox.x2, x1 + 1, w))
                y2 = int(np.clip(det.bbox.y2, y1 + 1, h))
                mask[y1:y2, x1:x2] = i + 1

        return mask

    async def compute_corridor_occupancy(
        self, frame: np.ndarray, detections: List[Detection]
    ) -> Dict[str, Any]:
        """Calculates obstacle occupancy in the critical forward walking corridor
        (lower 40% of the image, central 50% width).
        """
        if frame is None or frame.size == 0 or frame.ndim != 3:
            return {
                "corridor_clear": False,
                "occupied_ratio": 1.0,
                "uncertain": True,
                "warning": "Invalid frame for corridor estimation",
            }

        mask = await self.segment(frame, detections)
        h, w = mask.shape
        # Corridor: lower 40% (y from 0.6*h to h), center 50% (x from 0.25*w to 0.75*w)
        y_start = int(0.6 * h)
        x_start = int(0.25 * w)
        x_end = int(0.75 * w)

        corridor = mask[y_start:h, x_start:x_end]
        total_pixels = corridor.size
        if total_pixels == 0:
            return {"corridor_clear": False, "occupied_ratio": 1.0, "uncertain": True}

        occupied_pixels = int(np.count_nonzero(corridor))
        occupied_ratio = round(float(occupied_pixels) / float(total_pixels), 3)

        return {
            "corridor_clear": occupied_ratio < 0.05,
            "occupied_ratio": occupied_ratio,
            "uncertain": False,
            "safety_disclaimer": "Corridor clear indicates no detected obstacles in corridor zone; does not guarantee path safety.",
        }
