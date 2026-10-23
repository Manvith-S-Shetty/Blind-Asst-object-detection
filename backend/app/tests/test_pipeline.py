import pytest
import numpy as np

from app.pipeline.mock.detection import MockDetector, MockTracker
from app.pipeline.mock.perception import MockDepthEstimator, MockSceneDescriber, MockOCRReader
from app.pipeline.mock.voice import MockSpeechToText, MockTextToSpeech


def dummy_frame():
    return np.random.randint(0, 255, (480, 640, 3), dtype=np.uint8)


@pytest.mark.asyncio
async def test_detector_returns_detections():
    detector = MockDetector()
    detections = await detector.detect(dummy_frame())
    assert 1 <= len(detections) <= 3
    for d in detections:
        assert d.confidence > 0
        assert d.bbox.x2 > d.bbox.x1


@pytest.mark.asyncio
async def test_tracker_assigns_ids():
    detector = MockDetector()
    tracker = MockTracker()
    frame = dummy_frame()
    detections = await detector.detect(frame)
    tracked = await tracker.update(detections)
    assert all(d.track_id is not None for d in tracked)


@pytest.mark.asyncio
async def test_depth_estimator_adds_distance_and_direction():
    detector = MockDetector()
    depth = MockDepthEstimator()
    frame = dummy_frame()
    detections = await detector.detect(frame)
    result = await depth.estimate(frame, detections)
    for d in result:
        assert d.distance_m is not None and d.distance_m > 0
        assert d.direction in ("left", "center", "right")


@pytest.mark.asyncio
async def test_scene_describer_returns_caption():
    describer = MockSceneDescriber()
    scene = await describer.describe(dummy_frame())
    assert len(scene.caption) > 0


@pytest.mark.asyncio
async def test_stt_handles_empty_audio():
    stt = MockSpeechToText()
    result = await stt.transcribe(b"")
    assert result.confidence == 0.0


@pytest.mark.asyncio
async def test_tts_returns_valid_wav_bytes():
    tts = MockTextToSpeech()
    audio = await tts.synthesize("hello")
    assert audio[:4] == b"RIFF"
    assert audio[8:12] == b"WAVE"
