import re
import gc
import numpy as np
from typing import List, Optional
from PIL import Image
import torch
from transformers import BlipProcessor, BlipForConditionalGeneration

from app.pipeline.interfaces import SceneDescriber
from app.models.schemas import SceneDescription
from app.core.logging_config import logger


class BLIPSceneDescriber(SceneDescriber):
    """
    On-demand scene description using Salesforce/blip-image-captioning-base
    (BSD-3-Clause license, 247M parameters).
    Lazy-loads on first voice query and supports explicit unload() to reclaim
    memory, keeping continuous navigation lightweight.
    """
    def __init__(self, model_id: str = "Salesforce/blip-image-captioning-base", lazy_load: bool = True):
        self.model_id = model_id
        self._processor: Optional[BlipProcessor] = None
        self._model: Optional[BlipForConditionalGeneration] = None
        if not lazy_load:
            self._ensure_loaded()

    def _ensure_loaded(self):
        if self._model is not None and self._processor is not None:
            return
        try:
            logger.info(f"Loading scene describer model: {self.model_id}...")
            self._processor = BlipProcessor.from_pretrained(self.model_id)
            self._model = BlipForConditionalGeneration.from_pretrained(self.model_id)
            self._model.eval()
            logger.info("BLIPSceneDescriber loaded successfully.")
        except Exception as e:
            logger.error(f"Failed to load BLIP model '{self.model_id}': {e}", exc_info=True)
            raise RuntimeError(f"BLIP model initialization failed: {e}")

    def unload(self):
        """Releases model weights and frees system RAM."""
        if self._model is not None or self._processor is not None:
            logger.info("Unloading BLIPSceneDescriber to reclaim system memory.")
            self._model = None
            self._processor = None
            gc.collect()

    async def describe(self, frame: np.ndarray) -> SceneDescription:
        if frame is None or not isinstance(frame, np.ndarray) or frame.size == 0:
            return SceneDescription(
                caption="Camera frame is unavailable or unreadable.",
                tags=["unavailable"]
            )

        # Check for pitch black or obscured camera
        mean_brightness = float(np.mean(frame))
        if mean_brightness < 8.0:
            return SceneDescription(
                caption="The camera appears to be covered or in near-total darkness.",
                tags=["dark", "covered"]
            )

        try:
            self._ensure_loaded()
            pil_img = Image.fromarray(frame).convert("RGB")
            # Downsample if image is very large to maintain fast CPU inference
            w, h = pil_img.size
            if max(w, h) > 640:
                scale = 640.0 / max(w, h)
                pil_img = pil_img.resize((int(w * scale), int(h * scale)), Image.Resampling.BILINEAR)

            inputs = self._processor(pil_img, return_tensors="pt")
            with torch.no_grad():
                out = self._model.generate(
                    **inputs,
                    max_new_tokens=40,
                    min_length=8,
                    num_beams=2,
                )
            raw_caption = self._processor.decode(out[0], skip_special_tokens=True).strip()

            # Clean and capitalize caption
            if raw_caption:
                clean_caption = raw_caption[0].upper() + raw_caption[1:]
                if not clean_caption.endswith("."):
                    clean_caption += "."
            else:
                clean_caption = "A scene is in view, but specific details could not be determined."

            # Extract simple keyword tags
            words = re.findall(r"\b[A-Za-z]{3,}\b", clean_caption.lower())
            stop_words = {"the", "and", "with", "for", "that", "this", "are", "there", "view", "scene"}
            tags = [w for w in set(words) if w not in stop_words][:6]

            return SceneDescription(
                caption=clean_caption,
                tags=tags
            )
        except Exception as e:
            logger.error(f"Scene description inference error: {e}", exc_info=True)
            return SceneDescription(
                caption="Unable to analyze the scene at this moment.",
                tags=["error"]
            )


# Alias for backwards compatibility with factory.py
Florence2Describer = BLIPSceneDescriber
