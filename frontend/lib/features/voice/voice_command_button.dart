import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:blind_assistant/core/providers.dart';
import 'package:blind_assistant/features/navigation/navigation_controller.dart';
import 'package:blind_assistant/features/places/places_controller.dart';
import 'package:blind_assistant/services/place_intent_parser.dart';

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
    final permService = ref.read(permissionServiceProvider);

    // Request microphone permission ONLY on-demand when user activates voice command
    final micStatus = await permService.checkMicrophonePermission();
    PermissionStatus finalStatus = micStatus;
    if (micStatus.isPermanentlyDenied) {
      finalStatus = micStatus;
    } else if (!micStatus.isGranted) {
      finalStatus = await permService.requestMicrophonePermission();
    }

    if (finalStatus.isPermanentlyDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Microphone permission is permanently denied. Please grant permission in settings.',
            ),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: () => permService.openSettings(),
            ),
          ),
        );
      }
      await tts.speak(
        'Microphone permission is permanently denied. Please enable microphone permission in device settings.',
        interrupt: true,
      );
      return;
    } else if (!finalStatus.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Microphone permission is required for voice commands.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      await tts.speak(
        'Microphone permission is required for voice commands.',
        interrupt: true,
      );
      return;
    }

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

    // A. Check for "Next Place" Voice Command (e.g. "next", "next place", "next result")
    if (PlaceIntentParser.isNextIntent(text)) {
      if (epoch != _activeCommandEpoch) return;
      final placesCtrl = ref.read(placesControllerProvider.notifier);
      await placesCtrl.announceNextPlace();
      return;
    }

    // B. Check for "Repeat Place" Voice Command (e.g. "repeat", "repeat place", "say again", "tell me again")
    if (PlaceIntentParser.isRepeatIntent(text)) {
      if (epoch != _activeCommandEpoch) return;
      final placesCtrl = ref.read(placesControllerProvider.notifier);
      await placesCtrl.repeatCurrentPlace();
      return;
    }

    // C. Check for GPS Nearby Place Intent (e.g. "find a restaurant near me", "find pharmacy nearby", "nearest bus stop")
    final placeIntent = PlaceIntentParser.parse(text);
    if (placeIntent != null) {
      if (epoch != _activeCommandEpoch) return;
      final placesCtrl = ref.read(placesControllerProvider.notifier);
      if (mounted) {
        context.push('/places?category=${placeIntent.category.name}');
      }
      await placesCtrl.searchNearby(
        category: placeIntent.category,
        customQuery: placeIntent.customSearchTerm,
        speakResult: true,
      );
      return;
    }

    // B. Camera-dependent queries require an active camera frame
    final frameB64 = await navCtrl.captureCurrentFrameBase64();
    if (frameB64 == null) {
      if (epoch == _activeCommandEpoch) {
        await tts.speak('Please start navigation first so the camera is active.', interrupt: true);
      }
      return;
    }

    final connectionManager = ref.read(connectionManagerProvider);

    try {
      // 1. Read Text Intent
      if (lower.contains('read') ||
          lower.contains('text') ||
          lower.contains('sign') ||
          lower.contains('words') ||
          lower.contains('label')) {
        if (!connectionManager.isConnected) {
          if (epoch == _activeCommandEpoch) {
            await tts.speak('Reading text requires the optional server.', interrupt: true);
          }
          return;
        }

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
      // 2. Find Object Intent (Supported both Offline with on-device YOLO and Online with Server)
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

        if (connectionManager.isConnected) {
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
        } else {
          // On-device local search using active YOLO detections
          if (epoch != _activeCommandEpoch) return;

          final matches = navState.detections.where((d) =>
              d.label.toLowerCase() == searchTarget.toLowerCase() ||
              d.label.toLowerCase().contains(searchTarget.toLowerCase()) ||
              searchTarget.toLowerCase().contains(d.label.toLowerCase())).toList();

          if (matches.isNotEmpty) {
            final match = matches.first;
            final dirPhrase = switch (match.direction) {
              'left' => 'to your left',
              'right' => 'to your right',
              'center' => 'directly ahead',
              _ => 'in view',
            };
            await tts.speak('Found ${match.label} $dirPhrase.');
          } else {
            await tts.speak('$searchTarget is not currently detected in view.');
          }
        }
      }
      // 3. Describe Scene Intent
      else if (lower.contains('what') ||
          lower.contains('describe') ||
          lower.contains('around') ||
          lower.contains('scene') ||
          lower.contains('front')) {
        if (!connectionManager.isConnected) {
          if (epoch == _activeCommandEpoch) {
            await tts.speak('Scene description requires the optional server.', interrupt: true);
          }
          return;
        }

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
            "I can help you find nearby places, find an object, describe the scene, or read text. Try saying 'find a restaurant near me' or 'where is the chair'.",
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
