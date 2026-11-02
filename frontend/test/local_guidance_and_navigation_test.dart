import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:blind_assistant/core/app_settings.dart';
import 'package:blind_assistant/core/providers.dart';
import 'package:blind_assistant/features/navigation/navigation_controller.dart';
import 'package:blind_assistant/features/navigation/navigation_screen.dart';
import 'package:blind_assistant/models/detection.dart';
import 'package:blind_assistant/services/backend_connection_manager.dart';
import 'package:blind_assistant/services/local_detector.dart';
import 'package:blind_assistant/services/local_guidance_engine.dart';
import 'package:blind_assistant/services/tts_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeFlutterTts extends FlutterTts {
  void Function()? _onStart;
  void Function()? _onComplete;
  void Function()? _onCancel;
  void Function(dynamic)? _onError;
  final List<String> spokenHistory = [];
  bool isSpeaking = false;

  @override
  void setStartHandler(void Function() callback) => _onStart = callback;
  @override
  void setCompletionHandler(void Function() callback) =>
      _onComplete = callback;
  @override
  void setCancelHandler(void Function() callback) => _onCancel = callback;
  @override
  void setErrorHandler(void Function(dynamic) callback) =>
      _onError = callback;

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

  void simulateError(dynamic error) {
    isSpeaking = false;
    _onError?.call(error);
  }
}

class MockTtsService extends TtsService {
  final List<String> spokenMessages = [];

  @override
  Future<bool> speak(
    String text, {
    bool interrupt = false,
    Urgency urgency = Urgency.info,
  }) async {
    spokenMessages.add(text);
    return true;
  }

  @override
  Future<bool> speakGuidance(GuidanceMessage message) async {
    spokenMessages.add(message.text);
    return true;
  }

  @override
  Future<void> stop() async {
    spokenMessages.add('[STOPPED]');
  }
}

class MockLocalDetector extends LocalDetector {
  bool _mockInitialized;
  final String? _mockError;

  MockLocalDetector({bool initialized = true, String? error})
      : _mockInitialized = initialized,
        _mockError = error;

  @override
  bool get isInitialized => _mockInitialized;

  @override
  String? get lastError => _mockError;

  @override
  Future<void> initialize({
    String modelAsset = 'assets/models/yolo11n_float16.tflite',
    String labelsAsset = 'assets/models/labels.txt',
    int numThreads = 4,
    bool useIsolate = true,
  }) async {
    if (_mockError != null) {
      _mockInitialized = false;
      throw StateError(_mockError);
    }
    _mockInitialized = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('LocalGuidanceEngine Stability & Guidance Rules', () {
    late LocalGuidanceEngine engine;

    setUp(() {
      engine = LocalGuidanceEngine(
        reannounceCooldownMs: 3000,
        consecutiveFramesRequired: 2,
      );
    });

    test('SAFETY: Empty detections produces 0 messages (never claims safe or clear)', () {
      final messages = engine.generateGuidance(const []);
      expect(messages, isEmpty);
      for (final m in messages) {
        expect(m.text.toLowerCase().contains('safe'), isFalse);
        expect(m.text.toLowerCase().contains('clear'), isFalse);
      }
    });

    test('Urgent imminent hazard produces immediate concise alert without delay', () {
      final detections = [
        Detection(
          label: 'chair',
          confidence: 0.90,
          bbox: BoundingBox(x1: 100, y1: 100, x2: 300, y2: 400),
          direction: 'center',
          riskLevel: 'imminent',
          proximityBand: 'immediate',
          inPath: true,
        ),
      ];

      final messages = engine.generateGuidance(detections, currentTimestampMs: 1000);
      expect(messages.length, equals(1));
      expect(messages.first.urgency, equals(Urgency.urgent));
      expect(messages.first.text, equals('Stop. Chair directly ahead.'));
    });

    test('Flank urgent hazard warns with side', () {
      final detections = [
        Detection(
          label: 'chair',
          confidence: 0.90,
          bbox: BoundingBox(x1: 20, y1: 100, x2: 120, y2: 400),
          direction: 'left',
          riskLevel: 'imminent',
          proximityBand: 'immediate',
          inPath: false,
        ),
      ];

      final messages = engine.generateGuidance(detections, currentTimestampMs: 1000);
      expect(messages.length, equals(1));
      expect(messages.first.urgency, equals(Urgency.urgent));
      expect(messages.first.text, equals('Stop. Chair close on your left.'));
    });

    test('Temporal Stability: 1-frame non-urgent detection is suppressed until confirmed across consecutive frames', () {
      final detection = Detection(
        label: 'couch',
        confidence: 0.65,
        bbox: BoundingBox(x1: 200, y1: 200, x2: 400, y2: 400),
        direction: 'center',
        riskLevel: 'potential',
        proximityBand: 'near',
        inPath: true,
      );

      // Frame 1: consecutiveFrames = 1 (< 2 required) -> no announcement
      final frame1 = engine.generateGuidance([detection], currentTimestampMs: 1000);
      expect(frame1, isEmpty);

      // Frame 2: consecutiveFrames = 2 (confirmed) -> generates announcement
      final frame2 = engine.generateGuidance([detection], currentTimestampMs: 1200);
      expect(frame2.length, equals(1));
      expect(frame2.first.text, equals('Couch ahead. Move cautiously.'));
      expect(frame2.first.urgency, equals(Urgency.warn));
    });

    test('Simultaneous detections: Single most actionable, highest-priority hazard selected', () {
      // 3 simultaneous detections in the same frame
      final detections = [
        // Awareness: far person
        Detection(
          label: 'person',
          confidence: 0.80,
          bbox: BoundingBox(x1: 450, y1: 50, x2: 550, y2: 200),
          direction: 'right',
          riskLevel: 'awareness',
          proximityBand: 'mid',
        ),
        // Potential: desk on left
        Detection(
          label: 'dining table',
          confidence: 0.75,
          bbox: BoundingBox(x1: 10, y1: 200, x2: 150, y2: 350),
          direction: 'left',
          riskLevel: 'potential',
          proximityBand: 'near',
        ),
        // Imminent: chair directly ahead
        Detection(
          label: 'chair',
          confidence: 0.88,
          bbox: BoundingBox(x1: 220, y1: 250, x2: 420, y2: 500),
          direction: 'center',
          riskLevel: 'imminent',
          proximityBand: 'immediate',
          inPath: true,
        ),
      ];

      // High confidence imminent hazard responds immediately
      final messages = engine.generateGuidance(detections, currentTimestampMs: 1000);

      // Exactly ONE guidance message returned (not 3)
      expect(messages.length, equals(1));
      // Prioritizes immediate hazard ahead over desk and person
      expect(messages.first.text, equals('Stop. Chair directly ahead.'));
      expect(messages.first.urgency, equals(Urgency.urgent));
    });

    test('Deduplication: Repeated identical frames suppress repetitive speech', () {
      final detection = Detection(
        label: 'bed',
        confidence: 0.85,
        bbox: BoundingBox(x1: 200, y1: 200, x2: 400, y2: 400),
        direction: 'center',
        riskLevel: 'imminent',
        proximityBand: 'immediate',
        inPath: true,
      );

      // First frame -> announces
      final frame1 = engine.generateGuidance([detection], currentTimestampMs: 1000);
      expect(frame1.length, equals(1));
      expect(frame1.first.text, equals('Stop. Bed directly ahead.'));

      // Next frame at t=1200ms -> identical, suppressed
      final frame2 = engine.generateGuidance([detection], currentTimestampMs: 1200);
      expect(frame2, isEmpty);

      // Next frame at t=1500ms -> still suppressed
      final frame3 = engine.generateGuidance([detection], currentTimestampMs: 1500);
      expect(frame3, isEmpty);
    });

    test('Direction change: Shifting direction reannounces immediately', () {
      final chairLeft = Detection(
        label: 'chair',
        confidence: 0.88,
        bbox: BoundingBox(x1: 50, y1: 200, x2: 150, y2: 400),
        direction: 'left',
        riskLevel: 'potential',
        proximityBand: 'near',
      );

      // First frame (needs 2 frames for non-urgent potential)
      engine.generateGuidance([chairLeft], currentTimestampMs: 1000);
      final frame2 = engine.generateGuidance([chairLeft], currentTimestampMs: 1200);
      expect(frame2.length, equals(1));
      expect(frame2.first.text, equals('Chair on your left. Caution.'));

      // Obstacle shifts to center
      final chairCenter = Detection(
        label: 'chair',
        confidence: 0.88,
        bbox: BoundingBox(x1: 200, y1: 200, x2: 350, y2: 400),
        direction: 'center',
        riskLevel: 'potential',
        proximityBand: 'near',
      );

      // Confirmed across directionHysteresisFrames = 2
      engine.generateGuidance([chairCenter], currentTimestampMs: 1500);
      final shifted = engine.generateGuidance([chairCenter], currentTimestampMs: 1700);
      expect(shifted.length, equals(1));
      expect(shifted.first.text, equals('Chair ahead. Move cautiously.'));
    });

    test('Risk escalation: Upgrading from potential to imminent reannounces immediately', () {
      final potentialChair = Detection(
        label: 'chair',
        confidence: 0.85,
        bbox: BoundingBox(x1: 220, y1: 200, x2: 380, y2: 350),
        direction: 'center',
        riskLevel: 'potential',
        proximityBand: 'near',
      );

      engine.generateGuidance([potentialChair], currentTimestampMs: 1000);
      final frame2 = engine.generateGuidance([potentialChair], currentTimestampMs: 1200);
      expect(frame2.length, equals(1));
      expect(frame2.first.text, equals('Chair ahead. Move cautiously.'));

      // User steps closer: escalates to imminent
      final imminentChair = Detection(
        label: 'chair',
        confidence: 0.90,
        bbox: BoundingBox(x1: 200, y1: 200, x2: 420, y2: 500),
        direction: 'center',
        riskLevel: 'imminent',
        proximityBand: 'immediate',
      );

      final escalated = engine.generateGuidance([imminentChair], currentTimestampMs: 1400);
      expect(escalated.length, equals(1));
      expect(escalated.first.text, equals('Stop. Chair directly ahead.'));
      expect(escalated.first.urgency, equals(Urgency.urgent));
    });

    test('Cooldown: Expiration reannounces unchanged obstacle', () {
      final detection = Detection(
        label: 'person',
        confidence: 0.88,
        bbox: BoundingBox(x1: 200, y1: 200, x2: 400, y2: 400),
        direction: 'center',
        riskLevel: 'imminent',
      );

      final first = engine.generateGuidance([detection], currentTimestampMs: 1000);
      expect(first, isNotEmpty);

      // Within cooldown (< 2500ms for imminent) -> suppressed
      final second = engine.generateGuidance([detection], currentTimestampMs: 2500);
      expect(second, isEmpty);

      // After cooldown (> 2500ms) -> reannounced
      final third = engine.generateGuidance([detection], currentTimestampMs: 4000);
      expect(third, isNotEmpty);
    });

    test('Reset clears tracking history', () {
      final detection = Detection(
        label: 'table',
        confidence: 0.85,
        bbox: BoundingBox(x1: 200, y1: 200, x2: 400, y2: 400),
        direction: 'center',
        riskLevel: 'imminent',
      );

      final first = engine.generateGuidance([detection], currentTimestampMs: 1000);
      expect(first, isNotEmpty);

      engine.reset();

      // Immediately eligible after reset
      final second = engine.generateGuidance([detection], currentTimestampMs: 1100);
      expect(second, isNotEmpty);
    });

    test('Guidance speech never directs arbitrary turning', () {
      final detections = [
        Detection(label: 'chair', confidence: 0.8, direction: 'left', riskLevel: 'potential', bbox: BoundingBox(x1: 0, y1: 0, x2: 100, y2: 100)),
        Detection(label: 'person', confidence: 0.8, direction: 'right', riskLevel: 'potential', bbox: BoundingBox(x1: 0, y1: 0, x2: 100, y2: 100)),
      ];

      for (final d in detections) {
        engine.reset();
        engine.generateGuidance([d], currentTimestampMs: 1000);
        final g = engine.generateGuidance([d], currentTimestampMs: 1200);
        for (final m in g) {
          expect(m.text.toLowerCase().contains('turn left'), isFalse);
          expect(m.text.toLowerCase().contains('turn right'), isFalse);
          expect(m.text.toLowerCase().contains('move right'), isFalse);
          expect(m.text.toLowerCase().contains('move left'), isFalse);
        }
      }
    });
  });

  group('TtsService Lifecycle & Priority Preemption', () {
    late FakeFlutterTts fakeTts;
    late TtsService tts;

    setUp(() {
      fakeTts = FakeFlutterTts();
      tts = TtsService(tts: fakeTts);
    });

    tearDown(() async {
      await tts.dispose();
    });

    test('Single speech queue: Serializes and plays ordinary queued messages once active message finishes', () async {
      final infoMsg1 = GuidanceMessage(
        text: 'Person ahead.',
        urgency: Urgency.info,
        timestamp: 1.0,
      );
      final infoMsg2 = GuidanceMessage(
        text: 'Chair on your left.',
        urgency: Urgency.info,
        timestamp: 1.2,
      );

      final spoke1 = await tts.speakGuidance(infoMsg1);
      expect(spoke1, isTrue);
      expect(tts.isSpeaking, isTrue);
      expect(tts.currentUrgency, equals(Urgency.info));

      // Second info message while speaking is queued, not concurrently spoken
      final spoke2 = await tts.speakGuidance(infoMsg2);
      expect(spoke2, isTrue);
      expect(tts.queueLength, equals(1));
      expect(fakeTts.spokenHistory.length, equals(1));
      expect(fakeTts.spokenHistory.first, equals('Person ahead.'));

      // Active message finishes -> queued message plays
      fakeTts.simulateCompletion();
      expect(fakeTts.spokenHistory.length, equals(2));
      expect(fakeTts.spokenHistory.last, equals('Chair on your left.'));
    });

    test('Urgent interruption: Urgent hazard interrupts active lower-priority speech', () async {
      final infoMsg = GuidanceMessage(
        text: 'Person ahead.',
        urgency: Urgency.info,
        timestamp: 1.0,
      );
      final urgentMsg = GuidanceMessage(
        text: 'Stop. Chair directly ahead.',
        urgency: Urgency.urgent,
        timestamp: 1.5,
      );

      await tts.speakGuidance(infoMsg);
      expect(tts.isSpeaking, isTrue);

      // Urgent guidance arrives: preempts info speech
      final spokeUrgent = await tts.speakGuidance(urgentMsg);
      expect(spokeUrgent, isTrue);
      expect(tts.currentUrgency, equals(Urgency.urgent));
      expect(tts.currentText, equals('Stop. Chair directly ahead.'));
      expect(fakeTts.spokenHistory.last, equals('Stop. Chair directly ahead.'));
    });

    test('Urgent protection: Routine guidance never interrupts an active urgent warning', () async {
      final urgentMsg = GuidanceMessage(
        text: 'Stop. Obstacle directly ahead.',
        urgency: Urgency.urgent,
        timestamp: 1.0,
      );
      final warnMsg = GuidanceMessage(
        text: 'Person ahead. Move cautiously.',
        urgency: Urgency.warn,
        timestamp: 1.2,
      );
      final infoMsg = GuidanceMessage(
        text: 'Chair on your left.',
        urgency: Urgency.info,
        timestamp: 1.3,
      );

      await tts.speakGuidance(urgentMsg);
      expect(tts.currentUrgency, equals(Urgency.urgent));

      // Both warn and info must be rejected while urgent hazard is playing
      final spokeWarn = await tts.speakGuidance(warnMsg);
      expect(spokeWarn, isFalse);

      final spokeInfo = await tts.speakGuidance(infoMsg);
      expect(spokeInfo, isFalse);

      expect(tts.currentUrgency, equals(Urgency.urgent));
      expect(fakeTts.spokenHistory.length, equals(1));
    });

    test('Voice command / system speech respects active urgent warnings unless forced', () async {
      final urgentMsg = GuidanceMessage(
        text: 'Stop. Obstacle directly ahead.',
        urgency: Urgency.urgent,
        timestamp: 1.0,
      );

      await tts.speakGuidance(urgentMsg);

      // Routine voice response (e.g. "I can help you navigate") rejected while urgent warning active
      final spokeRoutine = await tts.speak('I can help you navigate.');
      expect(spokeRoutine, isFalse);
      expect(fakeTts.spokenHistory.length, equals(1));

      // Explicit interrupt allows system to override
      final spokeInterrupt = await tts.speak('Navigation stopped.', interrupt: true);
      expect(spokeInterrupt, isTrue);
      expect(fakeTts.spokenHistory.last, equals('Navigation stopped.'));
    });

    test('Stop immediately halts speech and resets urgency', () async {
      final urgentMsg = GuidanceMessage(
        text: 'Stop. Obstacle directly ahead.',
        urgency: Urgency.urgent,
        timestamp: 1.0,
      );

      await tts.speakGuidance(urgentMsg);
      expect(tts.isSpeaking, isTrue);

      await tts.stop();
      expect(tts.isSpeaking, isFalse);
      expect(tts.currentUrgency, isNull);
      expect(tts.currentText, isNull);
    });

    test('Speech completion and error reset TTS speaking state', () async {
      final infoMsg = GuidanceMessage(
        text: 'Person ahead.',
        urgency: Urgency.info,
        timestamp: 1.0,
      );

      await tts.speakGuidance(infoMsg);
      expect(tts.isSpeaking, isTrue);

      fakeTts.simulateCompletion();
      expect(tts.isSpeaking, isFalse);
      expect(tts.currentUrgency, isNull);

      await tts.speakGuidance(infoMsg);
      expect(tts.isSpeaking, isTrue);

      fakeTts.simulateError('Simulated TTS device error');
      expect(tts.isSpeaking, isFalse);
      expect(tts.currentUrgency, isNull);
    });
  });

  group('NavigationController Lifecycle & Offline Guidance', () {
    testWidgets('Navigation stop halts speech with interrupt and resets guidance engine', (tester) async {
      final mockTts = MockTtsService();
      final mockDetector = MockLocalDetector(initialized: true);

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => SettingsNotifier(const AppSettings(), false)),
          ttsServiceProvider.overrideWithValue(mockTts),
          localDetectorProvider.overrideWithValue(mockDetector),
        ],
      );

      final controller = container.read(navigationControllerProvider.notifier);
      container.read(navigationControllerProvider);
      await tester.pump();

      // Controller stop
      await controller.stop();
      await tester.pump();

      // Verify TTS announced navigation stopped with interrupt
      expect(mockTts.spokenMessages, contains('Navigation stopped.'));
      expect(container.read(navigationControllerProvider).isRunning, isFalse);

      container.dispose();
    });
  });

  group('NavigationScreen Offline State & Banner Testing', () {
    testWidgets('Offline ready state shows On-Device AI ready banner, not backend error',
        (WidgetTester tester) async {
      final mockConnection = BackendConnectionManager(
        const AppSettings(),
        customDiscovery: (_) async => null,
      );

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => SettingsNotifier(const AppSettings(), false)),
          localDetectorProvider.overrideWithValue(MockLocalDetector(initialized: true)),
          connectionManagerProvider.overrideWith((ref) => mockConnection),
          ttsServiceProvider.overrideWithValue(MockTtsService()),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: NavigationScreen(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('On-Device AI ready (Offline mode)'), findsOneWidget);
      expect(find.text('Backend unavailable'), findsNothing);

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(
        find.bySemanticsLabel('Start navigation'),
        findsOneWidget,
      );

      container.dispose();
    });

    testWidgets('Model loading failure accurately displays error banner',
        (WidgetTester tester) async {
      final mockConnection = BackendConnectionManager(
        const AppSettings(),
        customDiscovery: (_) async => null,
      );

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => SettingsNotifier(const AppSettings(), false)),
          localDetectorProvider.overrideWithValue(
            MockLocalDetector(initialized: false, error: 'TFLite binary not found'),
          ),
          connectionManagerProvider.overrideWith((ref) => mockConnection),
          ttsServiceProvider.overrideWithValue(MockTtsService()),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: NavigationScreen(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('Local AI model error'), findsOneWidget);
      expect(find.textContaining('TFLite binary not found'), findsOneWidget);
      expect(find.text('On-Device AI ready (Offline mode)'), findsNothing);

      container.dispose();
    });

    testWidgets('Running navigation switches banner to active and button to stop',
        (WidgetTester tester) async {
      final mockConnection = BackendConnectionManager(
        const AppSettings(),
        customDiscovery: (_) async => null,
      );

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => SettingsNotifier(const AppSettings(), false)),
          localDetectorProvider.overrideWithValue(MockLocalDetector(initialized: true)),
          connectionManagerProvider.overrideWith((ref) => mockConnection),
          ttsServiceProvider.overrideWithValue(MockTtsService()),
        ],
      );

      container.read(navigationControllerProvider.notifier).state =
          const NavigationState(
        isRunning: true,
        isLocalDetectorReady: true,
        detections: [],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: NavigationScreen(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('On-Device Navigation (Offline)'), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.bySemanticsLabel('Stop navigation'), findsOneWidget);

      container.dispose();
    });
  });
}
