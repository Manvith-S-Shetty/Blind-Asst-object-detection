import 'dart:math';

/// Represents the result of monocular distance estimation.
class DistanceEstimate {
  /// Estimated real-world distance in meters, or null if uncertain/unreliable.
  final double? distanceMeters;

  /// Whether the distance estimate satisfies all reliability criteria.
  final bool isReliable;

  /// Proximity classification: "immediate", "near", "mid", "far", or "unknown".
  final String proximityBand;

  /// Diagnostic reason if distance estimation was rejected or uncertain.
  final String? uncertaintyReason;

  const DistanceEstimate({
    this.distanceMeters,
    required this.isReliable,
    required this.proximityBand,
    this.uncertaintyReason,
  });

  factory DistanceEstimate.unknown({
    required String proximityBand,
    required String reason,
  }) {
    return DistanceEstimate(
      distanceMeters: null,
      isReliable: false,
      proximityBand: proximityBand,
      uncertaintyReason: reason,
    );
  }

  @override
  String toString() => isReliable
      ? 'DistanceEstimate(~${distanceMeters?.toStringAsFixed(1)}m, band=$proximityBand)'
      : 'DistanceEstimate(unknown, band=$proximityBand, reason=$uncertaintyReason)';
}

/// Calibrated monocular distance estimator based on pinhole camera geometry
/// and bounded physical size priors.
///
/// HARDWARE & PIPELINE DEPTH SENSING INVESTIGATION:
/// Standard smartphone cameras and the Flutter `camera` plugin (^0.11.0) provide
/// only 2D YUV420/RGB preview frames. Android Camera2 `DEPTH16` or Point Cloud streams
/// require specialized hardware (ToF sensors) rarely found on phones and are unsupported
/// by Flutter's camera stream API.
///
/// Therefore, on-device depth estimation must use calibrated monocular geometry.
///
/// GEOMETRIC MODEL:
/// Using pinhole camera projection:
///   D = (f_y * H_real) / h_bbox_px
/// Where:
///   - H_real: Mean real-world vertical height of the object class (meters)
///   - h_bbox_px: Bounding box height in original image pixels
///   - f_y: Vertical focal length in pixels = H_image / (2 * tan(VFOV / 2))
///   - VFOV: Vertical Field of View of typical phone camera in portrait (~55°).
///
/// SAFETY & UNCERTAINTY INVARIANTS:
/// 1. Distance in meters is ONLY provided when class height is well-calibrated,
///    bounding box is untruncated by frame borders, aspect ratio is normal,
///    and calculated distance falls within the reliable range (0.5m - 6.0m).
/// 2. If any condition is violated, distanceMeters is returned as NULL (unknown).
///    We NEVER invent or guess a numeric distance.
class MonocularDistanceEstimator {
  /// Vertical Field of View (VFOV) in radians for typical smartphone portrait cameras (~55°).
  final double verticalFovRadians;

  /// Minimum distance (meters) where pinhole assumptions hold before near-field distortion.
  final double minReliableDistanceMeters;

  /// Maximum distance (meters) before pixel quantization causes unacceptable variance.
  final double maxReliableDistanceMeters;

  /// Edge margin in pixels to detect truncated bounding boxes.
  final double borderMarginPx;

  /// Calibrated physical height priors in meters (mean real-world standing height).
  static const Map<String, double> _classHeightPriors = {
    'person': 1.70,       // Standing adult
    'bicycle': 1.00,      // Ground to handlebars
    'motorcycle': 1.15,   // Ground to mirrors
    'car': 1.50,          // Standard automobile
    'bus': 3.20,          // Standard bus
    'truck': 3.00,        // Standard commercial truck
    'chair': 0.85,        // Standard dining/office chair
    'couch': 0.85,        // Standard sofa backrest
    'dining table': 0.75, // Standard table height
    'toilet': 0.75,       // Standard toilet height
    'bed': 0.65,          // Standard bed height
    'dog': 0.60,          // Medium dog shoulder height
    'fire hydrant': 0.75, // Standard municipal hydrant
    'stop sign': 0.75,    // Standard octagonal face
  };

  const MonocularDistanceEstimator({
    this.verticalFovRadians = 55.0 * (pi / 180.0), // ~55° VFOV
    this.minReliableDistanceMeters = 0.5,
    this.maxReliableDistanceMeters = 6.0,
    this.borderMarginPx = 4.0,
  });

  /// Estimates real-world distance in meters for a detected object.
  ///
  /// Parameters:
  /// - [label]: Detected COCO class label.
  /// - [x1], [y1], [x2], [y2]: Bounding box coordinates clamped to [0, origWidth] x [0, origHeight].
  /// - [origWidth], [origHeight]: Full resolution dimensions of the camera frame.
  /// - [confidence]: YOLO detection confidence score.
  DistanceEstimate estimateDistance({
    required String label,
    required double x1,
    required double y1,
    required double x2,
    required double y2,
    required int origWidth,
    required int origHeight,
    required double confidence,
  }) {
    final boxWidth = max(0.0, x2 - x1);
    final boxHeight = max(0.0, y2 - y1);
    final areaFraction = (boxWidth * boxHeight) / (origWidth * origHeight);
    final heightFraction = boxHeight / origHeight;

    // Fallback proximity band based on visual proportions
    final fallbackBand = _resolveProximityBandByFraction(heightFraction, areaFraction);

    // 1. Check if class has a known physical size prior
    final realHeight = _classHeightPriors[label];
    if (realHeight == null) {
      return DistanceEstimate.unknown(
        proximityBand: fallbackBand,
        reason: 'uncalibrated_class',
      );
    }

    // 2. Reject if bounding box touches top or bottom image borders (truncation)
    // When truncated, visible box height is smaller than true object height,
    // which would cause dangerous over-estimation of distance!
    if (y1 <= borderMarginPx || y2 >= (origHeight - borderMarginPx)) {
      return DistanceEstimate.unknown(
        proximityBand: fallbackBand,
        reason: 'border_truncated',
      );
    }

    // 3. Minimum box height threshold to prevent extreme pixel quantization errors
    if (boxHeight < 15.0) {
      return DistanceEstimate.unknown(
        proximityBand: fallbackBand,
        reason: 'box_too_small',
      );
    }

    // 4. Low confidence rejection — jittery low-confidence detections cannot yield reliable distances
    if (confidence < 0.40) {
      return DistanceEstimate.unknown(
        proximityBand: fallbackBand,
        reason: 'low_confidence',
      );
    }

    // 4. Aspect ratio sanity check for specific classes
    if (label == 'person') {
      final aspectRatio = boxHeight / max(1.0, boxWidth);
      // Upright standing adult typically has height/width >= 1.2.
      // If aspectRatio < 1.0, person is seated, lying down, or heavily occluded.
      if (aspectRatio < 1.0) {
        return DistanceEstimate.unknown(
          proximityBand: fallbackBand,
          reason: 'pose_uncertainty',
        );
      }
    }

    // 5. Pinhole focal length computation
    // f_y = (origHeight / 2) / tan(VFOV / 2)
    final fy = (origHeight / 2.0) / tan(verticalFovRadians / 2.0);

    // D = (f_y * H_real) / h_bbox_px
    final rawDistance = (fy * realHeight) / boxHeight;

    // 6. Range bounds check
    if (rawDistance < minReliableDistanceMeters || rawDistance > maxReliableDistanceMeters) {
      return DistanceEstimate.unknown(
        proximityBand: fallbackBand,
        reason: 'out_of_reliable_range',
      );
    }

    // Round to 1 decimal place (e.g. 1.5m)
    final roundedDistance = (rawDistance * 10).roundToDouble() / 10.0;
    final proximityBand = _resolveProximityBandByMeters(roundedDistance);

    return DistanceEstimate(
      distanceMeters: roundedDistance,
      isReliable: true,
      proximityBand: proximityBand,
    );
  }

  String _resolveProximityBandByMeters(double distanceMeters) {
    if (distanceMeters <= 1.5) {
      return 'immediate';
    } else if (distanceMeters <= 2.5) {
      return 'near';
    } else if (distanceMeters <= 4.0) {
      return 'mid';
    } else {
      return 'far';
    }
  }

  String _resolveProximityBandByFraction(double heightFraction, double areaFraction) {
    if (heightFraction > 0.50 || areaFraction > 0.25) {
      return 'immediate';
    } else if (heightFraction > 0.25 || areaFraction > 0.10) {
      return 'near';
    } else if (heightFraction > 0.12 || areaFraction > 0.04) {
      return 'mid';
    } else {
      return 'far';
    }
  }
}

/// Temporal sliding-window median smoother for per-object distance estimates.
///
/// Reduces frame-to-frame distance jitter caused by bounding-box quantization
/// and minor pose/detection fluctuations. Uses a median filter (robust to
/// outliers) over a configurable sliding window of recent valid estimates.
///
/// When a frame returns null distance (e.g., border truncation), the smoother
/// retains the last valid smoothed distance for up to [graceFrames] consecutive
/// null frames before expiring it. This prevents brief flickers from erasing
/// the user's spatial awareness.
class DistanceSmoother {
  final int windowSize;
  final int graceFrames;

  /// Per-object label+direction key → recent distance history.
  final Map<String, _SmoothingState> _states = {};

  DistanceSmoother({
    this.windowSize = 5,
    this.graceFrames = 3,
  });

  /// Returns a smoothed distance for the given tracking key, or null if
  /// insufficient data or grace period exhausted.
  double? smooth(String trackKey, double? rawDistance) {
    final state = _states.putIfAbsent(trackKey, () => _SmoothingState());

    if (rawDistance != null) {
      // Outlier rejection: reject sudden single-frame spikes (> 1.8m jump)
      if (state.history.isNotEmpty && state.nullStreak == 0) {
        final lastVal = state.history.last;
        if ((rawDistance - lastVal).abs() > 1.8) {
          return state.lastSmoothed;
        }
      }
      state.history.add(rawDistance);
      if (state.history.length > windowSize) {
        state.history.removeAt(0);
      }
      state.nullStreak = 0;
    } else {
      state.nullStreak++;
    }

    // If grace period exhausted, clear history and return null
    if (state.nullStreak > graceFrames) {
      state.history.clear();
      state.lastSmoothed = null;
      return null;
    }

    if (state.history.isEmpty) {
      return state.lastSmoothed; // May be null
    }

    // Median filter: sort a copy and pick the middle value
    final sorted = List<double>.from(state.history)..sort();
    final median = sorted[sorted.length ~/ 2];
    final rounded = (median * 10).roundToDouble() / 10.0;
    state.lastSmoothed = rounded;
    return rounded;
  }

  /// Removes stale tracking entries not updated recently.
  void prune(Set<String> activeKeys) {
    _states.removeWhere((key, _) => !activeKeys.contains(key));
  }

  void reset() {
    _states.clear();
  }
}

class _SmoothingState {
  final List<double> history = [];
  int nullStreak = 0;
  double? lastSmoothed;
}
