import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:blind_assistant/core/app_settings.dart';
import 'package:blind_assistant/services/api_service.dart';
import 'package:blind_assistant/services/backend_connection_manager.dart';
import 'package:blind_assistant/services/tts_service.dart';

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>(
  (ref) => SettingsNotifier(),
);

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(const AppSettings()) {
    _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    state = await AppSettings.load();
  }

  Future<void> update({String? host, int? port}) async {
    state = state.copyWith(host: host, port: port);
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
  final manager = BackendConnectionManager(settings);
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

final ttsServiceProvider = Provider<TtsService>((ref) => TtsService());
