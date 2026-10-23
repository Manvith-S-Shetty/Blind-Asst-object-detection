"""
Real multi-object tracker implementing ByteTrack (Zhang et al. 2022).
Associates detections across consecutive frames using two-stage IoU
matching (high-confidence detections first, low-confidence recovery second)
with track buffer management for occlusion and reappearance.
License: MIT compatible.
"""
from typing import List, Optional, Tuple, Dict
import numpy as np

from app.pipeline.interfaces import Tracker
from app.models.schemas import Detection, BoundingBox
from app.core.logging_config import logger

try:
    import lap
    _HAS_LAP = True
except ImportError:
    _HAS_LAP = False


def box_iou(box1: np.ndarray, box2: np.ndarray) -> np.ndarray:
    """Computes pairwise IoU between two sets of boxes (x1, y1, x2, y2)."""
    if len(box1) == 0 or len(box2) == 0:
        return np.zeros((len(box1), len(box2)), dtype=np.float32)

    b1_x1, b1_y1, b1_x2, b1_y2 = box1[:, 0:1], box1[:, 1:2], box1[:, 2:3], box1[:, 3:4]
    b2_x1, b2_y1, b2_x2, b2_y2 = box2[:, 0], box2[:, 1], box2[:, 2], box2[:, 3]

    inter_x1 = np.maximum(b1_x1, b2_x1)
    inter_y1 = np.maximum(b1_y1, b2_y1)
    inter_x2 = np.minimum(b1_x2, b2_x2)
    inter_y2 = np.minimum(b1_y2, b2_y2)

    inter_w = np.maximum(0.0, inter_x2 - inter_x1)
    inter_h = np.maximum(0.0, inter_y2 - inter_y1)
    inter_area = inter_w * inter_h

    b1_area = (b1_x2 - b1_x1) * (b1_y2 - b1_y1)
    b2_area = (b2_x2 - b2_x1) * (b2_y2 - b2_y1)

    union = b1_area + b2_area - inter_area
    union = np.maximum(union, 1e-6)

    return inter_area / union


def linear_assignment(cost_matrix: np.ndarray, thresh: float) -> Tuple[List[Tuple[int, int]], List[int], List[int]]:
    """Linear sum assignment on cost matrix with threshold gating.
    Returns: (matches, unmatched_a, unmatched_b)
    """
    if cost_matrix.size == 0:
        return [], list(range(cost_matrix.shape[0])), list(range(cost_matrix.shape[1]))

    matches = []
    unmatched_a = list(range(cost_matrix.shape[0]))
    unmatched_b = list(range(cost_matrix.shape[1]))

    if _HAS_LAP:
        try:
            _, x, y = lap.lapjv(cost_matrix, extend_cost=True, cost_limit=thresh)
            for i, j in enumerate(x):
                if j >= 0:
                    matches.append((i, j))
                    if i in unmatched_a:
                        unmatched_a.remove(i)
                    if j in unmatched_b:
                        unmatched_b.remove(j)
            return matches, unmatched_a, unmatched_b
        except Exception:
            pass

    # Greedy fallback matching if LAP unavailable or fails
    cost_copy = cost_matrix.copy()
    num_a, num_b = cost_matrix.shape
    while True:
        min_idx = np.unravel_index(np.argmin(cost_copy), cost_copy.shape)
        min_cost = cost_copy[min_idx]
        if min_cost > thresh or np.isinf(min_cost):
            break
        i, j = min_idx
        matches.append((i, j))
        if i in unmatched_a:
            unmatched_a.remove(i)
        if j in unmatched_b:
            unmatched_b.remove(j)
        cost_copy[i, :] = np.inf
        cost_copy[:, j] = np.inf

    return matches, unmatched_a, unmatched_b


class Track:
    def __init__(self, track_id: int, bbox: np.ndarray, score: float, label: str):
        self.track_id = track_id
        self.bbox = bbox.copy()  # [x1, y1, x2, y2]
        self.score = score
        self.label = label
        self.time_since_update = 0
        self.is_activated = True

    def predict(self):
        # Linear motion / static assumption with frame bounding
        self.time_since_update += 1

    def update(self, bbox: np.ndarray, score: float, label: str):
        self.bbox = bbox.copy()
        self.score = score
        self.label = label
        self.time_since_update = 0
        self.is_activated = True


class ByteTrackTracker(Tracker):
    """Production ByteTrack implementation compatible with Blind Assistant pipeline."""

    def __init__(
        self,
        track_high_thresh: float = 0.45,
        track_low_thresh: float = 0.2,
        match_thresh: float = 0.7,  # Cost threshold: 1 - IoU
        max_time_lost: int = 30,    # Max frames to keep lost tracks for re-id
    ):
        self.track_high_thresh = track_high_thresh
        self.track_low_thresh = track_low_thresh
        self.match_thresh = match_thresh
        self.max_time_lost = max_time_lost

        self.tracked_tracks: List[Track] = []
        self.lost_tracks: List[Track] = []
        self._next_id = 1
        self.frame_id = 0
        logger.info("ByteTrackTracker initialized successfully")

    def reset(self):
        """Reset all active and lost tracks."""
        self.tracked_tracks.clear()
        self.lost_tracks.clear()
        self._next_id = 1
        self.frame_id = 0
        logger.info("ByteTrackTracker reset")

    def _next_track_id(self) -> int:
        tid = self._next_id
        self._next_id += 1
        return tid

    async def update(self, detections: List[Detection]) -> List[Detection]:
        """Update tracker with frame detections.
        SAFETY GUARANTEE: Never emits stale track positions. Only detections
        physically detected in the current frame receive track IDs.
        """
        self.frame_id += 1

        if not detections:
            # Predict & age tracks
            for t in self.tracked_tracks:
                t.predict()
            for t in self.lost_tracks:
                t.predict()
            # Move aged tracked tracks to lost
            self.lost_tracks.extend([t for t in self.tracked_tracks if t.time_since_update > 0])
            self.tracked_tracks = [t for t in self.tracked_tracks if t.time_since_update == 0]
            # Cull permanently lost tracks
            self.lost_tracks = [t for t in self.lost_tracks if t.time_since_update <= self.max_time_lost]
            return []

        # Convert detections to arrays
        det_boxes = np.array([
            [d.bbox.x1, d.bbox.y1, d.bbox.x2, d.bbox.y2] for d in detections
        ], dtype=np.float32)
        det_scores = np.array([d.confidence for d in detections], dtype=np.float32)
        det_labels = [d.label for d in detections]

        # Step 1: Split detections into high and low confidence
        high_mask = det_scores >= self.track_high_thresh
        low_mask = (det_scores >= self.track_low_thresh) & (~high_mask)

        high_indices = np.where(high_mask)[0]
        low_indices = np.where(low_mask)[0]

        # Predict existing tracks
        for t in self.tracked_tracks:
            t.predict()
        for t in self.lost_tracks:
            t.predict()

        # Step 2: First association (high confidence with tracked tracks)
        tracked_pool = self.tracked_tracks
        if tracked_pool and len(high_indices) > 0:
            track_boxes = np.array([t.bbox for t in tracked_pool], dtype=np.float32)
            ious = box_iou(track_boxes, det_boxes[high_indices])
            # Penalize class label mismatch
            for i, t in enumerate(tracked_pool):
                for j, h_idx in enumerate(high_indices):
                    if t.label != det_labels[h_idx]:
                        ious[i, j] = 0.0

            cost_matrix = 1.0 - ious
            matches_1, unmatched_tracks_1, unmatched_high_1 = linear_assignment(
                cost_matrix, thresh=self.match_thresh
            )
        else:
            matches_1 = []
            unmatched_tracks_1 = list(range(len(tracked_pool)))
            unmatched_high_1 = list(range(len(high_indices)))

        # Update matched tracks from first association
        assigned_track_ids: Dict[int, int] = {}
        matched_tracked_set = set()
        for t_idx, h_sub_idx in matches_1:
            track = tracked_pool[t_idx]
            d_idx = high_indices[h_sub_idx]
            track.update(det_boxes[d_idx], det_scores[d_idx], det_labels[d_idx])
            assigned_track_ids[d_idx] = track.track_id
            matched_tracked_set.add(t_idx)

        # Step 3: Second association (unmatched tracked tracks with low confidence detections)
        remaining_tracked = [tracked_pool[i] for i in unmatched_tracks_1]
        if remaining_tracked and len(low_indices) > 0:
            rem_boxes = np.array([t.bbox for t in remaining_tracked], dtype=np.float32)
            ious = box_iou(rem_boxes, det_boxes[low_indices])
            for i, t in enumerate(remaining_tracked):
                for j, l_idx in enumerate(low_indices):
                    if t.label != det_labels[l_idx]:
                        ious[i, j] = 0.0
            cost_matrix = 1.0 - ious
            matches_2, unmatched_tracks_2, _ = linear_assignment(cost_matrix, thresh=0.6)
            for r_idx, l_sub_idx in matches_2:
                track = remaining_tracked[r_idx]
                d_idx = low_indices[l_sub_idx]
                track.update(det_boxes[d_idx], det_scores[d_idx], det_labels[d_idx])
                assigned_track_ids[d_idx] = track.track_id
                # Track is saved from being lost
                original_idx = tracked_pool.index(track)
                matched_tracked_set.add(original_idx)
        else:
            unmatched_tracks_2 = list(range(len(remaining_tracked)))

        # Step 4: Third association (unmatched high confidence with lost tracks for re-identification)
        unmatched_high_indices = [high_indices[i] for i in unmatched_high_1]
        if self.lost_tracks and unmatched_high_indices:
            lost_boxes = np.array([t.bbox for t in self.lost_tracks], dtype=np.float32)
            ious = box_iou(lost_boxes, det_boxes[unmatched_high_indices])
            for i, t in enumerate(self.lost_tracks):
                for j, h_idx in enumerate(unmatched_high_indices):
                    if t.label != det_labels[h_idx]:
                        ious[i, j] = 0.0
            cost_matrix = 1.0 - ious
            matches_3, unmatched_lost, unmatched_high_3 = linear_assignment(
                cost_matrix, thresh=self.match_thresh
            )
            reidentified_lost = set()
            for l_idx, h_sub_idx in matches_3:
                track = self.lost_tracks[l_idx]
                d_idx = unmatched_high_indices[h_sub_idx]
                track.update(det_boxes[d_idx], det_scores[d_idx], det_labels[d_idx])
                assigned_track_ids[d_idx] = track.track_id
                self.tracked_tracks.append(track)
                reidentified_lost.add(l_idx)
            self.lost_tracks = [t for i, t in enumerate(self.lost_tracks) if i not in reidentified_lost]
            final_unmatched_high = [unmatched_high_indices[i] for i in unmatched_high_3]
        else:
            final_unmatched_high = unmatched_high_indices

        # Step 5: Initialize new tracks for remaining unmatched high-confidence detections
        for d_idx in final_unmatched_high:
            new_id = self._next_track_id()
            new_track = Track(
                track_id=new_id,
                bbox=det_boxes[d_idx],
                score=det_scores[d_idx],
                label=det_labels[d_idx],
            )
            self.tracked_tracks.append(new_track)
            assigned_track_ids[d_idx] = new_id

        # Step 6: Move unmatched tracked tracks to lost
        newly_lost = [t for i, t in enumerate(tracked_pool) if i not in matched_tracked_set]
        self.tracked_tracks = [t for i, t in enumerate(tracked_pool) if i in matched_tracked_set]
        self.lost_tracks.extend(newly_lost)

        # Cull expired lost tracks
        self.lost_tracks = [t for t in self.lost_tracks if t.time_since_update <= self.max_time_lost]

        # Step 7: Assign track_ids to return list
        for i, det in enumerate(detections):
            if i in assigned_track_ids:
                det.track_id = assigned_track_ids[i]
            else:
                det.track_id = None

        return detections
