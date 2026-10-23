import os
import pytest
import numpy as np
from PIL import Image, ImageDraw

from app.pipeline.real.paddle_ocr import PaddleOCRReader
from app.pipeline.real.blip_describer import BLIPSceneDescriber
from app.pipeline.real.locate_anything import LocateAnythingLocator
from app.api.routes import route_voice_intent
from app.models.schemas import BoundingBox, Detection, OCRResult, SceneDescription


@pytest.fixture
def bus_image():
    bus_path = os.path.join(
        os.path.dirname(__file__), "..", "..", "venv", "Lib", "site-packages", "ultralytics", "assets", "bus.jpg"
    )
    if os.path.exists(bus_path):
        return np.array(Image.open(bus_path).convert("RGB"))
    # Fallback synthetic frame if asset missing
    img = Image.new("RGB", (640, 480), color=(200, 200, 200))
    return np.array(img)


@pytest.fixture
def text_image():
    img = Image.new("RGB", (640, 480), color=(255, 255, 255))
    draw = ImageDraw.Draw(img)
    draw.text((60, 60), "EMERGENCY EXIT", fill=(0, 0, 0))
    draw.text((60, 180), "AUTHORIZED PERSONNEL ONLY", fill=(0, 0, 0))
    return np.array(img)


@pytest.mark.asyncio
async def test_ocr_reader_text_extraction(text_image):
    ocr = PaddleOCRReader(confidence_threshold=0.35)
    results = await ocr.read_text(text_image)

    assert isinstance(results, list)
    assert len(results) > 0
    full_text = " ".join([r.text for r in results]).upper()
    assert "EXIT" in full_text or "EMERGENCY" in full_text

    for r in results:
        assert isinstance(r, OCRResult)
        assert r.confidence >= 0.35
        assert isinstance(r.bbox, BoundingBox)
        assert 0 <= r.bbox.x1 <= 640
        assert 0 <= r.bbox.x2 <= 640
        assert 0 <= r.bbox.y1 <= 480
        assert 0 <= r.bbox.y2 <= 480
        assert r.bbox.x2 > r.bbox.x1
        assert r.bbox.y2 > r.bbox.y1


@pytest.mark.asyncio
async def test_ocr_reader_empty_and_invalid_inputs():
    ocr = PaddleOCRReader()

    # 1. Blank white frame (no text)
    blank = np.full((480, 640, 3), 255, dtype=np.uint8)
    res_blank = await ocr.read_text(blank)
    assert res_blank == []

    # 2. None frame
    res_none = await ocr.read_text(None)
    assert res_none == []

    # 3. Tiny/degenerate frame
    tiny = np.zeros((4, 4, 3), dtype=np.uint8)
    res_tiny = await ocr.read_text(tiny)
    assert res_tiny == []


@pytest.mark.asyncio
async def test_scene_describer_caption(bus_image):
    describer = BLIPSceneDescriber()
    scene = await describer.describe(bus_image)

    assert isinstance(scene, SceneDescription)
    assert len(scene.caption) > 10
    # Caption should be capitalized and end with a period
    assert scene.caption[0].isupper()
    assert scene.caption.endswith(".")
    assert isinstance(scene.tags, list)
    # The caption should not claim navigation is safe
    assert "safe" not in scene.caption.lower()
    assert "clear" not in scene.caption.lower()


@pytest.mark.asyncio
async def test_scene_describer_dark_and_empty():
    describer = BLIPSceneDescriber()

    # 1. Pitch black frame
    black = np.zeros((480, 640, 3), dtype=np.uint8)
    scene_dark = await describer.describe(black)
    assert "dark" in scene_dark.caption.lower() or "covered" in scene_dark.caption.lower()
    assert "dark" in scene_dark.tags

    # 2. None frame
    scene_none = await describer.describe(None)
    assert "unavailable" in scene_none.caption.lower()


@pytest.mark.asyncio
async def test_open_vocab_locator_found_and_not_detected(bus_image):
    locator = LocateAnythingLocator()

    # 1. Object known to be in bus_image ("bus" or "person")
    matches = await locator.locate(bus_image, "bus")
    assert isinstance(matches, list)
    assert len(matches) > 0
    top = matches[0]
    assert isinstance(top, Detection)
    assert top.label in ("bus", "vehicle", "car")
    assert top.direction in ("left", "center", "right")

    # 2. Object definitely absent ("airplane", "toaster", "refrigerator")
    absent_matches = await locator.locate(bus_image, "refrigerator")
    assert absent_matches == []

    # 3. Invalid inputs
    assert await locator.locate(None, "bus") == []
    assert await locator.locate(bus_image, "") == []


def test_voice_intent_routing():
    # 1. Read text variations
    action, target, _ = route_voice_intent("Please read this sign")
    assert action == "read_text"

    action, target, _ = route_voice_intent("Read what text is on the box")
    assert action == "read_text"

    # 2. Find object variations
    action, target, _ = route_voice_intent("Find my water bottle")
    assert action == "find_object"
    assert target == "water bottle"

    action, target, _ = route_voice_intent("Where is my backpack?")
    assert action == "find_object"
    assert target == "backpack"

    action, target, _ = route_voice_intent("Locate a chair")
    assert action == "find_object"
    assert target == "chair"

    # 3. Describe scene variations
    action, target, _ = route_voice_intent("Describe the scene in front of me")
    assert action == "describe_scene"

    action, target, _ = route_voice_intent("What do you see around here?")
    assert action == "describe_scene"

    # 4. Ambiguous / empty
    action, target, guidance = route_voice_intent("Play music")
    assert action == "unknown"
    assert "describe the scene" in guidance.lower()

    action, target, guidance = route_voice_intent("")
    assert action == "unknown"
    assert "did not detect any speech" in guidance.lower()
