import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:blind_assistant/core/app_settings.dart';
import 'package:blind_assistant/core/providers.dart';
import 'package:blind_assistant/features/navigation/navigation_controller.dart';
import 'package:blind_assistant/features/navigation/navigation_screen.dart';
import 'package:blind_assistant/features/voice/voice_command_button.dart';
import 'package:blind_assistant/models/detection.dart';
import 'package:blind_assistant/services/backend_connection_manager.dart';
import 'package:blind_assistant/services/local_detector.dart';
import 'package:blind_assistant/services/permission_service.dart';
import 'package:blind_assistant/services/tts_service.dart';

class FakePermissionService extends PermissionService {
  PermissionStatus cameraCheckStatus;
  PermissionStatus cameraRequestStatus;
  PermissionStatus micCheckStatus;
  PermissionStatus micRequestStatus;
  bool openSettingsCalled = false;
  int cameraRequestCount = 0;
  int micRequestCount = 0;

  FakePermissionService({
    this.cameraCheckStatus = PermissionStatus.denied,
    this.cameraRequestStatus = PermissionStatus.denied,
    this.micCheckStatus = PermissionStatus.denied,
    this.micRequestStatus = PermissionStatus.denied,
  });

  @override
  Future<PermissionStatus> checkCameraPermission() async => cameraCheckStatus;

  @override
  Future<PermissionStatus> requestCameraPermission() async {
    cameraRequestCount++;
    return cameraRequestStatus;
  }

  @override
  Future<PermissionStatus> checkMicrophonePermission() async => micCheckStatus;

  @override
  Future<PermissionStatus> requestMicrophonePermission() async {
    micRequestCount++;
    return micRequestStatus;
  }

  @override
  Future<bool> openSettings() async {
    openSettingsCalled = true;
    return true;
  }
}

class FakeTtsService extends TtsService {
  final List<String> spokenMessages = [];

  @override
  Future<void> init() async {}

  @override
  Future<bool> speak(
    String text, {
    bool interrupt = false,
    Urgency urgency = Urgency.info,
  }) async {
    spokenMessages.add(text);
    return true;
  }
}

class FakeLocalDetector extends LocalDetector {
  final bool initialized;
  final String? error;

  FakeLocalDetector({this.initialized = true, this.error});

  @override
  bool get isInitialized => initialized;

  @override
  String? get lastError => error;

  @override
  Future<void> initialize({
    String modelAsset = 'assets/models/yolo11n_float16.tflite',
    String labelsAsset = 'assets/models/labels.txt',
    int numThreads = 4,
    bool useIsolate = true,
  }) async {
    if (error != null) {
      throw StateError(error!);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Camera Permission Handling & Feedback', () {
    testWidgets('Denied camera permission halts startup, speaks alert, and sets state', (tester) async {
      final fakePerm = FakePermissionService(
        cameraCheckStatus: PermissionStatus.denied,
        cameraRequestStatus: PermissionStatus.denied,
      );
      final fakeTts = FakeTtsService();
      final fakeDetector = FakeLocalDetector(initialized: true);

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => SettingsNotifier(const AppSettings(), false)),
          permissionServiceProvider.overrideWithValue(fakePerm),
          ttsServiceProvider.overrideWithValue(fakeTts),
          localDetectorProvider.overrideWithValue(fakeDetector),
        ],
      );

      final controller = container.read(navigationControllerProvider.notifier);
      await controller.start();

      expect(fakePerm.cameraRequestCount, equals(1));
      final state = container.read(navigationControllerProvider);
      expect(state.isRunning, isFalse);
      expect(state.isConnecting, isFalse);
      expect(state.isCameraPermissionDenied, isTrue);
      expect(state.isCameraPermissionPermanentlyDenied, isFalse);
      expect(state.error, contains('Camera permission denied'));
      expect(
        fakeTts.spokenMessages,
        contains('Camera permission is required to detect obstacles. Please grant camera permission.'),
      );

      container.dispose();
    });

    testWidgets('Permanently denied camera permission speaks settings guidance and sets flags', (tester) async {
      final fakePerm = FakePermissionService(
        cameraCheckStatus: PermissionStatus.permanentlyDenied,
      );
      final fakeTts = FakeTtsService();
      final fakeDetector = FakeLocalDetector(initialized: true);

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => SettingsNotifier(const AppSettings(), false)),
          permissionServiceProvider.overrideWithValue(fakePerm),
          ttsServiceProvider.overrideWithValue(fakeTts),
          localDetectorProvider.overrideWithValue(fakeDetector),
        ],
      );

      final controller = container.read(navigationControllerProvider.notifier);
      await controller.start();

      final state = container.read(navigationControllerProvider);
      expect(state.isRunning, isFalse);
      expect(state.isCameraPermissionDenied, isTrue);
      expect(state.isCameraPermissionPermanentlyDenied, isTrue);
      expect(
        fakeTts.spokenMessages,
        contains(
          'Camera permission is permanently denied. Please enable camera permission in device settings to use navigation.',
        ),
      );

      // Verify openSettings method delegates to service
      await controller.openSettings();
      expect(fakePerm.openSettingsCalled, isTrue);

      container.dispose();
    });
  });

  group('On-Demand Microphone Permission in VoiceCommandButton', () {
    testWidgets('Navigation start does NOT request microphone permission', (tester) async {
      final fakePerm = FakePermissionService(
        cameraCheckStatus: PermissionStatus.denied,
        cameraRequestStatus: PermissionStatus.denied,
      );
      final fakeTts = FakeTtsService();

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => SettingsNotifier(const AppSettings(), false)),
          permissionServiceProvider.overrideWithValue(fakePerm),
          ttsServiceProvider.overrideWithValue(fakeTts),
          localDetectorProvider.overrideWithValue(FakeLocalDetector(initialized: true)),
        ],
      );

      final controller = container.read(navigationControllerProvider.notifier);
      await controller.start();

      expect(fakePerm.micRequestCount, equals(0));
      container.dispose();
    });

    testWidgets('VoiceCommandButton requests mic on-demand and announces denial', (tester) async {
      final fakePerm = FakePermissionService(
        micCheckStatus: PermissionStatus.denied,
        micRequestStatus: PermissionStatus.denied,
      );
      final fakeTts = FakeTtsService();

      final container = ProviderContainer(
        overrides: [
          permissionServiceProvider.overrideWithValue(fakePerm),
          ttsServiceProvider.overrideWithValue(fakeTts),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: VoiceCommandButton(),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(VoiceCommandButton));
      await tester.pumpAndSettle();

      expect(fakePerm.micRequestCount, equals(1));
      expect(
        fakeTts.spokenMessages,
        contains('Microphone permission is required for voice commands.'),
      );
      expect(
        find.text('Microphone permission is required for voice commands.'),
        findsOneWidget,
      );

      container.dispose();
    });

    testWidgets('VoiceCommandButton handles permanently denied microphone with settings action', (tester) async {
      final fakePerm = FakePermissionService(
        micCheckStatus: PermissionStatus.permanentlyDenied,
      );
      final fakeTts = FakeTtsService();

      final container = ProviderContainer(
        overrides: [
          permissionServiceProvider.overrideWithValue(fakePerm),
          ttsServiceProvider.overrideWithValue(fakeTts),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: VoiceCommandButton(),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(VoiceCommandButton));
      await tester.pumpAndSettle();

      expect(
        fakeTts.spokenMessages,
        contains(
          'Microphone permission is permanently denied. Please enable microphone permission in device settings.',
        ),
      );
      expect(find.text('Settings'), findsOneWidget);

      await tester.tap(find.text('Settings'));
      expect(fakePerm.openSettingsCalled, isTrue);

      container.dispose();
    });
  });

  group('Lifecycle Pause & Permission Revocation on Resume', () {
    testWidgets('Revoked permission while in background halts navigation on resume', (tester) async {
      final fakePerm = FakePermissionService(
        cameraCheckStatus: PermissionStatus.denied,
      );
      final fakeTts = FakeTtsService();

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => SettingsNotifier(const AppSettings(), false)),
          permissionServiceProvider.overrideWithValue(fakePerm),
          ttsServiceProvider.overrideWithValue(fakeTts),
          localDetectorProvider.overrideWithValue(FakeLocalDetector(initialized: true)),
        ],
      );

      final controller = container.read(navigationControllerProvider.notifier);
      // Simulate running navigation
      controller.state = const NavigationState(
        isRunning: true,
        isLocalDetectorReady: true,
      );

      // App paused
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);

      // App resumed while permission is revoked (denied)
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();

      final state = container.read(navigationControllerProvider);
      expect(state.isRunning, isFalse);
      expect(state.isCameraPermissionDenied, isTrue);
      expect(
        fakeTts.spokenMessages,
        contains('Camera permission was revoked. Navigation stopped.'),
      );

      container.dispose();
    });
  });

  group('NavigationScreen Permission UI Display', () {
    testWidgets('Shows Camera Permission Blocked and Open App Settings button', (tester) async {
      final fakePerm = FakePermissionService();
      final mockConnection = BackendConnectionManager(
        const AppSettings(),
        customDiscovery: (_) async => null,
      );

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => SettingsNotifier(const AppSettings(), false)),
          permissionServiceProvider.overrideWithValue(fakePerm),
          localDetectorProvider.overrideWithValue(FakeLocalDetector(initialized: true)),
          connectionManagerProvider.overrideWith((ref) => mockConnection),
          ttsServiceProvider.overrideWithValue(FakeTtsService()),
        ],
      );

      container.read(navigationControllerProvider.notifier).state =
          const NavigationState(
        isLocalDetectorReady: true,
        isCameraPermissionDenied: true,
        isCameraPermissionPermanentlyDenied: true,
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: NavigationScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Camera Permission Blocked'), findsOneWidget);
      expect(find.text('Camera permission permanently denied.'), findsOneWidget);
      expect(find.text('Open App Settings'), findsOneWidget);
      expect(find.text('Open Settings'), findsOneWidget);

      await tester.tap(find.text('Open App Settings'));
      await tester.pumpAndSettle();
      expect(fakePerm.openSettingsCalled, isTrue);

      container.dispose();
    });

    testWidgets('Shows Camera Permission Denied and Grant Camera Permission button', (tester) async {
      final fakePerm = FakePermissionService(
        cameraCheckStatus: PermissionStatus.denied,
        cameraRequestStatus: PermissionStatus.denied,
      );
      final mockConnection = BackendConnectionManager(
        const AppSettings(),
        customDiscovery: (_) async => null,
      );

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith((ref) => SettingsNotifier(const AppSettings(), false)),
          permissionServiceProvider.overrideWithValue(fakePerm),
          localDetectorProvider.overrideWithValue(FakeLocalDetector(initialized: true)),
          connectionManagerProvider.overrideWith((ref) => mockConnection),
          ttsServiceProvider.overrideWithValue(FakeTtsService()),
        ],
      );

      container.read(navigationControllerProvider.notifier).state =
          const NavigationState(
        isLocalDetectorReady: true,
        isCameraPermissionDenied: true,
        isCameraPermissionPermanentlyDenied: false,
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: NavigationScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Camera Permission Denied'), findsOneWidget);
      expect(find.text('Camera permission required for navigation.'), findsOneWidget);
      expect(find.text('Grant Camera Permission'), findsOneWidget);
      expect(find.text('Grant'), findsOneWidget);

      container.dispose();
    });
  });
}
