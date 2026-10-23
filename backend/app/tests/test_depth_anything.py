import os
import pytest
import numpy as np
from PIL import Image

from app.pipeline.real.depth_anything import DepthAnythingEstimator
from app.models.schemas import Detection, BoundingBox


@pytest.fixture(scope="module")
def depth_estimator():
    return DepthAnythingEstimator(input_size=252)


@pytest.mark.asyncio
async def test_depth_output_shape_and_range(depth_estimator):
    bus_path = os.path.join(
        os.path.dirname(__file__), "..", "..", "venv", "Lib", "site-packages", "ultralytics", "assets", "bus.jpg"
    )
    img = np.array(Image.open(bus_path).convert("RGB"))
    h, w, _ = img.shape

    depth_map = await depth_estimator.estimate_depth_map(img)
    assert depth_map is not None
    assert depth_map.shape == (h, w)
    assert not np.isnan(depth_map).any()
    assert not np.isinf(depth_map).any()
    assert depth_map.min() >= 0


@pytest.mark.asyncio
async def test_depth_annotation_on_detections(depth_estimator):
    bus_path = os.path.join(
        os.path.dirname(__file__), "..", "..", "venv", "Lib", "site-packages", "ultralytics", "assets", "bus.jpg"
    )
    img = np.array(Image.open(bus_path).convert("RGB"))

    # Person in foreground vs bus in background
    dets = [
        Detection(label="person", confidence=0.88, bbox=BoundingBox(x1=671, y1=394, x2=809, y2=878)),
        Detection(label="bus", confidence=0.94, bbox=BoundingBox(x1=21, y1=231, x2=806, y2=734)),
    ]

    annotated = await depth_estimator.estimate(img, dets)
    assert len(annotated) == 2
    for d in annotated:
        assert d.distance_m is not None
        assert 0.4 <= d.distance_m <= 8.0
        assert d.direction in ["left", "center", "right"]


@pytest.mark.asyncio
async def test_depth_invalid_inputs(depth_estimator):
    # None frame
    res_none = await depth_estimator.estimate_depth_map(None)
    assert res_none is None

    # Empty frame
    empty = np.zeros((0, 0, 3), dtype=np.uint8)
    res_empty = await depth_estimator.estimate_depth_map(empty)
    assert res_empty is None

    # Degenerate frame (< 10px)
    tiny = np.zeros((5, 5, 3), dtype=np.uint8)
    res_tiny = await depth_estimator.estimate_depth_map(tiny)
    assert res_tiny is None

    # Passing invalid frame to estimate() should leave distance_m as None safely
    dets = [Detection(label="chair", confidence=0.7, bbox=BoundingBox(x1=1, y1=1, x2=4, y2=4))]
    annotated = await depth_estimator.estimate(tiny, dets)
    assert annotated[0].distance_m is None
    assert annotated[0].direction is not None
