import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:blind_assistant/core/providers.dart';
import 'package:blind_assistant/features/navigation/navigation_controller.dart';

class VoiceCommandButton extends ConsumerStatefulWidget {
  const VoiceCommandButton({super.key});

  @override
  ConsumerState<VoiceCommandButton> createState() => _VoiceCommandButtonState();
}

class _VoiceCommandButtonState extends ConsumerState<VoiceCommandButton> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _listening = false;
  bool _available = false;
  int _activeCommandEpoch = 0;

  Future<void> _ensureInitialized() async {
    if (_available) return;
    try {
      _available = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (mounted) setState(() => _listening = false);
          }
        },
        onError: (error) {
          if (mounted) setState(() => _listening = false);
        },
      );
    } catch (_) {
      _available = false;
    }
  }

  Future<void> _toggleListening() async {
    final tts = ref.read(ttsServiceProvider);
    await _ensureInitialized();
    if (!_available) {
      await tts.speak('Voice recognition is not available on this device.', interrupt: true);
      return;
    }

    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }

    // Cancel any in-flight response from a prior command
    _activeCommandEpoch++;
    await tts.stop();

    if (mounted) setState(() => _listening = true);
    await _speech.listen(
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.confirmation,
        cancelOnError: true,
      ),
      onResult: (result) {
        if (result.finalResult) {
          _handleCommand(result.recognizedWords, _activeCommandEpoch);
        }
      },
    );
  }

  Future<void> _handleCommand(String rawText, int epoch) async {
    final text = rawText.trim();
    final lower = text.toLowerCase();
    final tts = ref.read(ttsServiceProvider);
    final api = ref.read(apiServiceProvider);
    final navCtrl = ref.read(navigationControllerProvider.notifier);
    final navState = ref.read(navigationControllerProvider);
    final sessionId = navState.sessionId ?? 'default_session';

    if (text.isEmpty) {
      if (epoch == _activeCommandEpoch) {
        await tts.speak('I did not catch that. Please try again.', interrupt: true);
      }
      return;
    }

    final frameB64 = await navCtrl.captureCurrentFrameBase64();
    if (frameB64 == null) {
      if (epoch == _activeCommandEpoch) {
        await tts.speak('Please start navigation first so the camera is active.', interrupt: true);
      }
      return;
    }

    try {
      // 1. Read Text Intent
      if (lower.contains('read') ||
          lower.contains('text') ||
          lower.contains('sign') ||
          lower.contains('words') ||
          lower.contains('label')) {
        await tts.speak('Reading text in view...', interrupt: true);
        final res = await api.readText(sessionId, frameB64);
        if (epoch != _activeCommandEpoch) return; // Stale task cancellation

        final extracted = res['extracted_text'] as String?;
        final results = res['results'] as List<dynamic>?;
        if (extracted != null && extracted.trim().isNotEmpty) {
          await tts.speak(extracted.trim());
        } else if (results != null && results.isNotEmpty) {
          final words = results
              .map((r) => r['text']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .join('. ');
          await tts.speak(words.isNotEmpty ? words : 'No text was detected in view.');
        } else {
          await tts.speak('No text was detected in view.');
        }
      }
      // 2. Find Object Intent
      else if (lower.contains('find') ||
          lower.contains('locate') ||
          lower.contains('where is') ||
          lower.contains('search for') ||
          lower.contains('look for')) {
        String query = lower;
        for (final prefix in [
          'find my', 'find a', 'find', 'locate my', 'locate a', 'locate',
          'where is my', 'where is a', 'where is', 'search for', 'look for'
        ]) {
          if (query.startsWith(prefix)) {
            query = query.substring(prefix.length).trim();
            break;
          }
        }
        query = query.replaceAll(RegExp(r'[.?!]'), '').trim();
        final searchTarget = query.isEmpty ? 'object' : query;

        await tts.speak('Searching for $searchTarget...', interrupt: true);
        final res = await api.findObject(sessionId, frameB64, searchTarget);
        if (epoch != _activeCommandEpoch) return; // Stale task cancellation

        final message = res['message'] as String?;
        if (message != null && message.isNotEmpty) {
          await tts.speak(message);
        } else {
          final matches = res['matches'] as List<dynamic>?;
          if (matches != null && matches.isNotEmpty) {
            await tts.speak('Found $searchTarget in view.');
          } else {
            await tts.speak('$searchTarget is not currently detected in the camera view.');
          }
        }
      }
      // 3. Describe Scene Intent
      else if (lower.contains('what') ||
          lower.contains('describe') ||
          lower.contains('around') ||
          lower.contains('scene') ||
          lower.contains('front')) {
        await tts.speak('Analyzing scene...', interrupt: true);
        final res = await api.describeScene(sessionId, frameB64);
        if (epoch != _activeCommandEpoch) return; // Stale task cancellation

        final caption = res['caption'] as String? ?? 'No description available.';
        await tts.speak(caption);
      }
      // 4. Ambiguous / Unrecognized Intent
      else {
        if (epoch == _activeCommandEpoch) {
          await tts.speak(
            "I can read text, describe the scene, or help you find an object. Try saying 'describe the scene' or 'find my bag'.",
            interrupt: true,
          );
        }
      }
    } catch (e) {
      if (epoch == _activeCommandEpoch) {
        await tts.speak('Unable to complete request at this moment.', interrupt: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: _listening ? 'Stop listening' : 'Give a voice command',
      child: ElevatedButton(
        onPressed: _toggleListening,
        style: ElevatedButton.styleFrom(
          backgroundColor: _listening ? Colors.blueAccent : Colors.white,
        ),
        child: Icon(
          _listening ? Icons.mic : Icons.mic_none,
          size: 40,
          color: _listening ? Colors.white : Colors.black,
        ),
      ),
    );
  }
}
