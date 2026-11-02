import 'dart:math';
import '../models/detection.dart';
import 'distance_estimator.dart';

/// Represents an obstacle tracked over successive frames.
class TrackedObstacle {
  final String label;
  String direction;
  String proximityBand;
  String riskLevel;
  double confidence;
  BoundingBox bbox;
  double? distanceM;
  bool inPath;

  int consecutiveFrames;
  int firstSeenTimestampMs;
  int lastSeenTimestampMs;

  int? lastAnnouncedTimestampMs;
  String? lastAnnouncedRisk;
  String? lastAnnouncedDirection;
  String? lastAnnouncedProximity;
  double? lastAnnouncedDistanceM;

  TrackedObstacle({
    required this.label,
    required this.direction,
    required this.proximityBand,
    required this.riskLevel,
    required this.confidence,
    required this.bbox,
    this.distanceM,
    this.inPath = false,
    required this.consecutiveFrames,
    required this.firstSeenTimestampMs,
    required this.lastSeenTimestampMs,
    this.lastAnnouncedTimestampMs,
    this.lastAnnouncedRisk,
    this.lastAnnouncedDirection,
    this.lastAnnouncedProximity,
    this.lastAnnouncedDistanceM,
  });

  double get centerX => (bbox.x1 + bbox.x2) / 2.0;
  double get centerY => (bbox.y1 + bbox.y2) / 2.0;
}

/// Generates clear, stable, priority-based voice guidance from on-device detections.
///
/// KEY DESIGN PRINCIPLES:
/// 1. Stability: Temporal confirmation prevents 1-frame false positives from triggering speech.
/// 2. Single Guidance Instruction: Only the single most actionable obstacle is chosen.
/// 3. Priority Ordering: Forward path obstacles and closer obstacles are prioritized over flank/distant ones.
/// 4. Deduplication: Unchanged obstacles are suppressed until cooldown, distance change, or hazard escalation.
/// 5. Safe, Natural Speech: Short instructions; distance-specific phrases are generated ONLY from valid
///    estimates; never invents distance numbers when uncertain; never claims path is clear when 0 objects detected.
class LocalGuidanceEngine {
  final int reannounceCooldownMs;
  final int consecutiveFramesRequired;
  final int trackExpiryMs;
  /// Number of consecutive same-direction frames before accepting a direction change.
  final int directionHysteresisFrames;

  final Map<String, TrackedObstacle> _activeTracks = {};
  int _nextTrackId = 1;
  final DistanceSmoother _distanceSmoother = DistanceSmoother();

  /// Per-track direction hysteresis buffers: trackKey → (candidateDirection, consecutiveCount)
  final Map<String, _DirectionHysteresis> _directionHysteresis = {};

  LocalGuidanceEngine({
    this.reannounceCooldownMs = 5000,
    this.consecutiveFramesRequired = 2,
    this.trackExpiryMs = 1500,
    this.directionHysteresisFrames = 2,
  });

  /// Evaluates detections, updates temporal tracking, and produces at most
  /// one high-priority [GuidanceMessage] per cycle.
  List<GuidanceMessage> generateGuidance(
    List<Detection> detections, {
    int? currentTimestampMs,
  }) {
    final now = currentTimestampMs ?? DateTime.now().millisecondsSinceEpoch;

    // 1. Update temporal tracks with incoming detections
    _updateTracks(detections, now);

    // 2. SAFETY INVARIANT: If no confirmed obstacles exist, return empty list.
    // NEVER claim the area is safe or clear!
    final confirmedTracks = _getConfirmedTracks(now);
    if (confirmedTracks.isEmpty) {
      return const [];
    }

    // 3. Sort confirmed obstacles by priority rank
    confirmedTracks.sort((a, b) {
      final rankA = _priorityRank(a);
      final rankB = _priorityRank(b);
      if (rankA != rankB) return rankA.compareTo(rankB);

      // Tie-breaker 1: Closer distance first (if both have estimated distance)
      if (a.distanceM != null && b.distanceM != null) {
        final distComp = a.distanceM!.compareTo(b.distanceM!);
        if (distComp != 0) return distComp;
      } else if (a.distanceM != null) {
        return -1;
      } else if (b.distanceM != null) {
        return 1;
      }

      // Tie-breaker 2: More persistent track (higher consecutiveFrames)
      if (a.consecutiveFrames != b.consecutiveFrames) {
        return b.consecutiveFrames.compareTo(a.consecutiveFrames);
      }

      // Tie-breaker 3: Higher confidence
      return b.confidence.compareTo(a.confidence);
    });

    // 4. Select the highest priority candidate and evaluate deduplication
    for (final candidate in confirmedTracks) {
      final shouldAnnounce = _shouldAnnounceCandidate(candidate, now);
      if (!shouldAnnounce) {
        continue;
      }

      // Mark candidate as announced
      candidate.lastAnnouncedTimestampMs = now;
      candidate.lastAnnouncedRisk = candidate.riskLevel;
      candidate.lastAnnouncedDirection = candidate.direction;
      candidate.lastAnnouncedProximity = candidate.proximityBand;
      candidate.lastAnnouncedDistanceM = candidate.distanceM;

      final urgency = _resolveUrgency(candidate.riskLevel);
      final text = _formulateNaturalSpeech(candidate, urgency);

      // Return exactly one single clear guidance message
      return [
        GuidanceMessage(
          text: text,
          urgency: urgency,
          timestamp: now / 1000.0,
        ),
      ];
    }

    return const [];
  }

  /// Updates existing obstacle tracks or adds new ones based on spatial/label proximity.
  void _updateTracks(List<Detection> detections, int now) {
    final matchedTrackKeys = <String>{};

    for (final det in detections) {
      final detCenterX = (det.bbox.x1 + det.bbox.x2) / 2.0;
      final detCenterY = (det.bbox.y1 + det.bbox.y2) / 2.0;

      String? bestTrackKey;
      double bestDistance = double.infinity;

      for (final entry in _activeTracks.entries) {
        if (matchedTrackKeys.contains(entry.key)) continue;
        final track = entry.value;

        // Class label compatibility (handles YOLO flicker between similar classes)
        final isLabelMatch = track.label == det.label || _areLabelsCompatible(track.label, det.label);
        if (!isLabelMatch) continue;

        // Check spatial proximity (Euclidean distance between center points)
        final dx = track.centerX - detCenterX;
        final dy = track.centerY - detCenterY;
        final dist = sqrt(dx * dx + dy * dy);

        // Bounding box IoU
        final interX1 = max(track.bbox.x1, det.bbox.x1);
        final interY1 = max(track.bbox.y1, det.bbox.y1);
        final interX2 = min(track.bbox.x2, det.bbox.x2);
        final interY2 = min(track.bbox.y2, det.bbox.y2);
        final interArea = max(0.0, interX2 - interX1) * max(0.0, interY2 - interY1);
        final boxAreaA = max(0.0, track.bbox.x2 - track.bbox.x1) * max(0.0, track.bbox.y2 - track.bbox.y1);
        final boxAreaB = max(0.0, det.bbox.x2 - det.bbox.x1) * max(0.0, det.bbox.y2 - det.bbox.y1);
        final unionArea = boxAreaA + boxAreaB - interArea;
        final iou = unionArea > 0 ? interArea / unionArea : 0.0;

        // Dynamic spatial association distance scaled to frame dimensions
        final maxSpatialDist = max(260.0, (det.frameWidth ?? 640) * 0.40);
        if ((iou > 0.25 || dist < maxSpatialDist) && dist < bestDistance) {
          bestDistance = dist;
          bestTrackKey = entry.key;
        }
      }

      if (bestTrackKey != null) {
        // Matched an existing track — increment consecutive frame count
        final track = _activeTracks[bestTrackKey]!;
        track.bbox = det.bbox;

        // Direction hysteresis: only accept a direction change after it has been
        // consistently observed for directionHysteresisFrames consecutive frames.
        // This prevents left↔center↔right flickering near the 0.33/0.67 boundaries.
        final rawDirection = det.direction ?? track.direction;
        final hysteresis = _directionHysteresis.putIfAbsent(
          bestTrackKey,
          () => _DirectionHysteresis(track.direction),
        );
        if (rawDirection != track.direction) {
          // Candidate direction differs from current stable direction
          if (rawDirection == hysteresis.candidateDirection) {
            hysteresis.consecutiveCount++;
          } else {
            hysteresis.candidateDirection = rawDirection;
            hysteresis.consecutiveCount = 1;
          }
          if (hysteresis.consecutiveCount >= directionHysteresisFrames) {
            track.direction = rawDirection;
            hysteresis.candidateDirection = rawDirection;
            hysteresis.consecutiveCount = 0;
          }
          // else: keep the current stable direction
        } else {
          hysteresis.candidateDirection = rawDirection;
          hysteresis.consecutiveCount = 0;
        }

        track.proximityBand = det.proximityBand ?? track.proximityBand;
        track.riskLevel = det.riskLevel ?? track.riskLevel;
        track.confidence = det.confidence;
        track.inPath = det.inPath ?? track.inPath;

        // Temporal median-filter smoothing for distance estimates
        final smoothedDist = _distanceSmoother.smooth(bestTrackKey, det.distanceM);
        track.distanceM = smoothedDist;

        track.consecutiveFrames++;
        track.lastSeenTimestampMs = now;
        matchedTrackKeys.add(bestTrackKey);
      } else {
        // New track observed
        final newKey = 'track_${_nextTrackId++}';
        _activeTracks[newKey] = TrackedObstacle(
          label: det.label,
          direction: det.direction ?? 'center',
          proximityBand: det.proximityBand ?? 'unknown',
          riskLevel: det.riskLevel ?? 'awareness',
          confidence: det.confidence,
          bbox: det.bbox,
          distanceM: det.distanceM,
          inPath: det.inPath ?? (det.direction == 'center'),
          consecutiveFrames: 1,
          firstSeenTimestampMs: now,
          lastSeenTimestampMs: now,
        );
        matchedTrackKeys.add(newKey);
      }
    }

    // Prune tracks not observed recently (age-out)
    _activeTracks.removeWhere(
      (key, track) => now - track.lastSeenTimestampMs > trackExpiryMs,
    );

    // Prune distance smoother and direction hysteresis for expired tracks
    final activeKeys = _activeTracks.keys.toSet();
    _distanceSmoother.prune(activeKeys);
    _directionHysteresis.removeWhere((key, _) => !activeKeys.contains(key));
  }

  /// Filters tracked obstacles that meet the consecutive-frame stability threshold.
  List<TrackedObstacle> _getConfirmedTracks(int now) {
    final result = <TrackedObstacle>[];
    for (final track in _activeTracks.values) {
      final isImminent = track.riskLevel == 'imminent';

      // Urgent imminent hazards: Immediate responsiveness if high confidence (>=0.50)
      // or verified in consecutive frames.
      if (isImminent) {
        if (track.confidence >= 0.50 || track.consecutiveFrames >= consecutiveFramesRequired) {
          result.add(track);
        }
      }
      // Non-urgent obstacles: Require consecutive-frame verification to suppress noise
      else {
        if (track.consecutiveFrames >= consecutiveFramesRequired) {
          result.add(track);
        }
      }
    }
    return result;
  }

  /// Priority Rank:
  /// Rank 0: Imminent hazard directly in forward path (<= 1.5m or imminent in path)
  /// Rank 1: Imminent hazard on flanks (<= 1.5m or imminent on side)
  /// Rank 2: Potential hazard in forward path (1.5m - 2.5m or potential in path)
  /// Rank 3: Potential hazard on flanks (1.5m - 2.5m or potential on side)
  /// Rank 4: General awareness in forward path (> 2.5m)
  /// Rank 5: General awareness on flanks
  int _priorityRank(TrackedObstacle track) {
    final inForwardPath = track.inPath || track.direction == 'center';
    final dist = track.distanceM;

    // Rank 0: Immediate forward hazard
    if (inForwardPath && ((dist != null && dist <= 1.5) || track.riskLevel == 'imminent')) {
      return 0;
    }

    // Rank 1: Imminent hazard on flanks
    if (!inForwardPath && ((dist != null && dist <= 1.5) || track.riskLevel == 'imminent')) {
      return 1;
    }

    // Rank 2: Potential forward hazard
    if (inForwardPath && ((dist != null && dist <= 2.5) || track.riskLevel == 'potential')) {
      return 2;
    }

    // Rank 3: Potential hazard on flanks
    if (!inForwardPath && ((dist != null && dist <= 2.5) || track.riskLevel == 'potential')) {
      return 3;
    }

    // Rank 4: Awareness in forward path
    if (inForwardPath) {
      return 4;
    }

    // Rank 5: Awareness on flanks
    return 5;
  }

  /// Checks deduplication rules:
  /// - New obstacle: announce.
  /// - Risk escalated (e.g. potential -> imminent): announce immediately.
  /// - Direction changed (e.g. left -> center): announce immediately.
  /// - Proximity escalated (e.g. mid -> near / immediate): announce immediately.
  /// - Significant distance approach (distance decreased by >= 0.8m): announce immediately.
  /// - Cooldown expired: announce.
  /// - Otherwise: suppress.
  bool _shouldAnnounceCandidate(TrackedObstacle track, int now) {
    // 1. Never announced before
    if (track.lastAnnouncedTimestampMs == null) {
      return true;
    }

    // 2. Risk level increased (e.g., from potential to imminent)
    if (_riskTier(track.riskLevel) > _riskTier(track.lastAnnouncedRisk)) {
      return true;
    }

    // 3. Direction changed significantly
    if (track.direction != track.lastAnnouncedDirection) {
      return true;
    }

    // 4. Proximity escalated significantly
    if (_proximityTier(track.proximityBand) > _proximityTier(track.lastAnnouncedProximity)) {
      return true;
    }

    // 5. Approaching hazard: distance decreased significantly (>= 0.35m)
    if (track.distanceM != null && track.lastAnnouncedDistanceM != null) {
      if ((track.lastAnnouncedDistanceM! - track.distanceM!) >= 0.35) {
        return true;
      }
    }

    // 6. Cooldown expired
    final isUrgent = track.riskLevel == 'imminent';
    // Urgent warnings reannounce faster (2.0s) if path remains blocked
    final cooldown = isUrgent ? min(2000, reannounceCooldownMs) : reannounceCooldownMs;
    final elapsed = now - track.lastAnnouncedTimestampMs!;
    if (elapsed >= cooldown) {
      return true;
    }

    return false;
  }

  int _riskTier(String? risk) {
    switch (risk) {
      case 'imminent':
        return 3;
      case 'potential':
        return 2;
      case 'awareness':
        return 1;
      default:
        return 0;
    }
  }

  int _proximityTier(String? prox) {
    switch (prox) {
      case 'immediate':
        return 3;
      case 'near':
        return 2;
      case 'mid':
        return 1;
      default:
        return 0;
    }
  }

  Urgency _resolveUrgency(String riskLevel) {
    switch (riskLevel) {
      case 'imminent':
        return Urgency.urgent;
      case 'potential':
        return Urgency.warn;
      default:
        return Urgency.info;
    }
  }

  /// Formulates concise, natural instructions.
  /// Adheres strictly to Requirements:
  /// - If distance is valid: "Obstacle ahead, approximately 1.5 meters. Stop."
  ///   or "[Label] on your left, approximately 2.0 meters."
  /// - If distance is uncertain: "[Label] on your left.", "Stop. [Label] directly ahead."
  /// - Never claims an area is safe or clear.
  /// - Never suggests turning without real sensor evidence.
  String _formulateNaturalSpeech(TrackedObstacle track, Urgency urgency) {
    final label = track.label.isNotEmpty
        ? '${track.label[0].toUpperCase()}${track.label.substring(1)}'
        : 'Obstacle';

    // 1. Valid calibrated distance available
    if (track.distanceM != null) {
      final distStr = 'approximately ${track.distanceM!.toStringAsFixed(1)} meters';

      if (urgency == Urgency.urgent) {
        if (track.direction == 'center' || track.inPath) {
          return '$label ahead, $distStr. Stop.';
        } else {
          return 'Stop. $label on your ${track.direction}, $distStr.';
        }
      }

      if (urgency == Urgency.warn) {
        if (track.direction == 'center' || track.inPath) {
          return '$label ahead, $distStr. Proceed cautiously.';
        } else {
          return '$label on your ${track.direction}, $distStr. Proceed cautiously.';
        }
      }

      // Urgency.info
      if (track.direction == 'center' || track.inPath) {
        return '$label ahead, $distStr.';
      }
      return '$label on your ${track.direction}, $distStr.';
    }

    // 2. Distance unknown / uncalibrated — NEVER invent a numeric measurement
    if (urgency == Urgency.urgent) {
      if (track.direction == 'center' || track.inPath) {
        return 'Stop. $label directly ahead.';
      } else {
        return 'Stop. $label close on your ${track.direction}.';
      }
    }

    if (urgency == Urgency.warn) {
      if (track.direction == 'center' || track.inPath) {
        return '$label ahead. Move cautiously.';
      } else {
        return '$label on your ${track.direction}. Caution.';
      }
    }

    // Urgency.info
    if (track.direction == 'center' || track.inPath) {
      return '$label ahead.';
    }
    return '$label on your ${track.direction}.';
  }

  /// Determines if two labels are semantically similar classes that YOLO may oscillate between.
  bool _areLabelsCompatible(String a, String b) {
    if (a == b) {
      return true;
    }
    if ((a == 'chair' && b == 'couch') || (a == 'couch' && b == 'chair')) {
      return true;
    }
    if ((a == 'car' && (b == 'truck' || b == 'bus')) ||
        (a == 'truck' && (b == 'car' || b == 'bus')) ||
        (a == 'bus' && (b == 'car' || b == 'truck'))) {
      return true;
    }
    if ((a == 'motorcycle' && b == 'bicycle') || (a == 'bicycle' && b == 'motorcycle')) {
      return true;
    }
    return false;
  }

  /// Resets all tracked obstacles and state memory (e.g. when navigation stops).
  void reset() {
    _activeTracks.clear();
    _nextTrackId = 1;
    _distanceSmoother.reset();
    _directionHysteresis.clear();
  }
}

/// Tracks candidate direction changes for hysteresis filtering.
class _DirectionHysteresis {
  String candidateDirection;
  int consecutiveCount = 0;

  _DirectionHysteresis(this.candidateDirection);
}
