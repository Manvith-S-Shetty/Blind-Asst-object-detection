import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:blind_assistant/core/providers.dart';
import 'package:blind_assistant/models/detection.dart';
import 'package:blind_assistant/services/navigation_socket.dart';

class NavigationState {
  final bool isRunning;
  final bool isConnecting;
  final String? sessionId;
  final List<Detection> detections;
  final List<GuidanceMessage> recentGuidance;
  final String? error;

  const NavigationState({
    this.isRunning = false,
    this.isConnecting = false,
    this.sessionId,
    this.detections = const [],
    this.recentGuidance = const [],
    this.error,
  });

  NavigationState copyWith({
    bool? isRunning,
    bool? isConnecting,
    String? sessionId,
    List<Detection>? detections,
    List<GuidanceMessage>? recentGuidance,
    String? error,
  }) =>
      NavigationState(
        isRunning: isRunning ?? this.isRunning,
        isConnecting: isConnecting ?? this.isConnecting,
        sessionId: sessionId ?? this.sessionId,
        detections: detections ?? this.detections,
        recentGuidance: recentGuidance ?? this.recentGuidance,
        error: error,
      );
}

class NavigationController extends StateNotifier<NavigationState> with WidgetsBindingObserver {
  bool _isDisposed = false;
  final Ref ref;
  CameraController? _cameraController;
  NavigationSocket? _socket;
  Timer? _captureTimer;
  StreamSubscription<FrameResult>? _frameSub;
  StreamSubscription<String>? _errorSub;

  bool _isSending = false;
  int _frameSequence = 0;
  int _lastProcessedTimestampMs = 0;

  // Throttle: matches backend's frame_process_interval_s default (0.3s)
  static const _captureInterval = Duration(milliseconds: 400);

  NavigationController(this.ref) : super(const NavigationState()) {
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // Pause frame capture loop to conserve mobile CPU and battery
      _captureTimer?.cancel();
      _captureTimer = null;
    } else if (state == AppLifecycleState.resumed && this.state.isRunning) {
      // Resume periodic frame capture
      _captureTimer?.cancel();
      _captureTimer = Timer.periodic(_captureInterval, (_) => _captureAndSend());
    }
  }

  Future<void> start() async {
    if (state.isRunning || state.isConnecting) return;

    // Do not start perception if the backend is not reachable.
    // Announce the problem clearly rather than silently failing during session creation.
    final connectionManager = ref.read(connectionManagerProvider);
    if (!connectionManager.isConnected) {
      final tts = ref.read(ttsServiceProvider);
      tts.speak(
        'Backend unavailable. Navigation requires the AI server. '
        'Please check your connection and try again.',
        interrupt: true,
      );
      state = state.copyWith(
        error: 'Backend unavailable — cannot start navigation. '
            'Tap the settings icon to configure the server address.',
      );
      return;
    }

    state = state.copyWith(isConnecting: true, error: null);

    try {
      // 1. Camera setup
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No camera available on this device');
      }
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.medium, // keep frames small (~640x480) for low transport latency
        enableAudio: false,
      );
      await _cameraController!.initialize();

      // 2. Backend session — use settings from the connection manager
      final api = ref.read(apiServiceProvider);
      final sessionId = await api.startSession();

      // 3. WebSocket — also use the connection manager's current settings
      final settings = connectionManager.currentSettings;
      _socket = NavigationSocket(settings: settings, sessionId: sessionId);
      _socket!.connect();

      _frameSub = _socket!.frames.listen(_onFrameResult);
      _errorSub = _socket!.errors.listen(_onSocketError);

      // 4. Start periodic frame capture
      _frameSequence = 0;
      _lastProcessedTimestampMs = 0;
      _captureTimer?.cancel();
      _captureTimer = Timer.periodic(_captureInterval, (_) => _captureAndSend());

      state = state.copyWith(isRunning: true, isConnecting: false, sessionId: sessionId);
    } catch (e) {
      state = state.copyWith(isConnecting: false, error: 'Failed to start: $e');
      await stop();
    }
  }

  Future<void> _captureAndSend() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isTakingPicture) return;

    // Prevent unbounded frame queues: if previous frame transmission is still in flight, drop
    if (_isSending) return;
    _isSending = true;

    try {
      _frameSequence++;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      _socket?.sendFrame(base64Encode(bytes), clientTimestampMs: timestamp, frameSeq: _frameSequence);
    } catch (_) {
      // Dropped frame — not worth surfacing to user; next tick retries
    } finally {
      _isSending = false;
    }
  }

  void _onFrameResult(FrameResult result) {
    // Rejection of late/out-of-order results from superseded frames
    if (result.clientTimestampMs != null) {
      if (result.clientTimestampMs! < _lastProcessedTimestampMs) {
        return; // Stale frame result discarded
      }
      _lastProcessedTimestampMs = result.clientTimestampMs!;
    }

    state = state.copyWith(
      detections: result.detections,
      recentGuidance: result.guidance,
      error: null, // Clear any previous transient network warning
    );

    final tts = ref.read(ttsServiceProvider);
    for (final g in result.guidance) {
      tts.speakGuidance(g);
    }
  }

  void _onSocketError(String err) {
    state = state.copyWith(error: err);
    // Announce degraded state if navigation is actively running
    if (state.isRunning) {
      final tts = ref.read(ttsServiceProvider);
      tts.speak('Navigation server connection interrupted. Caution.', interrupt: false);
    }
  }

  Future<String?> captureCurrentFrameBase64() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return null;
    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      return base64Encode(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> stop() async {
    _captureTimer?.cancel();
    _captureTimer = null;
    await _frameSub?.cancel();
    _frameSub = null;
    await _errorSub?.cancel();
    _errorSub = null;
    await _socket?.close();
    _socket = null;

    final sessionId = state.sessionId;
    if (sessionId != null) {
      try {
        await ref.read(apiServiceProvider).endSession(sessionId);
      } catch (_) {}
    }

    await _cameraController?.dispose();
    _cameraController = null;

    if (!_isDisposed) {
      state = const NavigationState();
    }
  }

  CameraController? get cameraController => _cameraController;

  @override
  void dispose() {
    _isDisposed = true;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _captureTimer?.cancel();
    _frameSub?.cancel();
    _errorSub?.cancel();
    _socket?.close();
    _cameraController?.dispose();
    super.dispose();
  }
}

final navigationControllerProvider =
    StateNotifierProvider<NavigationController, NavigationState>(
  (ref) => NavigationController(ref),
);
