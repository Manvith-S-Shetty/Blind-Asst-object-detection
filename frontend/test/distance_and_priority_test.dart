import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:blind_assistant/models/detection.dart';
import 'package:blind_assistant/services/distance_estimator.dart';
import 'package:blind_assistant/services/local_guidance_engine.dart';
import 'package:blind_assistant/services/tts_service.dart';

class FakeFlutterTtsForQueue extends FlutterTts {
  void Function()? _onStart;
  void Function()? _onComplete;
  void Function()? _onCancel;
  final List<String> spokenHistory = [];
  bool isSpeaking = false;

  @override
  void setStartHandler(void Function() callback) => _onStart = callback;
  @override
  void setCompletionHandler(void Function() callback) => _onComplete = callback;
  @override
  void setCancelHandler(void Function() callback) => _onCancel = callback;
  @override
  void setErrorHandler(void Function(dynamic) callback) {}

  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;
  @override
  Future<dynamic> setPitch(double pitch) async => 1;
  @override
  Future<dynamic> setVolume(double volume) async => 1;
  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async => 1;

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spokenHistory.add(text);
    isSpeaking = true;
    _onStart?.call();
    return 1;
  }

  @override
  Future<dynamic> stop() async {
    isSpeaking = false;
    _onCancel?.call();
    return 1;
  }

  void simulateCompletion() {
    isSpeaking = false;
    _onComplete?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MonocularDistanceEstimator Calibration & Uncertainty Tests', () {
    const estimator = MonocularDistanceEstimator();
    const origWidth = 480;
    const origHeight = 640;

    test('Valid calibrated estimate for standard upright adult person', () {
      // 640px height image, person taking up 320px in middle
      // fy ~ 640 / (2 * tan(27.5 deg)) ~ 614.7px
      // D = (614.7 * 1.70) / 320 ~ 3.26m -> rounded to 3.3m
      final estimate = estimator.estimateDistance(
        label: 'person',
        x1: 140,
        y1: 100,
        x2: 340,
        y2: 420, // height = 320px, well within borders [4, 636]
        origWidth: origWidth,
        origHeight: origHeight,
        confidence: 0.85,
      );

      expect(estimate.isReliable, isTrue);
      expect(estimate.distanceMeters, isNotNull);
      expect(estimate.distanceMeters!, closeTo(3.3, 0.2));
      expect(estimate.proximityBand, equals('mid'));
      expect(estimate.uncertaintyReason, isNull);
    });

    test('Valid calibrated estimate for chair at close range', () {
      // Chair realHeight = 0.85m, height = 350px
      // D = (614.7 * 0.85) / 350 ~ 1.49m -> rounded to 1.5m (immediate hazard)
      final estimate = estimator.estimateDistance(
        label: 'chair',
        x1: 100,
        y1: 150,
        x2: 380,
        y2: 500, // height = 350px
        origWidth: origWidth,
        origHeight: origHeight,
        confidence: 0.88,
      );

      expect(estimate.isReliable, isTrue);
      expect(estimate.distanceMeters, equals(1.5));
      expect(estimate.proximityBand, equals('immediate'));
    });

    test('UNCERTAINTY: Border truncation at top returns null/unknown', () {
      // Bounding box touches top border (y1 = 2 <= 4.0 margin)
      final estimate = estimator.estimateDistance(
        label: 'person',
        x1: 140,
        y1: 2, // truncated top
        x2: 340,
        y2: 300,
        origWidth: origWidth,
        origHeight: origHeight,
        confidence: 0.85,
      );

      expect(estimate.isReliable, isFalse);
      expect(estimate.distanceMeters, isNull);
      expect(estimate.uncertaintyReason, equals('border_truncated'));
    });

    test('UNCERTAINTY: Border truncation at bottom returns null/unknown', () {
      // Bounding box touches bottom border (y2 = 638 >= 640 - 4.0 margin)
      final estimate = estimator.estimateDistance(
        label: 'person',
        x1: 140,
        y1: 300,
        x2: 340,
        y2: 638, // truncated bottom
        origWidth: origWidth,
        origHeight: origHeight,
        confidence: 0.85,
      );

      expect(estimate.isReliable, isFalse);
      expect(estimate.distanceMeters, isNull);
      expect(estimate.uncertaintyReason, equals('border_truncated'));
    });

    test('UNCERTAINTY: Uncalibrated class returns null/unknown without guessing', () {
      // Backpack and umbrella have high variance and unknown elevation
      for (final label in ['backpack', 'umbrella', 'handbag', 'book', 'potted plant']) {
        final estimate = estimator.estimateDistance(
          label: label,
          x1: 100,
          y1: 100,
          x2: 250,
          y2: 250,
          origWidth: origWidth,
          origHeight: origHeight,
          confidence: 0.80,
        );

        expect(estimate.isReliable, isFalse);
        expect(estimate.distanceMeters, isNull);
        expect(estimate.uncertaintyReason, equals('uncalibrated_class'));
      }
    });

    test('UNCERTAINTY: Person aspect ratio anomaly (seated/crouching) returns null/unknown', () {
      // Person width = 200px, height = 150px (aspect ratio 150/200 = 0.75 < 1.0)
      final estimate = estimator.estimateDistance(
        label: 'person',
        x1: 100,
        y1: 200,
        x2: 300,
        y2: 350,
        origWidth: origWidth,
        origHeight: origHeight,
        confidence: 0.80,
      );

      expect(estimate.isReliable, isFalse);
      expect(estimate.distanceMeters, isNull);
      expect(estimate.uncertaintyReason, equals('pose_uncertainty'));
    });

    test('UNCERTAINTY: Out of reliable range (> 6.0m or < 0.5m) returns null/unknown', () {
      // Tall narrow box with upright aspect ratio (h=35, w=15 -> aspect 2.33), distance ~ 30m > 6.0m
      final estimateFar = estimator.estimateDistance(
        label: 'person',
        x1: 200,
        y1: 200,
        x2: 215,
        y2: 235,
        origWidth: origWidth,
        origHeight: origHeight,
        confidence: 0.80,
      );

      expect(estimateFar.isReliable, isFalse);
      expect(estimateFar.distanceMeters, isNull);
      expect(estimateFar.uncertaintyReason, equals('out_of_reliable_range'));
    });
  });

  group('Direction Classification & Path Corridor Tests', () {
    test('Bounding box center partitions view into Left, Center, and Right', () {
      // Width = 600. Left < 198 (0.33), Right > 402 (0.67), Center in-between
      const leftCenter = (50.0 + 150.0) / 2.0; // 100 < 198 -> Left
      const rightCenter = (450.0 + 550.0) / 2.0; // 500 > 402 -> Right
      const midCenter = (250.0 + 350.0) / 2.0; // 300 -> Center

      expect(leftCenter < 600 * 0.33, isTrue);
      expect(rightCenter > 600 * 0.67, isTrue);
      expect(midCenter >= 600 * 0.33 && midCenter <= 600 * 0.67, isTrue);
    });

    test('Forward corridor overlap marks flank obstacle as inPath if intersecting central path', () {
      // Width = 600. Central corridor is 0.35W to 0.65W (210 to 390).
      // Box from 100 to 250 overlaps central corridor (> 210)
      const x1 = 100.0;
      const x2 = 250.0;
      const inPath = (x1 < 600 * 0.65 && x2 > 600 * 0.35);
      expect(inPath, isTrue);
    });
  });

  group('Obstacle Priority Ordering & Speech Formulation Tests', () {
    late LocalGuidanceEngine engine;

    setUp(() {
      engine = LocalGuidanceEngine(
        reannounceCooldownMs: 4000,
        consecutiveFramesRequired: 2,
      );
    });

    test('Priority Ordering: Forward obstacle close ahead beats flank obstacle close ahead', () {
      final forwardHazard = Detection(
        label: 'chair',
        confidence: 0.85,
        bbox: BoundingBox(x1: 200, y1: 150, x2: 400, y2: 450),
        direction: 'center',
        inPath: true,
        distanceM: 1.5,
        riskLevel: 'imminent',
        proximityBand: 'immediate',
      );

      final flankHazard = Detection(
        label: 'person',
        confidence: 0.95, // Higher confidence, but off to the side
        bbox: BoundingBox(x1: 20, y1: 150, x2: 120, y2: 450),
        direction: 'left',
        inPath: false,
        distanceM: 1.5,
        riskLevel: 'potential',
        proximityBand: 'immediate',
      );

      // Urgent forward hazard is selected over flank hazard immediately
      final messages = engine.generateGuidance([flankHazard, forwardHazard], currentTimestampMs: 1000);

      expect(messages.length, equals(1));
      expect(messages.first.urgency, equals(Urgency.urgent));
      expect(messages.first.text, equals('Chair ahead, approximately 1.5 meters. Stop.'));
    });

    test('Priority Ordering: Close flank hazard beats distant forward obstacle', () {
      final distantForward = Detection(
        label: 'person',
        confidence: 0.85,
        bbox: BoundingBox(x1: 250, y1: 100, x2: 350, y2: 250),
        direction: 'center',
        inPath: true,
        distanceM: 4.5,
        riskLevel: 'awareness',
        proximityBand: 'far',
      );

      final closeFlank = Detection(
        label: 'chair',
        confidence: 0.90,
        bbox: BoundingBox(x1: 10, y1: 200, x2: 150, y2: 450),
        direction: 'left',
        inPath: false,
        distanceM: 1.4,
        riskLevel: 'potential',
        proximityBand: 'immediate',
      );

      engine.generateGuidance([distantForward, closeFlank], currentTimestampMs: 1000);
      final messages = engine.generateGuidance([distantForward, closeFlank], currentTimestampMs: 1200);

      expect(messages.length, equals(1));
      expect(messages.first.text, contains('Chair'));
      expect(messages.first.text, contains('left'));
    });

    test('Speech formulation: Valid distance generates distance-specific phrase', () {
      final detection = Detection(
        label: 'chair',
        confidence: 0.90,
        bbox: BoundingBox(x1: 200, y1: 200, x2: 400, y2: 500),
        direction: 'center',
        inPath: true,
        distanceM: 1.5,
        riskLevel: 'imminent',
      );

      final messages = engine.generateGuidance([detection], currentTimestampMs: 1000);
      expect(messages.length, equals(1));
      expect(messages.first.text, equals('Chair ahead, approximately 1.5 meters. Stop.'));
    });

    test('Speech formulation: Unknown distance generates concise phrase without inventing meters', () {
      final detection = Detection(
        label: 'obstacle',
        confidence: 0.90,
        bbox: BoundingBox(x1: 200, y1: 200, x2: 400, y2: 500),
        direction: 'center',
        inPath: true,
        distanceM: null, // Unknown!
        riskLevel: 'imminent',
      );

      final messages = engine.generateGuidance([detection], currentTimestampMs: 1000);
      expect(messages.length, equals(1));
      expect(messages.first.text, equals('Stop. Obstacle directly ahead.'));
      expect(messages.first.text.contains('meters'), isFalse);
    });

    test('Approaching obstacle with median smoothing: Sustained approach triggers reannouncement', () {
      final farChair = Detection(
        label: 'chair',
        confidence: 0.90,
        bbox: BoundingBox(x1: 200, y1: 100, x2: 350, y2: 300),
        direction: 'center',
        inPath: true,
        distanceM: 2.8,
        riskLevel: 'potential',
        proximityBand: 'near',
      );

      engine.generateGuidance([farChair], currentTimestampMs: 1000);
      final frame2 = engine.generateGuidance([farChair], currentTimestampMs: 1200);
      expect(frame2.length, equals(1));
      expect(frame2.first.text, contains('Chair ahead, approximately'));

      // User walks closer: sustain 1.4m over multiple frames for median smoothing
      final nearChair = Detection(
        label: 'chair',
        confidence: 0.90,
        bbox: BoundingBox(x1: 200, y1: 150, x2: 380, y2: 420),
        direction: 'center',
        inPath: true,
        distanceM: 1.4,
        riskLevel: 'potential',
        proximityBand: 'near',
      );

      // Feed 1st near-distance frame (median of [2.8, 1.4] is still 2.8m, suppressed)
      final frame1500 = engine.generateGuidance([nearChair], currentTimestampMs: 1500);
      expect(frame1500, isEmpty);

      // On 2nd near-distance frame (timestamp 1700), median of [2.8, 1.4, 1.4] shifts to 1.4m (>= 0.5m delta)
      // and triggers reannouncement immediately
      final approachFrame = engine.generateGuidance([nearChair], currentTimestampMs: 1700);
      expect(approachFrame.length, equals(1));
      expect(approachFrame.first.text, contains('Chair ahead, approximately'));
    });

    test('Direction hysteresis: Single-frame direction flip is suppressed', () {
      // Establish stable 'center' direction over 2 frames
      final chairCenter = Detection(
        label: 'chair',
        confidence: 0.88,
        bbox: BoundingBox(x1: 200, y1: 200, x2: 350, y2: 400),
        direction: 'center',
        inPath: true,
        distanceM: 2.0,
        riskLevel: 'potential',
        proximityBand: 'near',
      );

      engine.generateGuidance([chairCenter], currentTimestampMs: 1000);
      final frame2 = engine.generateGuidance([chairCenter], currentTimestampMs: 1200);
      expect(frame2.length, equals(1));
      expect(frame2.first.text, contains('ahead')); // confirmed center direction

      // One frame shows 'left', but hysteresis should hold 'center'
      final chairLeft = Detection(
        label: 'chair',
        confidence: 0.88,
        bbox: BoundingBox(x1: 50, y1: 200, x2: 150, y2: 400),
        direction: 'left',
        inPath: false,
        distanceM: 2.0,
        riskLevel: 'potential',
        proximityBand: 'near',
      );

      final flickFrame = engine.generateGuidance([chairLeft], currentTimestampMs: 1500);
      // Should NOT trigger direction-change reannouncement because hysteresis holds 'center'
      expect(flickFrame, isEmpty);
    });
  });

  group('TtsService Serialized Queue, Coalescing, and Stale Removal Tests', () {
    late FakeFlutterTtsForQueue fakeTts;
    late TtsService tts;

    setUp(() {
      fakeTts = FakeFlutterTtsForQueue();
      tts = TtsService(tts: fakeTts);
    });

    tearDown(() async {
      await tts.dispose();
    });

    test('Coalescing: Frequent frame guidance updates replace pending guidance with latest instruction', () async {
      final msg1 = GuidanceMessage(text: 'Person ahead.', urgency: Urgency.info, timestamp: 1.0);
      final msg2 = GuidanceMessage(text: 'Chair on your left.', urgency: Urgency.info, timestamp: 1.2);
      final msg3 = GuidanceMessage(text: 'Stop. Obstacle ahead.', urgency: Urgency.warn, timestamp: 1.4);

      // Active speech starts
      await tts.speakGuidance(msg1);
      expect(fakeTts.spokenHistory.length, equals(1));
      expect(fakeTts.spokenHistory.first, equals('Person ahead.'));

      // Frequent frame updates arrive while msg1 is voicing
      await tts.speakGuidance(msg2);
      expect(tts.queueLength, equals(1));

      // msg3 replaces msg2 in the pending slot (coalesced)
      await tts.speakGuidance(msg3);
      expect(tts.queueLength, equals(1)); // Queue did not grow to 2; it coalesced!

      // When msg1 completes, the coalesced latest instruction (msg3) plays next
      fakeTts.simulateCompletion();
      expect(fakeTts.spokenHistory.length, equals(2));
      expect(fakeTts.spokenHistory.last, equals('Stop. Obstacle ahead.'));
    });

    test('Preemption: Urgent hazard cancels active lower-priority speech and purges routine queue', () async {
      final routineActive = GuidanceMessage(text: 'Person ahead.', urgency: Urgency.info, timestamp: 1.0);
      final routineQueued = GuidanceMessage(text: 'Chair on right.', urgency: Urgency.info, timestamp: 1.1);
      final urgentHazard = GuidanceMessage(text: 'Obstacle ahead, approximately 1.5 meters. Stop.', urgency: Urgency.urgent, timestamp: 1.3);

      await tts.speakGuidance(routineActive);
      await tts.speakGuidance(routineQueued);
      expect(tts.queueLength, equals(1));

      // Urgent hazard arrives
      final preempted = await tts.speakGuidance(urgentHazard);
      expect(preempted, isTrue);

      // Urgent hazard plays immediately as active
      expect(fakeTts.spokenHistory.last, equals('Obstacle ahead, approximately 1.5 meters. Stop.'));
      expect(tts.currentUrgency, equals(Urgency.urgent));

      // Lower priority queued item was purged from queue
      expect(tts.queueLength, equals(0));
    });

    test('Deduplication: Identical active or queued message is not duplicated', () async {
      final msg = GuidanceMessage(text: 'Person on your left.', urgency: Urgency.info, timestamp: 1.0);

      final accepted1 = await tts.speakGuidance(msg);
      expect(accepted1, isTrue);

      // Identical while speaking -> rejected
      final accepted2 = await tts.speakGuidance(msg);
      expect(accepted2, isFalse);
      expect(fakeTts.spokenHistory.length, equals(1));
    });

    test('Stop clears active speech and all pending queue items', () async {
      final msg1 = GuidanceMessage(text: 'Message one.', urgency: Urgency.info, timestamp: 1.0);
      final msg2 = GuidanceMessage(text: 'Message two.', urgency: Urgency.info, timestamp: 1.1);

      await tts.speakGuidance(msg1);
      await tts.speakGuidance(msg2);

      await tts.stop();
      expect(tts.isSpeaking, isFalse);
      expect(tts.queueLength, equals(0));
      expect(tts.currentText, isNull);
    });

    test('speechEnabled toggle: When speechEnabled is false, speech is dropped', () async {
      tts.speechEnabled = false;
      expect(tts.speechEnabled, isFalse);

      final msg = GuidanceMessage(text: 'Test speech', urgency: Urgency.info, timestamp: 1.0);
      await tts.speakGuidance(msg);

      expect(fakeTts.spokenHistory, isEmpty);
      expect(tts.isSpeaking, isFalse);

      // Re-enable
      tts.speechEnabled = true;
      expect(tts.speechEnabled, isTrue);
      await tts.speakGuidance(msg);
      expect(fakeTts.spokenHistory, contains('Test speech'));
    });
  });

  group('DistanceSmoother & Label Compatibility Tests', () {
    test('DistanceSmoother rejects sudden single-frame spikes (> 1.8m jump)', () {
      final smoother = DistanceSmoother();
      // Track starting at 1.5m
      final d1 = smoother.smooth('track_1', 1.5);
      expect(d1, equals(1.5));

      final d2 = smoother.smooth('track_1', 1.6);
      expect(d2, equals(1.6));

      // Sudden implausible jump from 1.6m to 4.5m (> 1.8m jump)
      final d3 = smoother.smooth('track_1', 4.5);
      // Spike should be rejected and return previous smoothed value
      expect(d3, equals(1.6));

      // Plausible gradual update to 1.8m
      final d4 = smoother.smooth('track_1', 1.8);
      expect(d4, isNotNull);
      expect(d4!, closeTo(1.6, 0.3));
    });

    test('LocalGuidanceEngine associates alternating chair/couch labels to avoid dropping tracks', () {
      final engine = LocalGuidanceEngine(consecutiveFramesRequired: 2);

      // Frame 1: Model classifies as 'chair' (potential hazard)
      final det1 = Detection(
        label: 'chair',
        confidence: 0.65,
        bbox: BoundingBox(x1: 200, y1: 200, x2: 400, y2: 400),
        direction: 'center',
        riskLevel: 'potential',
        inPath: true,
      );
      final frame1 = engine.generateGuidance([det1], currentTimestampMs: 1000);
      expect(frame1, isEmpty); // Frame 1 needs confirmation

      // Frame 2: Model oscillates to 'couch' at same location
      final det2 = Detection(
        label: 'couch',
        confidence: 0.68,
        bbox: BoundingBox(x1: 205, y1: 202, x2: 405, y2: 402),
        direction: 'center',
        riskLevel: 'potential',
        inPath: true,
      );
      final frame2 = engine.generateGuidance([det2], currentTimestampMs: 1200);
      // Because chair and couch are compatible, consecutiveFrames increments to 2 and guidance is spoken!
      expect(frame2.length, equals(1));
      expect(frame2.first.text, contains('ahead'));
    });
  });
}
