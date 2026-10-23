"""
Conservative obstacle-risk assessment engine.
Combines detection confidence, 2D image position relative to the walking corridor,
monocular relative disparity proxies, and temporal consistency.

MANDATORY SAFETY CONSTRAINTS:
1. Relative depth is an inverse-disparity proxy, NOT calibrated physical distance in metres.
2. Missing detections do not indicate a safe or clear path.
3. Time-to-collision (TTC) is NOT estimated because user walking speed and metric velocity
   are unavailable and unvalidated.
4. An obstacle outside the forward walking corridor is distinguished from one directly in-path.
"""
from enum import Enum
from typing import List, Optional, Tuple
from app.models.schemas import Detection, BoundingBox


class RiskLevel(str, Enum):
    IMMINENT = "imminent"       # Immediate hazard directly in the walking path
    POTENTIAL = "potential"     # Nearby hazard in path, or immediate hazard on the flanks
    AWARENESS = "awareness"     # Obstacle present in field of view but not an immediate path hazard
    NEGLIGIBLE = "negligible"   # Distant, low-confidence, or non-hazardous object


class ProximityBand(str, Enum):
    IMMEDIATE = "immediate"     # High disparity / proxy <= 0.8
    NEAR = "near"               # 0.8 < proxy <= 2.0
    MID = "mid"                 # 2.0 < proxy <= 4.0
    FAR = "far"                 # proxy > 4.0
    UNKNOWN = "unknown"         # depth missing or invalid


class RiskAssessor:
    """Evaluates safety risk without assuming uncalibrated sensor signals represent ground truth."""

    def __init__(
        self,
        corridor_x_min: float = 0.20,
        corridor_x_max: float = 0.80,
        corridor_y_min: float = 0.35,
        min_confidence_imminent: float = 0.50,
        min_confidence_warning: float = 0.40,
    ):
        self.corridor_x_min = corridor_x_min
        self.corridor_x_max = corridor_x_max
        self.corridor_y_min = corridor_y_min
        self.min_confidence_imminent = min_confidence_imminent
        self.min_confidence_warning = min_confidence_warning

    def assess(
        self,
        det: Detection,
        frame_width: int = 640,
        frame_height: int = 480,
    ) -> Detection:
        """Enriches Detection with in_path, proximity_band, and risk_level."""
        w = max(frame_width, 1)
        h = max(frame_height, 1)
        x1_norm = det.bbox.x1 / w
        x2_norm = det.bbox.x2 / w
        y2_norm = det.bbox.y2 / h

        # 1. Walking corridor determination:
        # Does the bounding box horizontally intersect the central walking corridor [0.20, 0.80]
        # and vertically extend into navigable ground space (y2 >= 0.35), or is direction explicitly "center"?
        overlap_x = max(0.0, min(x2_norm, self.corridor_x_max) - max(x1_norm, self.corridor_x_min))
        bbox_in_corridor = (overlap_x > 0.05) and (y2_norm >= self.corridor_y_min)
        in_path = bbox_in_corridor or (det.direction == "center")
        det.in_path = in_path

        # 2. Proximity band derivation (never treating proxy as certified metres)
        if det.distance_m is None:
            band = ProximityBand.UNKNOWN
        elif det.distance_m <= 0.8:
            band = ProximityBand.IMMEDIATE
        elif det.distance_m <= 2.0:
            band = ProximityBand.NEAR
        elif det.distance_m <= 4.0:
            band = ProximityBand.MID
        else:
            band = ProximityBand.FAR
        det.proximity_band = band.value

        # 3. Confidence tier filtering
        conf = det.confidence

        # 4. Conservative Risk Classification
        if conf < self.min_confidence_warning:
            # Low confidence unverified detection -> negligible risk to prevent alarm spam
            det.risk_level = RiskLevel.NEGLIGIBLE.value
        elif band == ProximityBand.IMMEDIATE:
            if in_path and conf >= self.min_confidence_imminent:
                det.risk_level = RiskLevel.IMMINENT.value
            else:
                # Flanking immediate obstacle or moderate confidence
                det.risk_level = RiskLevel.POTENTIAL.value
        elif band == ProximityBand.NEAR:
            if in_path:
                det.risk_level = RiskLevel.POTENTIAL.value
            else:
                det.risk_level = RiskLevel.AWARENESS.value
        elif band in (ProximityBand.MID, ProximityBand.FAR):
            det.risk_level = RiskLevel.AWARENESS.value
        else:
            # UNKNOWN depth
            if in_path and conf >= self.min_confidence_imminent:
                # Depth unavailable but high-confidence obstacle directly in walking path -> potential
                det.risk_level = RiskLevel.POTENTIAL.value
            else:
                det.risk_level = RiskLevel.AWARENESS.value

        return det


risk_assessor = RiskAssessor()
