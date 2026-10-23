"""
Builds the active pipeline stage-by-stage based on Settings.use_real_models.
This is the ONLY place mock vs real implementations are chosen — everything
else in the app talks to the abstract interfaces in interfaces.py.
"""
from dataclasses import dataclass

from app.core.config import settings
from app.pipeline.interfaces import (
    Detector, Tracker, DepthEstimator, SceneDescriber,
    OpenVocabLocator, OCRReader, Segmenter, SpeechToText, TextToSpeech,
)
from app.pipeline.mock.detection import MockDetector, MockTracker
from app.pipeline.mock.perception import (
    MockDepthEstimator, MockSceneDescriber, MockOpenVocabLocator,
    MockOCRReader, MockSegmenter,
)
from app.pipeline.mock.voice import MockSpeechToText, MockTextToSpeech


@dataclass
class Pipeline:
    detector: Detector
    tracker: Tracker
    depth_estimator: DepthEstimator
    scene_describer: SceneDescriber
    open_vocab_locator: OpenVocabLocator
    ocr_reader: OCRReader
    segmenter: Segmenter
    speech_to_text: SpeechToText
    text_to_speech: TextToSpeech


class ModelUnavailableError(RuntimeError):
    """Raised when a requested real model is unavailable or failed to initialize."""
    def __init__(self, component_key: str, reason: str):
        self.component_key = component_key
        self.reason = reason
        super().__init__(f"Real model '{component_key}' is unavailable: {reason}")


class UnavailableComponent:
    """Explicit placeholder for a real component that failed to load.
    Prevents silent fallback to mock data when real inference was expected.
    """
    def __init__(self, component_key: str, error_msg: str):
        self._component_key = component_key
        self._error_msg = error_msg

    def __getattr__(self, name):
        async def _raise_unavailable(*args, **kwargs):
            raise ModelUnavailableError(self._component_key, self._error_msg)
        return _raise_unavailable


def _pick(component_key: str, mock_impl, real_import_path: str):
    """Returns the mock instance if disabled, or the real model if enabled.
    If a real model is enabled but fails to import or initialize, returns an
    UnavailableComponent that explicitly raises ModelUnavailableError instead
    of silently substituting mock outputs.
    """
    if not settings.use_real_models.get(component_key, False):
        return mock_impl()
    try:
        module_path, class_name = real_import_path.rsplit(".", 1)
        module = __import__(module_path, fromlist=[class_name])
        real_cls = getattr(module, class_name)
        return real_cls()
    except Exception as e:
        from app.core.logging_config import logger
        logger.error(
            f"Real model for '{component_key}' failed to initialize ({e}). "
            f"Operating in explicit unavailable state — mock fallback suppressed for safety.",
            exc_info=True
        )
        return UnavailableComponent(component_key, str(e))


def build_pipeline() -> Pipeline:
    return Pipeline(
        detector=_pick("detector", MockDetector, "app.pipeline.real.yolo_detector.YoloDetector"),
        tracker=_pick("tracker", MockTracker, "app.pipeline.real.bytetrack_tracker.ByteTrackTracker"),
        depth_estimator=_pick("depth_estimator", MockDepthEstimator, "app.pipeline.real.depth_anything.DepthAnythingEstimator"),
        scene_describer=_pick("scene_describer", MockSceneDescriber, "app.pipeline.real.florence2.Florence2Describer"),
        open_vocab_locator=_pick("open_vocab_locator", MockOpenVocabLocator, "app.pipeline.real.locate_anything.LocateAnythingLocator"),
        ocr_reader=_pick("ocr_reader", MockOCRReader, "app.pipeline.real.paddle_ocr.PaddleOCRReader"),
        segmenter=_pick("segmenter", MockSegmenter, "app.pipeline.real.sam2_segmenter.SAM2Segmenter"),
        speech_to_text=_pick("speech_to_text", MockSpeechToText, "app.pipeline.real.whisper_stt.WhisperSTT"),
        text_to_speech=_pick("text_to_speech", MockTextToSpeech, "app.pipeline.real.piper_tts.PiperTTS"),
    )


# Single shared pipeline instance for the app's lifetime.
pipeline = build_pipeline()
