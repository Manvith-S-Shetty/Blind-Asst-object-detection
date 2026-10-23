import os
import pytest
import numpy as np
from PIL import Image

from app.pipeline.real.sam2_segmenter import SAM2Segmenter
from app.models.schemas import Detection, BoundingBox


@pytest.fixture(scope="module")
def segmenter():
    return SAM2Segmenter(model_path="yolo11n-seg.pt", conf_thresh=0.35)


@pytest.mark.asyncio
async def test_segmenter_output_dimensions_and_masks(segmenter):
    bus_path = os.path.join(
        os.path.dirname(__file__), "..", "..", "venv", "Lib", "site-packages", "ultralytics", "assets", "bus.jpg"
    )
    img = np.array(Image.open(bus_path).convert("RGB"))
    h, w, _ = img.shape

    dets = [
        Detection(label="bus", confidence=0.94, bbox=BoundingBox(x1=21, y1=231, x2=806, y2=734)),
        Detection(label="person", confidence=0.88, bbox=BoundingBox(x1=671, y1=394, x2=809, y2=878)),
    ]

    mask = await segmenter.segment(img, dets)
    assert mask.shape == (h, w)
    assert mask.dtype == np.uint8

    # Mask should contain values for detection 1 and detection 2
    unique_vals = set(np.unique(mask))
    assert 1 in unique_vals or 2 in unique_vals


@pytest.mark.asyncio
async def test_corridor_occupancy(segmenter):
    bus_path = os.path.join(
        os.path.dirname(__file__), "..", "..", "venv", "Lib", "site-packages", "ultralytics", "assets", "bus.jpg"
    )
    img = np.array(Image.open(bus_path).convert("RGB"))

    # Person in bottom center corridor
    dets = [
        Detection(label="person", confidence=0.85, bbox=BoundingBox(x1=200, y1=600, x2=400, y2=900))
    ]

    res = await segmenter.compute_corridor_occupancy(img, dets)
    assert "corridor_clear" in res
    assert "occupied_ratio" in res
    assert "safety_disclaimer" in res
    assert res["occupied_ratio"] > 0


@pytest.mark.asyncio
async def test_segmenter_invalid_and_empty_frames(segmenter):
    # None frame
    res_none = await segmenter.segment(None, [])
    assert res_none.shape == (0, 0)

    # Empty frame
    empty = np.zeros((0, 0, 3), dtype=np.uint8)
    res_empty = await segmenter.segment(empty, [])
    assert res_empty.shape == (0, 0)

    # Valid blank frame with no detections
    blank = np.zeros((100, 100, 3), dtype=np.uint8)
    res_blank = await segmenter.segment(blank, [])
    assert res_blank.shape == (100, 100)
    assert np.all(res_blank == 0)
