import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:blind_assistant/core/app_settings.dart';
import 'package:blind_assistant/models/detection.dart';

/// Wraps the /ws/navigate/{session_id} endpoint. Connects once, sends
/// base64 JPEG frames as they're captured with client timestamps, and exposes
/// a stream of parsed FrameResults for the UI/TTS to consume.
///
/// Supports automatic reconnection upon unexpected disconnection.
class NavigationSocket {
  final AppSettings settings;
  final String sessionId;
  WebSocketChannel? _channel;
  final _controller = StreamController<FrameResult>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  bool _isExplicitlyClosed = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;

  NavigationSocket({required this.settings, required this.sessionId});

  Stream<FrameResult> get frames => _controller.stream;
  Stream<String> get errors => _errorController.stream;
  bool get isConnected => _channel != null;

  void connect() {
    _isExplicitlyClosed = false;
    _reconnectTimer?.cancel();
    final uri = Uri.parse('${settings.wsBase}/ws/navigate/$sessionId');
    try {
      _channel = WebSocketChannel.connect(uri);
      _reconnectAttempts = 0;
      _channel!.stream.listen(
        (raw) {
          try {
            final decoded = json.decode(raw as String) as Map<String, dynamic>;
            if (decoded.containsKey('error')) {
              _errorController.add(decoded['error'] as String);
              return;
            }
            _controller.add(FrameResult.fromJson(decoded));
          } catch (e) {
            _errorController.add('Failed to parse server message: $e');
          }
        },
        onError: (e) {
          _errorController.add('WebSocket error: $e');
          _scheduleReconnect();
        },
        onDone: () {
          if (!_isExplicitlyClosed) {
            _errorController.add('Connection closed by server. Attempting reconnect...');
            _scheduleReconnect();
          }
        },
      );
    } catch (e) {
      _errorController.add('Connection failed: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_isExplicitlyClosed) return;
    _reconnectTimer?.cancel();
    _channel = null;
    _reconnectAttempts++;
    final delay = Duration(seconds: _reconnectAttempts.clamp(1, 5));
    _reconnectTimer = Timer(delay, () {
      if (!_isExplicitlyClosed) {
        connect();
      }
    });
  }

  /// Sends a frame with optional client timestamp and sequence number.
  void sendFrame(String jpegBase64, {int? clientTimestampMs, int? frameSeq}) {
    if (_channel == null) return;
    try {
      final payload = <String, dynamic>{
        'image_base64': jpegBase64,
        if (clientTimestampMs != null) 'client_timestamp_ms': clientTimestampMs,
        if (frameSeq != null) 'frame_seq': frameSeq,
      };
      _channel!.sink.add(json.encode(payload));
    } catch (_) {
      // Channel write error — will trigger onError/onDone in stream
    }
  }

  Future<void> close() async {
    _isExplicitlyClosed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _channel?.sink.close();
    _channel = null;
    await _controller.close();
    await _errorController.close();
  }
}
