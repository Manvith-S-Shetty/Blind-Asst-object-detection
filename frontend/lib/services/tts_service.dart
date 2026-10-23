import 'package:flutter_tts/flutter_tts.dart';
import 'package:blind_assistant/models/detection.dart';

/// Wraps flutter_tts. Urgent guidance interrupts whatever is currently
/// being spoken (safety first); info/warn messages queue normally.
///
/// Supports command interruption to prevent stale voice command responses
/// from overlapping or playing after the user changes context.
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await _tts.setSpeechRate(0.55);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(false);
    _initialized = true;
  }

  Future<void> speakGuidance(GuidanceMessage message) async {
    await init();
    if (message.urgency == Urgency.urgent) {
      await _tts.stop(); // interrupt whatever's playing — safety over politeness
    }
    await _tts.speak(message.text);
  }

  Future<void> speak(String text, {bool interrupt = false}) async {
    await init();
    if (interrupt) {
      await _tts.stop();
    }
    await _tts.speak(text);
  }

  Future<void> stop() => _tts.stop();
}
