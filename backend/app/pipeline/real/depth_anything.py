"""
Real monocular depth estimator using Depth Anything V2 Small (Apache-2.0).
Provides dense relative disparity/depth estimation and annotates detections
with estimated relative proximity proxy and horizontal direction.

SAFETY NOTE:
Monocular depth provides relative inverse depth (disparity), not calibrated metric
distance. Unless calibrated with known camera intrinsics/stereo sensors, distance_m
is a relative estimation proxy and should be treated with appropriate uncertainty.
"""
import asyncio
from typing import List, Optional
import numpy as np
import torch
from PIL import Image
from transformers import AutoImageProcessor, AutoModelForDepthEstimation

from app.pipeline.interfaces import DepthEstimator
from app.models.schemas import Detection
from app.core.logging_config import logger


class DepthAnythingEstimator(DepthEstimator):
    def __init__(
        self,
        model_id: str = "depth-anything/Depth-Anything-V2-Small-hf",
        input_size: int = 252,
    ):
        logger.info(f"Loading Depth Anything V2 model: {model_id}")
        self.model_id = model_id
        self.input_size = input_size
        self.processor = AutoImageProcessor.from_pretrained(
            model_id, size={"height": input_size, "width": input_size}
        )
        self.model = AutoModelForDepthEstimation.from_pretrained(model_id)
        self.model.eval()
        logger.info("Depth Anything V2 loaded successfully")

    def _infer_depth_map(self, frame: np.ndarray) -> Optional[np.ndarray]:
        """Runs synchronous inference and returns full-resolution relative depth map."""
        if frame is None or frame.size == 0 or frame.ndim != 3:
            logger.warning("Depth inference rejected: frame is empty or invalid shape")
            return None

        h, w, c = frame.shape
        if h < 10 or w < 10:
            logger.warning("Depth inference rejected: frame dimensions too small (< 10px)")
            return None

        try:
            pil_img = Image.fromarray(frame)
            inputs = self.processor(images=pil_img, return_tensors="pt")

            with torch.no_grad():
                outputs = self.model(**inputs)

            # Interpolate predicted depth to original frame dimensions
            pred_depth = outputs.predicted_depth.unsqueeze(1)
            depth_map = torch.nn.functional.interpolate(
                pred_depth,
                size=(h, w),
                mode="bilinear",
                align_corners=False,
            ).squeeze().cpu().numpy()

            if np.isnan(depth_map).any() or np.isinf(depth_map).any():
                logger.warning("Depth map contains NaN/inf values; discarding")
                return None

            return depth_map
        except Exception as e:
            logger.error(f"Depth inference failed: {e}", exc_info=True)
            return None

    async def estimate_depth_map(self, frame: np.ndarray) -> Optional[np.ndarray]:
        """Async accessor for the full dense depth map."""
        return await asyncio.to_thread(self._infer_depth_map, frame)

    async def estimate(self, frame: np.ndarray, detections: List[Detection]) -> List[Detection]:
        """Annotates detections with relative distance proxy and direction."""
        if not detections:
            return detections

        depth_map = await self.estimate_depth_map(frame)
        h, w = frame.shape[0], frame.shape[1] if (frame is not None and frame.ndim >= 2) else (1, 1)

        for det in detections:
            # Determine direction from horizontal bounding box center
            center_x = (det.bbox.x1 + det.bbox.x2) / 2.0
            if center_x < w * 0.35:
                det.direction = "left"
            elif center_x > w * 0.65:
                det.direction = "right"
            else:
                det.direction = "center"

            if depth_map is None:
                # Explicit uncalibrated/unavailable state — do not invent fake distance
                det.distance_m = None
                continue

            # Crop box coordinates within frame boundaries
            x1 = int(np.clip(det.bbox.x1, 0, w - 1))
            y1 = int(np.clip(det.bbox.y1, 0, h - 1))
            x2 = int(np.clip(det.bbox.x2, x1 + 1, w))
            y2 = int(np.clip(det.bbox.y2, y1 + 1, h))

            # Sample central 50% core of the box to avoid background bleed
            bw, bh = x2 - x1, y2 - y1
            cx1 = int(x1 + bw * 0.25)
            cx2 = int(max(cx1 + 1, x2 - bw * 0.25))
            cy1 = int(y1 + bh * 0.25)
            cy2 = int(max(cy1 + 1, y2 - bh * 0.25))

            box_depth = depth_map[cy1:cy2, cx1:cx2]
            if box_depth.size == 0:
                det.distance_m = None
                continue

            # In Depth Anything V2, values are inverse relative depth (disparity).
            # Higher disparity = closer to camera.
            # Convert to relative distance proxy bounded in [0.4m, 8.0m].
            median_disp = float(np.median(box_depth))
            if median_disp <= 0.05:
                # Very far or background
                approx_dist = 6.0
            else:
                # Disparity to relative distance scaling
                approx_dist = 5.0 / median_disp
                approx_dist = max(0.4, min(8.0, approx_dist))

            det.distance_m = round(approx_dist, 2)

        return detections
