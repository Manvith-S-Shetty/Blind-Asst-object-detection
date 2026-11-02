import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:blind_assistant/core/providers.dart';
import 'package:blind_assistant/models/detection.dart';
import 'package:blind_assistant/services/local_guidance_engine.dart';
import 'package:blind_assistant/services/navigation_socket.dart';
import 'package:blind_assistant/services/permission_service.dart';

class NavigationState {
  final bool isRunning;
  final bool isConnecting;
  final String? sessionId;
  final List<Detection> detections;
  final List<GuidanceMessage> recentGuidance;
  final String? error;
  final bool isLocalDetectorReady;
  final String? localDetectorError;
  final bool isOnlineMode;
  final bool isCameraPermissionDenied;
  final bool isCameraPermissionPermanentlyDenied;

  const NavigationState({
    this.isRunning = false,
    this.isConnecting = false,
    this.sessionId,
    this.detections = const [],
    this.recentGuidance = const [],
    this.error,
    this.isLocalDetectorReady = false,
    this.localDetectorError,
    this.isOnlineMode = false,
    this.isCameraPermissionDenied = false,
    this.isCameraPermissionPermanentlyDenied = false,
  });

  NavigationState copyWith({
    bool? isRunning,
    bool? isConnecting,
    String? sessionId,
    List<Detection>? detections,
    List<GuidanceMessage>? recentGuidance,
    String? error,
    bool? isLocalDetectorReady,
    String? localDetectorError,
    bool? isOnlineMode,
    bool? isCameraPermissionDenied,
    bool? isCameraPermissionPermanentlyDenied,
  }) =>
      NavigationState(
        isRunning: isRunning ?? this.isRunning,
        isConnecting: isConnecting ?? this.isConnecting,
        sessionId: sessionId ?? this.sessionId,
        detections: detections ?? this.detections,
        recentGuidance: recentGuidance ?? this.recentGuidance,
        error: error,
        isLocalDetectorReady: isLocalDetectorReady ?? this.isLocalDetectorReady,
        localDetectorError: localDetectorError ?? this.localDetectorError,
        isOnlineMode: isOnlineMode ?? this.isOnlineMode,
        isCameraPermissionDenied:
            isCameraPermissionDenied ?? this.isCameraPermissionDenied,
        isCameraPermissionPermanentlyDenied:
            isCameraPermissionPermanentlyDenied ??
                this.isCameraPermissionPermanentlyDenied,
      );
}

class NavigationController extends StateNotifier<NavigationState>
    with WidgetsBindingObserver {
  bool _isDisposed = false;
  final Ref ref;
  CameraController? _cameraController;
  NavigationSocket? _socket;
  Timer? _captureTimer;
  StreamSubscription<FrameResult>? _frameSub;
  StreamSubscription<String>? _errorSub;

  final LocalGuidanceEngine _guidanceEngine;
  final PermissionService _permissionService;

  bool _isProcessingFrame = false;
  bool _usingImageStream = false;
  bool _isResumingCamera = false;
  int _frameSequence = 0;
  int _lastProcessedTimestampMs = 0;
  Uint8List? _lastFrameBytes;

  // Capture interval used when falling back to periodic picture capture (~3 FPS)
  static const _captureInterval = Duration(milliseconds: 350);

  NavigationController(this.ref)
      : _guidanceEngine = ref.read(localGuidanceEngineProvider),
        _permissionService = ref.read(permissionServiceProvider),
        super(const NavigationState()) {
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}

    // Initialize or check local detector availability on startup
    Future.microtask(() => checkOrWarmupLocalDetector());
  }

  /// Verifies model and label loading on-device without blocking UI creation.
  Future<void> checkOrWarmupLocalDetector() async {
    if (_isDisposed) return;
    try {
      final detector = ref.read(localDetectorProvider);
      if (!detector.isInitialized) {
        await detector.initialize();
      }
      if (!_isDisposed) {
        state = state.copyWith(
          isLocalDetectorReady: true,
          localDetectorError: null,
        );
      }
    } catch (e) {
      if (!_isDisposed) {
        state = state.copyWith(
          isLocalDetectorReady: false,
          localDetectorError: e.toString(),
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseCamera();
    } else if (state == AppLifecycleState.resumed && this.state.isRunning) {
      _resumeCamera();
    }
  }

  void _pauseCamera() {
    _captureTimer?.cancel();
    _captureTimer = null;

    if (_usingImageStream &&
        _cameraController != null &&
        _cameraController!.value.isStreamingImages) {
      try {
        _cameraController!.stopImageStream();
      } catch (_) {}
    }
    _usingImageStream = false;
    _isProcessingFrame = false;

    try {
      _cameraController?.dispose();
    } catch (_) {}
    _cameraController = null;
  }

  Future<void> _resumeCamera() async {
    if (!state.isRunning || _isDisposed || _isResumingCamera) return;
    _isResumingCamera = true;

    try {
      final permStatus = await _permissionService.checkCameraPermission();
      if (!permStatus.isGranted) {
        state = state.copyWith(
          isRunning: false,
          isCameraPermissionDenied: true,
          error: 'Camera permission was revoked while app was in background.',
        );
        ref.read(ttsServiceProvider).speak(
          'Camera permission was revoked. Navigation stopped.',
          interrupt: true,
        );
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        state = state.copyWith(error: 'No camera available on resume.');
        return;
      }

      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final newController = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await newController.initialize();
      if (!state.isRunning || _isDisposed) {
        await newController.dispose();
        return;
      }

      _cameraController = newController;
      await _startCapturePipeline();
    } catch (e) {
      debugPrint('Error recovering camera on resume: $e');
      state = state.copyWith(error: 'Camera recovery failed: $e');
    } finally {
      _isResumingCamera = false;
    }
  }

  /// Opens the device settings screen for the app (e.g. if permissions were permanently denied).
  Future<bool> openSettings() async {
    return _permissionService.openSettings();
  }

  /// Starts navigation perception.
  /// On-device inference is the primary navigation path and does NOT require
  /// a FastAPI backend connection.
  Future<void> start() async {
    if (state.isRunning || state.isConnecting) return;

    state = state.copyWith(
      isConnecting: true,
      error: null,
      isCameraPermissionDenied: false,
      isCameraPermissionPermanentlyDenied: false,
    );

    final tts = ref.read(ttsServiceProvider);

    try {
      // 1. Check & Request Camera Permission
      final permStatus = await _permissionService.checkCameraPermission();
      PermissionStatus finalStatus = permStatus;
      if (permStatus.isPermanentlyDenied) {
        finalStatus = permStatus;
      } else if (!permStatus.isGranted) {
        finalStatus = await _permissionService.requestCameraPermission();
      }

      if (finalStatus.isPermanentlyDenied) {
        await tts.speak(
          'Camera permission is permanently denied. Please enable camera permission in device settings to use navigation.',
          interrupt: true,
        );
        state = state.copyWith(
          isConnecting: false,
          isCameraPermissionDenied: true,
          isCameraPermissionPermanentlyDenied: true,
          error: 'Camera permission permanently denied. Tap to open app settings.',
        );
        return;
      } else if (!finalStatus.isGranted) {
        await tts.speak(
          'Camera permission is required to detect obstacles. Please grant camera permission.',
          interrupt: true,
        );
        state = state.copyWith(
          isConnecting: false,
          isCameraPermissionDenied: true,
          isCameraPermissionPermanentlyDenied: false,
          error: 'Camera permission denied. Camera is required for navigation.',
        );
        return;
      }

      // 2. Ensure LocalDetector model is initialized
      final detector = ref.read(localDetectorProvider);
      if (!detector.isInitialized) {
        try {
          await detector.initialize();
          state = state.copyWith(
            isLocalDetectorReady: true,
            localDetectorError: null,
          );
        } catch (e) {
          await tts.speak(
            'Failed to initialize on-device detection model.',
            interrupt: true,
          );
          state = state.copyWith(
            isConnecting: false,
            isLocalDetectorReady: false,
            localDetectorError: e.toString(),
            error: 'Model initialization failed: $e',
          );
          return;
        }
      }

      // 3. Camera setup
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        await tts.speak('No camera was found on this device.', interrupt: true);
        state = state.copyWith(
          isConnecting: false,
          error: 'No camera available on this device.',
        );
        return;
      }
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _cameraController!.initialize();

      // 4. Optional FastAPI backend session (for dev inspection & telemetry)
      final connectionManager = ref.read(connectionManagerProvider);
      String? sessionId;
      bool isOnline = false;

      if (connectionManager.isConnected) {
        try {
          final api = ref.read(apiServiceProvider);
          sessionId = await api.startSession();
          final settings = connectionManager.currentSettings;
          _socket = NavigationSocket(settings: settings, sessionId: sessionId);
          _socket!.connect();

          _frameSub = _socket!.frames.listen(_onServerFrameResult);
          _errorSub = _socket!.errors.listen(_onSocketError);
          isOnline = true;
        } catch (e) {
          debugPrint('Optional backend session startup skipped: $e');
        }
      }

      // 5. Start local frame perception pipeline
      _frameSequence = 0;
      _lastProcessedTimestampMs = 0;
      _isProcessingFrame = false;
      _guidanceEngine.reset();

      state = state.copyWith(
        isRunning: true,
        isConnecting: false,
        sessionId: sessionId,
        isOnlineMode: isOnline,
        error: null,
        isCameraPermissionDenied: false,
        isCameraPermissionPermanentlyDenied: false,
      );

      await _startCapturePipeline();

      // Audio confirmation of navigation start
      await tts.speak(
        isOnline
            ? 'Navigation started. Connected to server and on-device detection active.'
            : 'Navigation started. On-device detection active.',
        interrupt: true,
      );
    } on CameraException catch (e) {
      debugPrint('CameraException during start: ${e.code} - ${e.description}');
      final isPermIssue = e.code == 'cameraPermissionDenied' ||
          e.code == 'CameraAccessDenied' ||
          e.code == 'CameraAccessRestricted';
      if (isPermIssue) {
        await tts.speak(
          'Camera access was denied. Please grant camera permission.',
          interrupt: true,
        );
        state = state.copyWith(
          isConnecting: false,
          isCameraPermissionDenied: true,
          error: 'Camera access denied: ${e.description ?? e.code}',
        );
      } else {
        await tts.speak('Camera initialization failed.', interrupt: true);
        state = state.copyWith(
          isConnecting: false,
          error: 'Camera error (${e.code}): ${e.description ?? e.toString()}',
        );
      }
      await stop(speakConfirmation: false);
    } catch (e) {
      debugPrint('Error starting navigation: $e');
      state = state.copyWith(
        isConnecting: false,
        error: 'Failed to start navigation: $e',
      );
      await stop(speakConfirmation: false);
    }
  }

  /// Connects camera frames to LocalDetector.
  /// Tries live [CameraImage] stream first; falls back to periodic frame capture if unsupported.
  Future<void> _startCapturePipeline() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (_usingImageStream && controller.value.isStreamingImages) {
      return;
    }

    try {
      await controller.startImageStream((CameraImage image) {
        _onStreamCameraImage(image);
      });
      _usingImageStream = true;
    } catch (e) {
      debugPrint(
        'startImageStream unsupported on this platform or failed ($e). '
        'Using periodic frame capture fallback.',
      );
      _usingImageStream = false;
      _captureTimer?.cancel();
      _captureTimer =
          Timer.periodic(_captureInterval, (_) => _captureAndProcessFrame());
    }
  }

  /// Processes live camera image frames from startImageStream.
  /// Drops overlapping frames and discards stale frames.
  void _onStreamCameraImage(CameraImage image) async {
    if (!state.isRunning || _isDisposed) return;

    // Requirement 5: Prevent overlapping inference calls
    if (_isProcessingFrame) {
      return; // Discard stale frame immediately while inference is in flight
    }
    _isProcessingFrame = true;

    final frameTimestamp = DateTime.now().millisecondsSinceEpoch;
    _frameSequence++;

    try {
      final detector = ref.read(localDetectorProvider);
      final sensorOrientation =
          _cameraController?.description.sensorOrientation ?? 0;

      final detections = await detector.detectFromCameraImage(
        image,
        sensorOrientation: sensorOrientation,
      );

      // Verify still running when inference completes
      if (!state.isRunning || _isDisposed) return;

      // Requirement 5: Discard late/out-of-order results
      if (frameTimestamp < _lastProcessedTimestampMs) {
        return;
      }
      _lastProcessedTimestampMs = frameTimestamp;

      _handleDetections(detections, frameTimestamp);
    } catch (e) {
      debugPrint('Stream detection error: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  /// Periodic frame capture fallback (via takePicture) when image stream is unavailable.
  Future<void> _captureAndProcessFrame() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (!state.isRunning || _isDisposed) return;
    if (controller.value.isTakingPicture) return;

    // Requirement 5: Prevent overlapping inference calls
    if (_isProcessingFrame) return;
    _isProcessingFrame = true;

    final frameTimestamp = DateTime.now().millisecondsSinceEpoch;
    _frameSequence++;

    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      _lastFrameBytes = bytes;

      if (!state.isRunning || _isDisposed) return;

      final detector = ref.read(localDetectorProvider);
      final detections = await detector.detectFromJpeg(bytes);

      if (!state.isRunning || _isDisposed) return;

      if (frameTimestamp < _lastProcessedTimestampMs) {
        return;
      }
      _lastProcessedTimestampMs = frameTimestamp;

      _handleDetections(detections, frameTimestamp);

      // Optional backend forwarding for development telemetry
      if (_socket != null && _socket!.isConnected) {
        _socket!.sendFrame(
          base64Encode(bytes),
          clientTimestampMs: frameTimestamp,
          frameSeq: _frameSequence,
        );
      }
    } catch (e) {
      debugPrint('Periodic frame capture error: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  /// Updates state and announces useful detections aloud using TTS.
  void _handleDetections(List<Detection> detections, int timestampMs) {
    final guidance = _guidanceEngine.generateGuidance(
      detections,
      currentTimestampMs: timestampMs,
    );

    state = state.copyWith(
      detections: detections,
      recentGuidance: guidance,
      error: null,
    );

    // Requirement 4: Announce useful detections aloud via TTS
    final tts = ref.read(ttsServiceProvider);
    for (final g in guidance) {
      tts.speakGuidance(g);
    }
  }

  void _onServerFrameResult(FrameResult result) {
    // Only overlay server guidance if running in online dev mode
    if (!state.isOnlineMode) return;
    if (result.guidance.isNotEmpty) {
      state = state.copyWith(recentGuidance: result.guidance);
      final tts = ref.read(ttsServiceProvider);
      for (final g in result.guidance) {
        tts.speakGuidance(g);
      }
    }
  }

  void _onSocketError(String err) {
    debugPrint('[NavigationController] Backend disconnected/error ($err); continuing in offline mode.');
    if (state.isRunning && state.isOnlineMode) {
      // Degrade gracefully to purely local mode without disrupting ongoing navigation
      state = state.copyWith(
        isOnlineMode: false,
      );
    }
  }

  /// Returns base64 encoded bytes of the current or latest camera frame.
  Future<String?> captureCurrentFrameBase64() async {
    if (_lastFrameBytes != null) {
      return base64Encode(_lastFrameBytes!);
    }
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return null;
    if (controller.value.isTakingPicture) return null;
    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      _lastFrameBytes = bytes;
      return base64Encode(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Stops navigation cleanly.
  Future<void> stop({bool speakConfirmation = true}) async {
    _captureTimer?.cancel();
    _captureTimer = null;

    if (_usingImageStream &&
        _cameraController != null &&
        _cameraController!.value.isStreamingImages) {
      try {
        await _cameraController!.stopImageStream();
      } catch (_) {}
    }
    _usingImageStream = false;
    _isProcessingFrame = false;

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

    try {
      await _cameraController?.dispose();
    } catch (_) {}
    _cameraController = null;
    _lastFrameBytes = null;
    _guidanceEngine.reset();

    if (speakConfirmation) {
      final tts = ref.read(ttsServiceProvider);
      await tts.speak('Navigation stopped.', interrupt: true);
    }

    if (!_isDisposed) {
      state = state.copyWith(
        isRunning: false,
        isConnecting: false,
        sessionId: null,
        isOnlineMode: false,
        detections: const [],
        recentGuidance: const [],
        error: null,
      );
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
    if (_usingImageStream &&
        _cameraController != null &&
        _cameraController!.value.isStreamingImages) {
      try {
        _cameraController!.stopImageStream();
      } catch (_) {}
    }
    _cameraController?.dispose();
    _guidanceEngine.reset();
    try {
      ref.read(ttsServiceProvider).stop();
    } catch (_) {}
    super.dispose();
  }
}

final navigationControllerProvider =
    StateNotifierProvider<NavigationController, NavigationState>(
  (ref) => NavigationController(ref),
);
