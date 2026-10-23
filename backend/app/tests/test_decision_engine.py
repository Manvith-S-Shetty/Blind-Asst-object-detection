import pytest
from app.services.decision_engine import DecisionEngine
from app.models.schemas import Detection, BoundingBox, UrgencyLevel


def make_detection(track_id, label, distance_m, direction="center"):
    return Detection(
        track_id=track_id,
        label=label,
        confidence=0.9,
        bbox=BoundingBox(x1=0, y1=0, x2=10, y2=10),
        distance_m=distance_m,
        direction=direction,
    )


def test_urgent_obstacle_flagged():
    engine = DecisionEngine()
    det = make_detection(1, "chair", distance_m=0.5)
    guidance = engine.generate_guidance([det])
    assert len(guidance) == 1
    assert guidance[0].urgency == UrgencyLevel.urgent
    assert "Stop" in guidance[0].text


def test_warn_obstacle_includes_move_hint():
    engine = DecisionEngine()
    det = make_detection(2, "table", distance_m=1.5, direction="left")
    guidance = engine.generate_guidance([det])
    assert guidance[0].urgency == UrgencyLevel.warn
    assert "right" in guidance[0].text.lower()  # move away from obstacle on the left


def test_far_object_is_info_level():
    engine = DecisionEngine()
    det = make_detection(3, "bench", distance_m=5.0)
    guidance = engine.generate_guidance([det])
    assert guidance[0].urgency == UrgencyLevel.info


def test_nearest_obstacle_announced_first():
    engine = DecisionEngine()
    far = make_detection(4, "pole", distance_m=4.0)
    near = make_detection(5, "person", distance_m=0.6)
    guidance = engine.generate_guidance([far, near])
    assert guidance[0].related_detections[0].label == "person"


def test_reannounce_cooldown_suppresses_repeats():
    engine = DecisionEngine()
    det = make_detection(6, "curb", distance_m=1.8)
    first = engine.generate_guidance([det])
    second = engine.generate_guidance([det])  # immediately again
    assert len(first) == 1
    assert len(second) == 0  # suppressed by cooldown


def test_urgent_bypasses_cooldown():
    engine = DecisionEngine()
    det = make_detection(7, "stairs", distance_m=0.4)
    first = engine.generate_guidance([det])
    second = engine.generate_guidance([det])
    assert len(first) == 1
    assert len(second) == 1  # urgent repeats are not suppressed
