import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:blind_assistant/core/app_settings.dart';
import 'package:blind_assistant/services/api_service.dart';
import 'package:blind_assistant/services/backend_connection_manager.dart';
import 'package:blind_assistant/services/local_detector.dart';
import 'package:blind_assistant/services/local_guidance_engine.dart';
import 'package:blind_assistant/services/permission_service.dart';
import 'package:blind_assistant/services/tts_service.dart';

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>(
  (ref) => SettingsNotifier(),
);

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier([super.initial = const AppSettings(), bool loadFromDisk = true]) {
    if (loadFromDisk) {
      _loadFromDisk();
    }
  }

  Future<void> _loadFromDisk() async {
    state = await AppSettings.load();
  }

  Future<void> update({
    String? host,
    int? port,
    double? speechCooldownSeconds,
    double? confidenceThreshold,
    int? consecutiveFramesRequired,
  }) async {
    state = state.copyWith(
      host: host,
      port: port,
      speechCooldownSeconds: speechCooldownSeconds,
      confidenceThreshold: confidenceThreshold,
      consecutiveFramesRequired: consecutiveFramesRequired,
    );
    await state.save();
  }
}

// ---------------------------------------------------------------------------
// Backend Connection Manager
// ---------------------------------------------------------------------------

/// Provides the connection manager as a ChangeNotifierProvider so widgets can
/// watch status changes without manually subscribing to the ChangeNotifier.
final connectionManagerProvider =
    ChangeNotifierProvider<BackendConnectionManager>((ref) {
  final settings = ref.read(settingsProvider);
  final manager = BackendConnectionManager(settings, maxRetryAttempts: 3);
  // Begin discovery / connection when the provider is first created.
  // Use addPostFrameCallback so this runs after the first build.
  Future.microtask(() => manager.connect());
  return manager;
});

// ---------------------------------------------------------------------------
// API service
// ---------------------------------------------------------------------------

/// ApiService always reads the CURRENT settings from the connection manager
/// so it transparently uses the auto-discovered address.
final apiServiceProvider = Provider<ApiService>((ref) {
  final manager = ref.watch(connectionManagerProvider);
  return ApiService(manager.currentSettings);
});

// ---------------------------------------------------------------------------
// TTS
// ---------------------------------------------------------------------------

final ttsServiceProvider = Provider<TtsService>((ref) {
  final tts = TtsService();
  ref.onDispose(() {
    tts.dispose();
  });
  return tts;
});

// ---------------------------------------------------------------------------
// Local On-Device Perception
// ---------------------------------------------------------------------------

final localDetectorProvider = Provider<LocalDetector>((ref) {
  final settings = ref.watch(settingsProvider);
  final detector = LocalDetector(
    confidenceThreshold: settings.confidenceThreshold,
  );
  ref.onDispose(() {
    detector.dispose();
  });
  return detector;
});

final localGuidanceEngineProvider = Provider<LocalGuidanceEngine>((ref) {
  final settings = ref.watch(settingsProvider);
  return LocalGuidanceEngine(
    reannounceCooldownMs: (settings.speechCooldownSeconds * 1000).toInt(),
    consecutiveFramesRequired: settings.consecutiveFramesRequired,
  );
});

// ---------------------------------------------------------------------------
// Permissions
// ---------------------------------------------------------------------------

final permissionServiceProvider = Provider<PermissionService>((ref) {
  return const PermissionService();
});



