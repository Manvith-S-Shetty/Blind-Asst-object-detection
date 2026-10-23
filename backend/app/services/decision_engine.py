"""
Decision Engine: Translates perceived obstacles into safe, prioritized spoken guidance.

SAFETY REQUIREMENTS ENFORCED:
1. No uncalibrated metric claims: Never speaks physical metres ("about X meters away")
   from monocular relative depth. Uses conservative proximity bands.
2. No negative proof: An empty obstacle list does not claim the path is safe or clear.
3. No time-to-collision claims without calibrated motion/distance ground-truth.
4. Cooldown logic suppresses low-value repeats without silencing worsening hazards.
5. Urgent safety warnings bypass standard cooldowns.
"""
from typing import List, Dict, Optional, Tuple
import time

from app.core.config import settings
from app.models.schemas import Detection, GuidanceMessage, UrgencyLevel
from app.services.risk_assessment import risk_assessor, RiskLevel, ProximityBand


class TrackState:
    def __init__(self, announced_at: float, risk_level: str, proximity_band: str, distance_proxy: float):
        self.announced_at = announced_at
        self.risk_level = risk_level
        self.proximity_band = proximity_band
        self.distance_proxy = distance_proxy


class DecisionEngine:
    def __init__(
        self,
        reannounce_cooldown_s: float = 4.0,
        urgent_cooldown_s: float = 2.0,
    ):
        self._track_states: Dict[int, TrackState] = {}
        self.reannounce_cooldown_s = reannounce_cooldown_s
        self.urgent_cooldown_s = urgent_cooldown_s

    def generate_guidance(
        self,
        detections: List[Detection],
        frame_width: int = 640,
        frame_height: int = 480,
    ) -> List[GuidanceMessage]:
        """Processes detections into prioritized, safety-conscious guidance messages."""
        now = time.time()

        # Step 1: Run conservative risk assessment on all detections
        assessed: List[Detection] = []
        for det in detections:
            assessed_det = risk_assessor.assess(det, frame_width=frame_width, frame_height=frame_height)
            assessed.append(assessed_det)

        # Step 2: Filter out negligible noise & sort by safety priority
        # Priority order: IMMINENT > POTENTIAL > AWARENESS
        risk_rank = {
            RiskLevel.IMMINENT.value: 0,
            RiskLevel.POTENTIAL.value: 1,
            RiskLevel.AWARENESS.value: 2,
            RiskLevel.NEGLIGIBLE.value: 3,
        }

        # Sort: first by risk severity, then by proximity proxy (closer first), then confidence
        ranked = sorted(
            [d for d in assessed if d.risk_level != RiskLevel.NEGLIGIBLE.value],
            key=lambda d: (
                risk_rank.get(d.risk_level, 4),
                d.distance_m if d.distance_m is not None else 999.0,
                -d.confidence,
            ),
        )

        messages: List[GuidanceMessage] = []

        for det in ranked:
            tid = det.track_id
            is_urgent = (
                det.risk_level == RiskLevel.IMMINENT.value
                or (det.distance_m is not None and det.distance_m <= settings.obstacle_urgent_distance_m)
            )

            # Check cooldown and worsening hazard condition
            if tid is not None and tid in self._track_states:
                state = self._track_states[tid]
                elapsed = now - state.announced_at
                cur_dist = det.distance_m if det.distance_m is not None else 999.0

                # Check if hazard has worsened (closer by >= 0.4 proxy or elevated to imminent)
                hazard_worsened = (
                    (det.risk_level == RiskLevel.IMMINENT.value and state.risk_level != RiskLevel.IMMINENT.value)
                    or (cur_dist <= state.distance_proxy - 0.4)
                )

                if is_urgent:
                    # Urgent bypasses cooldown, allowing immediate repeat or re-alert
                    pass
                elif not hazard_worsened and elapsed < self.reannounce_cooldown_s:
                    # Suppress repetitive announcement of non-worsened obstacle
                    continue

            # Update tracked state
            if tid is not None:
                self._track_states[tid] = TrackState(
                    announced_at=now,
                    risk_level=det.risk_level or RiskLevel.NEGLIGIBLE.value,
                    proximity_band=det.proximity_band or ProximityBand.UNKNOWN.value,
                    distance_proxy=det.distance_m if det.distance_m is not None else 999.0,
                )

            urgency, text = self._formulate_guidance(det)
            if text:
                messages.append(GuidanceMessage(
                    text=text,
                    urgency=urgency,
                    related_detections=[det],
                ))

            # Prioritize the most critical obstacle to avoid cognitive speech overload
            if is_urgent:
                break

        return messages

    def _formulate_guidance(self, det: Detection) -> Tuple[UrgencyLevel, str]:
        """Generates clear, qualitative guidance.
        SAFETY RULE: Never includes 'about X meters away'.
        """
        direction_phrase = {
            "left": "to your left",
            "right": "to your right",
            "center": "directly ahead",
        }.get(det.direction, "nearby")

        dist = det.distance_m if det.distance_m is not None else 999.0
        is_urgent = (
            det.risk_level == RiskLevel.IMMINENT.value
            or dist <= settings.obstacle_urgent_distance_m
        )

        if is_urgent:
            return UrgencyLevel.urgent, (
                f"Stop. {det.label.capitalize()} very close, {direction_phrase}."
            )

        is_warn = (
            det.risk_level == RiskLevel.POTENTIAL.value
            or dist <= settings.obstacle_warn_distance_m
        )

        if is_warn:
            move_hint = {
                "left": "consider moving right",
                "right": "consider moving left",
                "center": "consider moving slightly left or right",
            }.get(det.direction, "caution")
            return UrgencyLevel.warn, (
                f"{det.label.capitalize()} nearby {direction_phrase}, {move_hint}."
            )

        # Awareness / Info
        if det.direction == "center":
            phrase = f"{det.label.capitalize()} ahead in the distance."
        else:
            phrase = f"{det.label.capitalize()} {direction_phrase}."

        return UrgencyLevel.info, phrase

    def generate_degraded_guidance(self, reason: str) -> List[GuidanceMessage]:
        """Provides explicit warning when perception models or video stream degrades."""
        return [
            GuidanceMessage(
                text=f"Caution: navigation guidance degraded. {reason}",
                urgency=UrgencyLevel.warn,
                is_degraded=True,
            )
        ]


decision_engine = DecisionEngine()
