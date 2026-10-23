/// Mirrors app/models/schemas.py on the backend. Keep field names in sync —
/// they're the API contract between Flutter and FastAPI.
library detection;
class BoundingBox {
  final double x1, y1, x2, y2;

  BoundingBox({required this.x1, required this.y1, required this.x2, required this.y2});

  factory BoundingBox.fromJson(Map<String, dynamic> json) => BoundingBox(
        x1: (json['x1'] as num).toDouble(),
        y1: (json['y1'] as num).toDouble(),
        x2: (json['x2'] as num).toDouble(),
        y2: (json['y2'] as num).toDouble(),
      );
}

class Detection {
  final int? trackId;
  final String label;
  final double confidence;
  final BoundingBox bbox;
  final double? distanceM;
  final String? direction; // "left" | "center" | "right"
  final bool? inPath;
  final String? riskLevel; // "imminent" | "potential" | "awareness" | "negligible"
  final String? proximityBand; // "immediate" | "near" | "mid" | "far" | "unknown"

  Detection({
    this.trackId,
    required this.label,
    required this.confidence,
    required this.bbox,
    this.distanceM,
    this.direction,
    this.inPath,
    this.riskLevel,
    this.proximityBand,
  });

  factory Detection.fromJson(Map<String, dynamic> json) => Detection(
        trackId: json['track_id'] as int?,
        label: json['label'] as String,
        confidence: (json['confidence'] as num).toDouble(),
        bbox: BoundingBox.fromJson(json['bbox'] as Map<String, dynamic>),
        distanceM: (json['distance_m'] as num?)?.toDouble(),
        direction: json['direction'] as String?,
        inPath: json['in_path'] as bool?,
        riskLevel: json['risk_level'] as String?,
        proximityBand: json['proximity_band'] as String?,
      );
}

enum Urgency { info, warn, urgent }

Urgency urgencyFromString(String s) {
  switch (s) {
    case 'urgent':
      return Urgency.urgent;
    case 'warn':
      return Urgency.warn;
    default:
      return Urgency.info;
  }
}

class GuidanceMessage {
  final String text;
  final Urgency urgency;
  final double timestamp;
  final bool isDegraded;

  GuidanceMessage({
    required this.text,
    required this.urgency,
    required this.timestamp,
    this.isDegraded = false,
  });

  factory GuidanceMessage.fromJson(Map<String, dynamic> json) => GuidanceMessage(
        text: json['text'] as String,
        urgency: urgencyFromString(json['urgency'] as String),
        timestamp: (json['timestamp'] as num).toDouble(),
        isDegraded: json['is_degraded'] as bool? ?? false,
      );
}

class FrameResult {
  final String sessionId;
  final int frameId;
  final List<Detection> detections;
  final List<GuidanceMessage> guidance;
  final int? clientTimestampMs;
  final int? frameSeq;

  FrameResult({
    required this.sessionId,
    required this.frameId,
    required this.detections,
    required this.guidance,
    this.clientTimestampMs,
    this.frameSeq,
  });

  factory FrameResult.fromJson(Map<String, dynamic> json) => FrameResult(
        sessionId: json['session_id'] as String,
        frameId: json['frame_id'] as int,
        detections: (json['detections'] as List)
            .map((d) => Detection.fromJson(d as Map<String, dynamic>))
            .toList(),
        guidance: (json['guidance'] as List)
            .map((g) => GuidanceMessage.fromJson(g as Map<String, dynamic>))
            .toList(),
        clientTimestampMs: json['client_timestamp_ms'] as int?,
        frameSeq: json['frame_seq'] as int?,
      );
}
