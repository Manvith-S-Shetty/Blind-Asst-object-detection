import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blind_assistant/models/detection.dart';
import 'package:blind_assistant/widgets/guidance_banner.dart';

void main() {
  group('Model serialization and parsing', () {
    test('BoundingBox parses correctly', () {
      final json = {'x1': 10.5, 'y1': 20.0, 'x2': 100.5, 'y2': 200.0};
      final bbox = BoundingBox.fromJson(json);
      expect(bbox.x1, 10.5);
      expect(bbox.y1, 20.0);
      expect(bbox.x2, 100.5);
      expect(bbox.y2, 200.0);
    });

    test('Detection with track_id and distance parses correctly', () {
      final json = {
        'track_id': 3,
        'label': 'chair',
        'confidence': 0.88,
        'bbox': {'x1': 0, 'y1': 0, 'x2': 50, 'y2': 50},
        'distance_m': 1.45,
        'direction': 'left',
        'in_path': true,
        'risk_level': 'potential',
        'proximity_band': 'near',
      };
      final detection = Detection.fromJson(json);
      expect(detection.trackId, 3);
      expect(detection.label, 'chair');
      expect(detection.confidence, 0.88);
      expect(detection.distanceM, 1.45);
      expect(detection.direction, 'left');
      expect(detection.inPath, true);
      expect(detection.riskLevel, 'potential');
      expect(detection.proximityBand, 'near');
    });

    test('FrameResult parses detections and guidance', () {
      final json = {
        'session_id': 'sess_123',
        'frame_id': 42,
        'detections': [
          {
            'track_id': 1,
            'label': 'person',
            'confidence': 0.95,
            'bbox': {'x1': 10, 'y1': 10, 'x2': 100, 'y2': 200},
            'distance_m': 0.7,
            'direction': 'center',
          }
        ],
        'guidance': [
          {
            'text': 'Stop! person 0.7m directly ahead',
            'urgency': 'urgent',
            'timestamp': 1700000000.0,
          }
        ],
        'client_timestamp_ms': 1729620000123,
        'frame_seq': 7,
      };
      final frameResult = FrameResult.fromJson(json);
      expect(frameResult.sessionId, 'sess_123');
      expect(frameResult.frameId, 42);
      expect(frameResult.clientTimestampMs, 1729620000123);
      expect(frameResult.frameSeq, 7);
      expect(frameResult.detections.length, 1);
      expect(frameResult.guidance.length, 1);
      expect(frameResult.guidance.first.urgency, Urgency.urgent);
    });
  });

  group('GuidanceBanner widget', () {
    testWidgets('Displays placeholder when no messages', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GuidanceBanner(messages: []),
          ),
        ),
      );
      expect(find.textContaining('Listening'), findsOneWidget);
    });

    testWidgets('Displays urgent and warn guidance messages with semantics', (tester) async {
      final messages = [
        GuidanceMessage(
          text: 'Stop! Obstacle ahead',
          urgency: Urgency.urgent,
          timestamp: 12345.0,
        ),
        GuidanceMessage(
          text: 'Caution, table on left',
          urgency: Urgency.warn,
          timestamp: 12346.0,
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GuidanceBanner(messages: messages),
          ),
        ),
      );

      expect(find.text('Stop! Obstacle ahead'), findsOneWidget);
      expect(find.text('Caution, table on left'), findsOneWidget);
    });
  });
}
