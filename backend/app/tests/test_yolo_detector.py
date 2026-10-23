
import os
import pytest
import numpy as np
from PIL import Image

from app.pipeline.real.yolo_detector import YoloDetector
from app.models.schemas import Detection


@pytest.mark.asyncio
async def test_real_yolo_detector_loads_and_detects():
    detector = YoloDetector(model_path="yolo11n.pt", confidence_threshold=0.4)
    assert detector.model is not None

    bus_path = os.path.join(
        os.path.dirname(__file__), "..", "..", "venv", "Lib", "site-packages", "ultralytics", "assets", "bus.jpg"
    )
    assert os.path.exists(bus_path), f"Asset {bus_path} not found"

    img = np.array(Image.open(bus_path).convert("RGB"))
    h, w, c = img.shape

    detections = await detector.detect(img)
    assert len(detections) > 0

    labels = [d.label for d in detections]
    assert "bus" in labels
    assert "person" in labels

    for d in detections:
        assert isinstance(d, Detection)
        assert d.confidence >= 0.4
        assert 0 <= d.bbox.x1 <= w
        assert 0 <= d.bbox.x2 <= w
        assert 0 <= d.bbox.y1 <= h
        assert 0 <= d.bbox.y2 <= h
        assert d.bbox.x2 > d.bbox.x1
        assert d.bbox.y2 > d.bbox.y1


@pytest.mark.asyncio
async def test_real_yolo_detector_blank_frame():
    detector = YoloDetector(model_path="yolo11n.pt", confidence_threshold=0.4)
    blank = np.zeros((300, 300, 3), dtype=np.uint8)
    detections = await detector.detect(blank)
    assert detections == []
