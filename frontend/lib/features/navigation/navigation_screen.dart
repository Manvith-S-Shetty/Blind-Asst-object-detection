import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:blind_assistant/core/providers.dart';
import 'package:blind_assistant/core/theme.dart';
import 'package:blind_assistant/features/navigation/navigation_controller.dart';
import 'package:blind_assistant/features/voice/voice_command_button.dart';
import 'package:blind_assistant/models/detection.dart';
import 'package:blind_assistant/services/backend_connection_manager.dart';
import 'package:blind_assistant/widgets/guidance_banner.dart';

class NavigationScreen extends ConsumerWidget {
  const NavigationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(navigationControllerProvider);
    final controller = ref.read(navigationControllerProvider.notifier);
    final connectionManager = ref.watch(connectionManagerProvider);

    final isDetectionReady =
        state.isLocalDetectorReady || connectionManager.isConnected;

    final urgentGuidance =
        state.recentGuidance.where((g) => g.urgency == Urgency.urgent).toList();
    final String? stopWarningText = urgentGuidance.isNotEmpty
        ? urgentGuidance.first.text
        : state.detections.any((d) =>
                d.riskLevel == 'imminent' &&
                (d.inPath == true || d.direction == 'center'))
            ? 'Forward obstacle detected close ahead. Stop.'
            : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Blind Assistant'),
        actions: [
          IconButton(
            icon: const Icon(Icons.place, size: 28),
            tooltip: 'Nearby Places',
            onPressed: () => context.push('/places'),
          ),
          IconButton(
            icon: const Icon(Icons.settings, size: 28),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Status banner — accurate on-device or server status without false alerts
            _ConnectionStatusBanner(
              connectionManager: connectionManager,
              isLocalReady: state.isLocalDetectorReady,
              localError: state.localDetectorError,
              isRunning: state.isRunning,
              isCameraPermissionDenied: state.isCameraPermissionDenied,
              isCameraPermissionPermanentlyDenied:
                  state.isCameraPermissionPermanentlyDenied,
              onRetry: () {
                controller.checkOrWarmupLocalDetector();
                connectionManager.retry();
              },
              onSettings: () => context.push('/settings'),
              onOpenAppSettings: controller.openSettings,
              onGrantCamera: controller.start,
            ),
            if (state.isRunning && stopWarningText != null)
              _StopHazardWarningBanner(text: stopWarningText),
            Expanded(
              flex: 3,
              child: _CameraPreviewArea(
                isRunning: state.isRunning,
                cameraController: controller.cameraController,
                detections: state.detections,
                isCameraPermissionDenied: state.isCameraPermissionDenied,
                isCameraPermissionPermanentlyDenied:
                    state.isCameraPermissionPermanentlyDenied,
                onGrantCamera: controller.start,
                onOpenAppSettings: controller.openSettings,
              ),
            ),
            Expanded(
              flex: 2,
              child: SingleChildScrollView(
                child: GuidanceBanner(messages: state.recentGuidance),
              ),
            ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  state.error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 16),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _StartStopButton(
                    isRunning: state.isRunning,
                    isConnecting: state.isConnecting,
                    isReady: isDetectionReady,
                    isCameraPermissionPermanentlyDenied:
                        state.isCameraPermissionPermanentlyDenied,
                    onStart: controller.start,
                    onStop: controller.stop,
                    onOpenAppSettings: controller.openSettings,
                  ),
                  const VoiceCommandButton(),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 6, left: 16, right: 16),
              child: Text(
                'Perception assistance aid only. Does not guarantee collision avoidance.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Displays an accurate on-device (offline) or online status banner.
/// When local detection is ready, it shows an offline status strip instead of
/// blocking the user with "Backend unreachable".
/// If model loading or inference fails, it truthfully reports the error.
class _ConnectionStatusBanner extends StatelessWidget {
  final BackendConnectionManager connectionManager;
  final bool isLocalReady;
  final String? localError;
  final bool isRunning;
  final bool isCameraPermissionDenied;
  final bool isCameraPermissionPermanentlyDenied;
  final VoidCallback onRetry;
  final VoidCallback onSettings;
  final VoidCallback onOpenAppSettings;
  final VoidCallback onGrantCamera;

  const _ConnectionStatusBanner({
    required this.connectionManager,
    required this.isLocalReady,
    required this.localError,
    required this.isRunning,
    this.isCameraPermissionDenied = false,
    this.isCameraPermissionPermanentlyDenied = false,
    required this.onRetry,
    required this.onSettings,
    required this.onOpenAppSettings,
    required this.onGrantCamera,
  });

  @override
  Widget build(BuildContext context) {
    // 1. Report permanent permission denial prominently
    if (isCameraPermissionPermanentlyDenied) {
      return Semantics(
        liveRegion: true,
        label:
            'Camera permission permanently denied. Open settings to grant camera access.',
        child: Container(
          color: Colors.amber.shade900,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.videocam_off, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Camera permission permanently denied.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: onOpenAppSettings,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.black26,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Open Settings',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      );
    }

    // 2. Report standard permission denial
    if (isCameraPermissionDenied) {
      return Semantics(
        liveRegion: true,
        label: 'Camera permission denied. Tap Grant to allow camera access.',
        child: Container(
          color: Colors.orange.shade900,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.no_photography, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Camera permission required for navigation.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: onGrantCamera,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.black26,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Grant',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      );
    }

    // 3. Report failure truthfully if local detector failed to load
    // Requirement 6: "Do not falsely report success if model loading or inference fails."
    if (localError != null && !isLocalReady) {
      return Semantics(
        liveRegion: true,
        label: 'Local detection error: $localError',
        child: Container(
          color: AppTheme.urgentColor.withValues(alpha: 0.92),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Local AI model error: $localError',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Retry', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      );
    }

    final backendStatus = connectionManager.status;

    // 4. If connected to backend, online mode is active (minimal banner)
    if (backendStatus == ConnectionStatus.connected) {
      return const SizedBox.shrink();
    }

    // 5. Local on-device inference is ready (Offline mode)
    // Requirement 6: "Replace the backend-unreachable banner with an accurate local/offline status"
    if (isLocalReady) {
      final label = isRunning
          ? 'On-Device Navigation (Offline)'
          : 'On-Device AI ready (Offline mode)';

      return Semantics(
        liveRegion: true,
        label: label,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          color: Colors.teal.shade800.withValues(alpha: 0.88),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.sensors, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: onSettings,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child:
                    const Text('Server Settings', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }

    // 6. Initializing state
    return Semantics(
      liveRegion: true,
      label: 'Initializing on-device AI…',
      child: Container(
        color: Colors.grey.shade800.withValues(alpha: 0.85),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: const Row(
          children: [
            Icon(Icons.hourglass_top, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Initializing on-device AI…',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraPreviewArea extends StatelessWidget {
  final bool isRunning;
  final CameraController? cameraController;
  final List<Detection> detections;
  final bool isCameraPermissionDenied;
  final bool isCameraPermissionPermanentlyDenied;
  final VoidCallback onGrantCamera;
  final VoidCallback onOpenAppSettings;

  const _CameraPreviewArea({
    required this.isRunning,
    required this.cameraController,
    required this.detections,
    this.isCameraPermissionDenied = false,
    this.isCameraPermissionPermanentlyDenied = false,
    required this.onGrantCamera,
    required this.onOpenAppSettings,
  });

  @override
  Widget build(BuildContext context) {
    if (isCameraPermissionPermanentlyDenied) {
      return Container(
        color: Colors.grey.shade900,
        alignment: Alignment.center,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off, size: 48, color: Colors.amber.shade400),
              const SizedBox(height: 8),
              const Text(
                'Camera Permission Blocked',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                'Blind Assistant requires camera access to detect obstacles and guide you. Please enable camera permission in device settings.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: onOpenAppSettings,
                icon: const Icon(Icons.settings),
                label: const Text('Open App Settings'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber.shade800,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (isCameraPermissionDenied) {
      return Container(
        color: Colors.grey.shade900,
        alignment: Alignment.center,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography, size: 48, color: Colors.orange.shade400),
              const SizedBox(height: 8),
              const Text(
                'Camera Permission Denied',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                'Camera access is required for real-time obstacle perception.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: onGrantCamera,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Grant Camera Permission'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal.shade700,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!isRunning ||
        cameraController == null ||
        !cameraController!.value.isInitialized) {
      return Container(
        color: Colors.grey.shade900,
        alignment: Alignment.center,
        child: const Text(
          'Tap Start to begin navigation',
          style: TextStyle(color: Colors.white70, fontSize: 20),
        ),
      );
    }
    final width = cameraController!.value.previewSize?.height ?? 1;
    final height = cameraController!.value.previewSize?.width ?? 1;

    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(cameraController!),
                CustomPaint(
                  painter: _DetectionOverlayPainter(
                    detections: detections,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StopHazardWarningBanner extends StatelessWidget {
  final String text;

  const _StopHazardWarningBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'WARNING: $text',
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.red.shade900,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.redAccent, width: 2),
        ),
        child: Row(
          children: [
            const Icon(Icons.pan_tool, color: Colors.white, size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'STOP - OBSTACLE AHEAD',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                  Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetectionOverlayPainter extends CustomPainter {
  final List<Detection> detections;

  _DetectionOverlayPainter({required this.detections});

  Color _colorForRisk(String? risk) {
    switch (risk) {
      case 'imminent':
        return const Color(0xFFFF3B30); // Red
      case 'potential':
        return const Color(0xFFFF9500); // Amber
      case 'awareness':
        return const Color(0xFF34C759); // Green
      default:
        return Colors.lightGreenAccent;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;

    for (final d in detections) {
      final color = _colorForRisk(d.riskLevel);
      final boxPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = d.riskLevel == 'imminent' ? 3.5 : 2.2;

      final double scaleX = (d.frameWidth != null && d.frameWidth! > 0)
          ? size.width / d.frameWidth!
          : 1.0;
      final double scaleY = (d.frameHeight != null && d.frameHeight! > 0)
          ? size.height / d.frameHeight!
          : 1.0;

      final double x1 = d.bbox.x1 * scaleX;
      final double y1 = d.bbox.y1 * scaleY;
      final double x2 = d.bbox.x2 * scaleX;
      final double y2 = d.bbox.y2 * scaleY;

      final rect = Rect.fromLTRB(x1, y1, x2, y2);
      canvas.drawRect(rect, boxPaint);

      final track = d.trackId != null ? '#${d.trackId} ' : '';
      final dir = d.direction != null ? ' [${d.direction?.toUpperCase()}]' : '';
      final dist = d.distanceM != null
          ? ' ~${d.distanceM!.toStringAsFixed(1)}m (est)'
          : ' [dist: uncertain]';
      final label = '$track${d.label.toUpperCase()} ${(d.confidence * 100).toInt()}%$dir$dist';

      final span = TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      );
      final tp = TextPainter(text: span, textDirection: TextDirection.ltr);
      tp.layout();

      final badgeY = (y1 - tp.height - 4).clamp(0.0, size.height - tp.height - 4);
      final badgeRect = Rect.fromLTWH(
        x1.clamp(0.0, size.width - tp.width - 8),
        badgeY,
        tp.width + 8,
        tp.height + 4,
      );

      final bgPaint = Paint()..color = Colors.black87;
      final borderPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;

      canvas.drawRRect(RRect.fromRectAndRadius(badgeRect, const Radius.circular(4)), bgPaint);
      canvas.drawRRect(RRect.fromRectAndRadius(badgeRect, const Radius.circular(4)), borderPaint);
      tp.paint(canvas, Offset(badgeRect.left + 4, badgeRect.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionOverlayPainter oldDelegate) => true;
}

class _StartStopButton extends StatelessWidget {
  final bool isRunning;
  final bool isConnecting;
  final bool isReady;
  final bool isCameraPermissionPermanentlyDenied;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onOpenAppSettings;

  const _StartStopButton({
    required this.isRunning,
    required this.isConnecting,
    required this.isReady,
    this.isCameraPermissionPermanentlyDenied = false,
    required this.onStart,
    required this.onStop,
    required this.onOpenAppSettings,
  });

  @override
  Widget build(BuildContext context) {
    if (isCameraPermissionPermanentlyDenied) {
      return Semantics(
        button: true,
        label: 'Camera permission needed. Tap to open device settings.',
        child: ElevatedButton(
          onPressed: onOpenAppSettings,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.amber.shade800,
          ),
          child: const Icon(
            Icons.settings,
            size: 40,
            color: Colors.white,
          ),
        ),
      );
    }

    final canStart = isReady && !isConnecting;
    return Semantics(
      button: true,
      label: isRunning
          ? 'Stop navigation'
          : isReady
              ? 'Start navigation'
              : 'Detection not ready — cannot start',
      child: ElevatedButton(
        onPressed: isConnecting
            ? null
            : (isRunning ? onStop : (canStart ? onStart : null)),
        style: ElevatedButton.styleFrom(
          backgroundColor: isRunning
              ? Colors.redAccent
              : isReady
                  ? Colors.white
                  : Colors.grey.shade600,
        ),
        child: isConnecting
            ? const CircularProgressIndicator()
            : Icon(
                isRunning ? Icons.stop : Icons.play_arrow,
                size: 40,
                color: isRunning ? Colors.white : Colors.black,
              ),
      ),
    );
  }
}

