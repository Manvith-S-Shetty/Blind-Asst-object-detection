"""
Focused safety and navigation engine automated tests.

SAFETY DISCLAIMER:
These automated unit tests use deterministic synthetic inputs to verify software logic,
uncertainty handling, and cooldown rules. They do NOT certify or prove real-world
physical navigation safety.
"""
import pytest
import re
from app.services.decision_engine import DecisionEngine
from app.services.risk_assessment import RiskAssessor, RiskLevel, ProximityBand
from app.models.schemas import Detection, BoundingBox, UrgencyLevel


def make_test_detection(
    track_id=1,
    label="chair",
    confidence=0.9,
    bbox=(200, 200, 400, 450),
    distance_m=1.2,
    direction="center",
):
    return Detection(
        track_id=track_id,
        label=label,
        confidence=confidence,
        bbox=BoundingBox(x1=bbox[0], y1=bbox[1], x2=bbox[2], y2=bbox[3]),
        distance_m=distance_m,
        direction=direction,
    )


# 1. High-confidence vs low-confidence gating
def test_high_vs_low_confidence_detections():
    assessor = RiskAssessor()
    # High confidence in corridor
    high_conf = make_test_detection(confidence=0.88, distance_m=0.6)
    assessor.assess(high_conf, 640, 480)
    assert high_conf.risk_level == RiskLevel.IMMINENT.value

    # Low confidence (< 0.40) noise detection in corridor
    low_conf = make_test_detection(confidence=0.35, distance_m=0.6)
    assessor.assess(low_conf, 640, 480)
    assert low_conf.risk_level == RiskLevel.NEGLIGIBLE.value

    engine = DecisionEngine()
    guidance = engine.generate_guidance([low_conf])
    # Low-confidence noise is suppressed
    assert len(guidance) == 0


# 2. Objects inside vs outside estimated walking corridor
def test_inside_vs_outside_walking_corridor():
    assessor = RiskAssessor(corridor_x_min=0.20, corridor_x_max=0.80)

    # In path: center bounding box [250, 200, 390, 450] in 640x480 frame
    in_corridor = make_test_detection(bbox=(250, 200, 390, 450), distance_m=0.5, direction="center")
    assessor.assess(in_corridor, 640, 480)
    assert in_corridor.in_path is True
    assert in_corridor.risk_level == RiskLevel.IMMINENT.value

    # Outside corridor: far left flank [10, 200, 60, 450] with direction="left"
    flank_left = make_test_detection(bbox=(10, 200, 60, 450), distance_m=0.5, direction="left")
    assessor.assess(flank_left, 640, 480)
    assert flank_left.in_path is False
    # Flanking obstacle downgraded to POTENTIAL (not imminent collision)
    assert flank_left.risk_level == RiskLevel.POTENTIAL.value


# 3. Conflicting and missing depth signals
def test_conflicting_or_missing_depth():
    assessor = RiskAssessor()
    engine = DecisionEngine()

    # Obstacle directly in path but depth estimation failed (None)
    missing_depth = make_test_detection(distance_m=None, confidence=0.85, direction="center")
    assessor.assess(missing_depth, 640, 480)
    assert missing_depth.proximity_band == ProximityBand.UNKNOWN.value
    # Handled cautiously as potential risk
    assert missing_depth.risk_level == RiskLevel.POTENTIAL.value

    guidance = engine.generate_guidance([missing_depth])
    assert len(guidance) == 1
    assert guidance[0].urgency == UrgencyLevel.warn
    # No bogus metric distance emitted
    assert "meter" not in guidance[0].text.lower()


# 4. Empty detections must never falsely declare path clear
def test_empty_detections_does_not_declare_path_clear():
    engine = DecisionEngine()
    guidance = engine.generate_guidance([])
    assert len(guidance) == 0
    for g in guidance:
        assert "safe" not in g.text.lower()
        assert "clear" not in g.text.lower()


# 5. Worsening hazard bypasses cooldown
def test_worsening_hazard_bypasses_cooldown():
    engine = DecisionEngine(reannounce_cooldown_s=5.0)

    # Frame 1: Obstacle at distance proxy 1.8 (Warn/Potential)
    det_f1 = make_test_detection(track_id=10, distance_m=1.8, direction="center")
    g1 = engine.generate_guidance([det_f1])
    assert len(g1) == 1
    assert g1[0].urgency == UrgencyLevel.warn

    # Frame 2 (immediate): Distance remains 1.8 -> suppressed by cooldown
    g2 = engine.generate_guidance([det_f1])
    assert len(g2) == 0

    # Frame 3 (immediate): Obstacle rapidly approaches to 0.6 (worsened to Imminent!)
    det_f3 = make_test_detection(track_id=10, distance_m=0.6, direction="center")
    g3 = engine.generate_guidance([det_f3])
    assert len(g3) == 1
    assert g3[0].urgency == UrgencyLevel.urgent
    assert "Stop" in g3[0].text


# 6. Priority selection: imminent hazards supersede informational messages
def test_guidance_priority_selection():
    engine = DecisionEngine()

    imminent = make_test_detection(track_id=1, label="stairs", distance_m=0.5, direction="center")
    potential = make_test_detection(track_id=2, label="chair", distance_m=1.5, direction="left")
    awareness = make_test_detection(track_id=3, label="tree", distance_m=4.5, direction="right")

    guidance = engine.generate_guidance([awareness, potential, imminent])
    # Imminent obstacle is prioritized and dominates output
    assert len(guidance) >= 1
    assert guidance[0].urgency == UrgencyLevel.urgent
    assert "stairs" in guidance[0].text.lower()
    assert "Stop" in guidance[0].text


# 7. No metric distance claims in any generated guidance
def test_no_metric_distance_claims():
    engine = DecisionEngine()
    test_cases = [
        make_test_detection(distance_m=0.3, direction="center"),
        make_test_detection(distance_m=1.2, direction="left"),
        make_test_detection(distance_m=2.5, direction="right"),
        make_test_detection(distance_m=6.0, direction="center"),
        make_test_detection(distance_m=None, direction="center"),
    ]

    metric_pattern = re.compile(r"\b(\d+(\.\d+)?)\s*(meter|metre|m\b)", re.IGNORECASE)

    for tc in test_cases:
        msgs = engine.generate_guidance([tc])
        for m in msgs:
            match = metric_pattern.search(m.text)
            assert match is None, f"Found forbidden metric distance claim '{match.group(0)}' in: {m.text}"


# 8. Degraded mode behavior
def test_degraded_mode_behavior():
    engine = DecisionEngine()
    degraded_msgs = engine.generate_degraded_guidance("Camera frame corrupted or sensor disconnected")
    assert len(degraded_msgs) == 1
    assert degraded_msgs[0].is_degraded is True
    assert degraded_msgs[0].urgency == UrgencyLevel.warn
    assert "degraded" in degraded_msgs[0].text.lower()
