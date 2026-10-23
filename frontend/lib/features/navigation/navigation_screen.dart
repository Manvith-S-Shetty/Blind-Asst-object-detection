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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Blind Assistant'),
        actions: [
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
            // Connection status banner — shown when not connected
            _ConnectionStatusBanner(
              connectionManager: connectionManager,
              onRetry: () => connectionManager.retry(),
              onSettings: () => context.push('/settings'),
            ),
            Expanded(
              flex: 3,
              child: _CameraPreviewArea(
                isRunning: state.isRunning,
                cameraController: controller.cameraController,
                detections: state.detections,
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
              padding: const EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _StartStopButton(
                    isRunning: state.isRunning,
                    isConnecting: state.isConnecting,
                    isBackendReady: connectionManager.isConnected,
                    onStart: controller.start,
                    onStop: controller.stop,
                  ),
                  const VoiceCommandButton(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows a non-blocking status strip at the top of the screen when the backend
/// is not connected.  Provides Retry and Settings actions.
/// When connected, renders nothing (zero height).
class _ConnectionStatusBanner extends StatelessWidget {
  final BackendConnectionManager connectionManager;
  final VoidCallback onRetry;
  final VoidCallback onSettings;

  const _ConnectionStatusBanner({
    required this.connectionManager,
    required this.onRetry,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final status = connectionManager.status;

    if (status == ConnectionStatus.connected) {
      return const SizedBox.shrink();
    }

    final (color, icon, label) = switch (status) {
      ConnectionStatus.connecting => (
          Colors.amber.shade700,
          Icons.wifi_find,
          connectionManager.statusMessage ?? 'Searching for backend…'
        ),
      ConnectionStatus.reconnecting => (
          Colors.orange.shade700,
          Icons.autorenew,
          connectionManager.statusMessage ?? 'Reconnecting…'
        ),
      ConnectionStatus.unavailable => (
          AppTheme.urgentColor,
          Icons.wifi_off,
          'Backend unavailable'
        ),
      _ => (Colors.grey.shade800, Icons.hourglass_top, 'Initialising…'),
    };

    return Semantics(
      liveRegion: true,
      label: label,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        color: color.withValues(alpha: 0.92),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
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
            if (status == ConnectionStatus.unavailable ||
                status == ConnectionStatus.reconnecting) ...[
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Retry', style: TextStyle(fontSize: 13)),
              ),
              TextButton(
                onPressed: onSettings,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Settings', style: TextStyle(fontSize: 13)),
              ),
            ],
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

  const _CameraPreviewArea({
    required this.isRunning,
    required this.cameraController,
    required this.detections,
  });

  @override
  Widget build(BuildContext context) {
    if (!isRunning || cameraController == null || !cameraController!.value.isInitialized) {
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

class _DetectionOverlayPainter extends CustomPainter {
  final List<Detection> detections;

  _DetectionOverlayPainter({required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;

    final boxPaint = Paint()
      ..color = Colors.lightGreenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    const textStyle = TextStyle(
      color: Colors.white,
      fontSize: 14,
      fontWeight: FontWeight.bold,
      backgroundColor: Colors.black87,
    );

    for (final d in detections) {
      final rect = Rect.fromLTRB(d.bbox.x1, d.bbox.y1, d.bbox.x2, d.bbox.y2);
      canvas.drawRect(rect, boxPaint);

      final track = d.trackId != null ? '#${d.trackId} ' : '';
      final dist = d.distanceM != null ? ' ${d.distanceM!.toStringAsFixed(1)}m' : '';
      final label = '$track${d.label} ${(d.confidence * 100).toInt()}%$dist';

      final span = TextSpan(text: label, style: textStyle);
      final tp = TextPainter(text: span, textDirection: TextDirection.ltr);
      tp.layout();
      tp.paint(canvas, Offset(d.bbox.x1, (d.bbox.y1 - 18).clamp(0, size.height)));
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionOverlayPainter oldDelegate) => true;
}

class _StartStopButton extends StatelessWidget {
  final bool isRunning;
  final bool isConnecting;
  final bool isBackendReady;
  final VoidCallback onStart;
  final VoidCallback onStop;

  const _StartStopButton({
    required this.isRunning,
    required this.isConnecting,
    required this.isBackendReady,
    required this.onStart,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final canStart = isBackendReady && !isConnecting;
    return Semantics(
      button: true,
      label: isRunning
          ? 'Stop navigation'
          : isBackendReady
              ? 'Start navigation'
              : 'Backend not connected — cannot start',
      child: ElevatedButton(
        onPressed: isConnecting ? null : (isRunning ? onStop : (canStart ? onStart : null)),
        style: ElevatedButton.styleFrom(
          backgroundColor: isRunning
              ? Colors.redAccent
              : isBackendReady
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
