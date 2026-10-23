import numpy as np
from typing import List
from rapidocr_onnxruntime import RapidOCR

from app.pipeline.interfaces import OCRReader
from app.models.schemas import OCRResult, BoundingBox
from app.core.logging_config import logger


class PaddleOCRReader(OCRReader):
    """
    Real OCR implementation using RapidOCR (PP-OCRv4 ONNX runtime).
    Permissive Apache-2.0 license. Provides high-accuracy text extraction
    from scene photos and mobile camera frames without heavy C++ runtime dependencies.
    """
    def __init__(self, confidence_threshold: float = 0.35):
        self.confidence_threshold = confidence_threshold
        try:
            self.engine = RapidOCR()
            logger.info("PaddleOCRReader (RapidOCR PP-OCRv4) initialized successfully.")
        except Exception as e:
            logger.error(f"Failed to initialize RapidOCR: {e}", exc_info=True)
            raise RuntimeError(f"RapidOCR engine initialization failed: {e}")

    async def read_text(self, frame: np.ndarray) -> List[OCRResult]:
        if frame is None or not isinstance(frame, np.ndarray) or frame.size == 0:
            logger.warning("Empty or invalid frame passed to read_text.")
            return []

        h, w = frame.shape[:2]
        if h < 10 or w < 10:
            logger.warning(f"Frame dimensions too small for OCR: {w}x{h}")
            return []

        try:
            raw_results, _ = self.engine(frame)
        except Exception as e:
            logger.error(f"RapidOCR inference error: {e}", exc_info=True)
            return []

        if not raw_results:
            return []

        results: List[OCRResult] = []
        for item in raw_results:
            # item format: [box_points, text, confidence]
            # box_points: [[x1, y1], [x2, y1], [x2, y2], [x1, y2]]
            try:
                box_points, text, score = item
                text_clean = str(text).strip()
                score_val = float(score)

                if score_val < self.confidence_threshold or not text_clean:
                    continue

                xs = [pt[0] for pt in box_points]
                ys = [pt[1] for pt in box_points]
                x1 = max(0.0, float(min(xs)))
                y1 = max(0.0, float(min(ys)))
                x2 = min(float(w), float(max(xs)))
                y2 = min(float(h), float(max(ys)))

                if x2 <= x1 or y2 <= y1:
                    continue

                results.append(
                    OCRResult(
                        text=text_clean,
                        bbox=BoundingBox(x1=x1, y1=y1, x2=x2, y2=y2),
                        confidence=round(score_val, 3),
                    )
                )
            except Exception as item_err:
                logger.warning(f"Failed to parse OCR result item {item}: {item_err}")
                continue

        return results
