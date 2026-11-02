import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:blind_assistant/models/detection.dart';

/// Represents a single unit of work in the serialized speech queue.
class SpeechJob {
  final String text;
  final Urgency urgency;
  final bool isGuidance;
  final int createdAtMs;
  final Completer<bool> completer;

  SpeechJob({
    required this.text,
    required this.urgency,
    required this.isGuidance,
    required this.createdAtMs,
    required this.completer,
  });
}

/// Serialized speech queue service wrapping [FlutterTts].
///
/// SAFETY & ACCESSIBILITY GUARANTEES:
/// 1. Exactly one active speech output at a time (strict serialized queue).
/// 2. Genuinely urgent obstacle warnings cancel or preempt lower-priority speech.
/// 3. Routine status updates and lower-priority guidance NEVER interrupt an active urgent hazard warning
///    unless an explicit interruption (e.g. user navigation stop) is commanded.
/// 4. Repeated identical messages are deduplicated to avoid continuous speech spam.
/// 5. Guidance messages are coalesced: frequent frame updates replace any pending guidance
///    in the queue with the latest useful instruction.
/// 6. Stale guidance (> 3.5 seconds in queue) is automatically discarded.
/// 7. Robust lifecycle recovery: errors, cancellations, and a watchdog timeout ensure
///    the queue can never become permanently stuck.
class TtsService {
  final FlutterTts _tts;
  bool _initialized = false;
  bool _speechEnabled = true;

  final List<SpeechJob> _queue = [];
  SpeechJob? _activeJob;
  bool _isSpeaking = false;
  bool _processingQueue = false;
  Urgency? _currentUrgency;
  String? _currentText;

  Timer? _watchdogTimer;

  TtsService({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  bool get speechEnabled => _speechEnabled;
  set speechEnabled(bool enabled) {
    _speechEnabled = enabled;
    debugPrint('[TTS] speechEnabled set to: $enabled');
    if (!enabled) {
      stop();
    }
  }

  bool get isSpeaking => _activeJob != null || _isSpeaking;
  Urgency? get currentUrgency => _activeJob?.urgency ?? _currentUrgency;
  String? get currentText => _activeJob?.text ?? _currentText;
  int get queueLength => _queue.length;

  Future<void> init() async {
    if (_initialized) return;
    try {
      debugPrint('[TTS] Initializing TextToSpeech engine...');
      try {
        await _tts.setLanguage('en-US');
      } catch (e) {
        debugPrint('[TTS] setLanguage exception (ignored if unsupported): $e');
      }
      await _tts.setSpeechRate(0.55);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(false);

      _tts.setStartHandler(() {
        debugPrint('[TTS] Started speaking: "$_currentText"');
        _isSpeaking = true;
      });

      _tts.setCompletionHandler(() {
        debugPrint('[TTS] Completed speaking: "$_currentText"');
        _onUtteranceFinished();
      });

      _tts.setCancelHandler(() {
        debugPrint('[TTS] Cancelled speaking: "$_currentText"');
        _onUtteranceFinished();
      });

      _tts.setErrorHandler((dynamic msg) {
        debugPrint('[TTS] Native error: $msg');
        _onUtteranceFinished();
      });

      _initialized = true;
      debugPrint('[TTS] Engine initialized successfully');
    } catch (e) {
      debugPrint('[TTS] Init exception (non-fatal on testing hosts): $e');
      _initialized = true;
    }
  }

  /// Announces a navigation guidance message according to priority rules.
  ///
  /// - Genuinely urgent warnings preempt active lower-priority speech.
  /// - Non-urgent guidance does not interrupt active urgent warnings.
  /// - Coalesces frequent frame updates into the newest guidance instruction.
  /// - Deduplicates identical active/queued messages.
  Future<bool> speakGuidance(GuidanceMessage message) async {
    await init();
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. Routine guidance MUST NEVER interrupt an active urgent hazard warning
    if (_activeJob != null &&
        _activeJob!.urgency == Urgency.urgent &&
        message.urgency != Urgency.urgent) {
      return false;
    }

    // 2. Urgent warning preemption
    if (message.urgency == Urgency.urgent) {
      // If currently speaking this exact urgent message, don't restart it
      if (_activeJob != null && _activeJob!.text == message.text) {
        return false;
      }

      await _preemptForUrgent();
      final job = SpeechJob(
        text: message.text,
        urgency: Urgency.urgent,
        isGuidance: true,
        createdAtMs: now,
        completer: Completer<bool>(),
      );
      _queue.insert(0, job);
      _processQueue();
      return true;
    }

    // 3. Deduplication: drop identical message if already active or waiting in queue
    if (_activeJob?.text == message.text || _queue.any((j) => j.text == message.text)) {
      return false;
    }

    // 4. Coalescing: frequent frame updates coalesce into the single latest pending guidance
    final existingGuidanceIndex = _queue.indexWhere((j) => j.isGuidance);
    final job = SpeechJob(
      text: message.text,
      urgency: message.urgency,
      isGuidance: true,
      createdAtMs: now,
      completer: Completer<bool>(),
    );

    if (existingGuidanceIndex >= 0) {
      // Discard older pending guidance in favor of this fresher instruction
      _queue[existingGuidanceIndex].completer.complete(false);
      _queue[existingGuidanceIndex] = job;
    } else {
      _queue.add(job);
    }

    _processQueue();
    return true;
  }

  /// Speaks system notices, confirmations, or voice command responses.
  ///
  /// - Respects active urgent warnings (routine updates will not preempt urgent unless forced with [interrupt]).
  /// - If [interrupt] is true, preempts active speech.
  Future<bool> speak(
    String text, {
    bool interrupt = false,
    Urgency urgency = Urgency.info,
  }) async {
    await init();
    final now = DateTime.now().millisecondsSinceEpoch;

    // Rule: Routine system messages must NEVER interrupt an active urgent hazard alert
    // unless interrupt is explicitly requested (e.g. navigation cancelled/stopped)
    if (_activeJob != null &&
        _activeJob!.urgency == Urgency.urgent &&
        urgency != Urgency.urgent &&
        !interrupt) {
      return false;
    }

    // Deduplication check for routine speech
    if (!interrupt && (_activeJob?.text == text || _queue.any((j) => j.text == text))) {
      return false;
    }

    if (interrupt) {
      await _cancelActiveSpeech();
    }

    final job = SpeechJob(
      text: text,
      urgency: urgency,
      isGuidance: false,
      createdAtMs: now,
      completer: Completer<bool>(),
    );

    if (interrupt || urgency == Urgency.urgent) {
      _queue.insert(0, job);
    } else {
      _queue.add(job);
    }

    _processQueue();
    return true;
  }

  /// Processes queued speech sequentially. Ensures only one utterance is active at a time.
  /// 
  /// REENTRANCY GUARD: Native Android TTS callbacks (completion, cancel, error) can fire
  /// synchronously inside `_tts.speak()` or `_tts.stop()`, which would recursively call
  /// `_onUtteranceFinished` -> `_processQueue`. The `_processingQueue` flag prevents
  /// this recursion from causing double-dispatch or queue corruption.
  Future<void> _processQueue() async {
    if (_activeJob != null || _processingQueue) {
      return; // Utterance in progress or already inside processQueue.
    }

    _processingQueue = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;

      while (_queue.isNotEmpty) {
        final candidate = _queue.removeAt(0);

        // Check if speech is globally enabled
        if (!_speechEnabled) {
          debugPrint('[TTS] Speech disabled. Discarding: "${candidate.text}"');
          if (!candidate.completer.isCompleted) {
            candidate.completer.complete(false);
          }
          continue;
        }

        // Discard stale guidance messages (> 3.5 seconds old)
        if (candidate.isGuidance && (now - candidate.createdAtMs > 3500)) {
          debugPrint('[TTS] Discarding stale guidance: "${candidate.text}"');
          if (!candidate.completer.isCompleted) {
            candidate.completer.complete(false);
          }
          continue;
        }

        _activeJob = candidate;
        _isSpeaking = true;
        _currentUrgency = candidate.urgency;
        _currentText = candidate.text;

        // Dynamic watchdog timer based on utterance length (min 2.5s, max 7.0s)
        final timeoutMs = (candidate.text.length * 110).clamp(2500, 7000);
        _watchdogTimer?.cancel();
        _watchdogTimer = Timer(Duration(milliseconds: timeoutMs), () {
          debugPrint('[TTS] Watchdog timeout (${timeoutMs}ms) fired for: "${candidate.text}"');
          _onUtteranceFinished();
        });

        try {
          debugPrint('[TTS] Speaking: "${candidate.text}" (urgency: ${candidate.urgency})');
          final dynamic res = await _tts.speak(candidate.text);
          debugPrint('[TTS] Native speak call returned: $res');
          // On Android, a return value of 0 indicates failure or unready engine.
          // In that scenario, completion callback won't be fired by Android native code.
          if (res == 0) {
            debugPrint('[TTS] Native speak returned 0 (not ready / failed). Advancing queue.');
            _onUtteranceFinished();
          }
        } catch (e) {
          debugPrint('[TTS] Speak exception: $e');
          _onUtteranceFinished();
        }
        return;
      }
    } finally {
      _processingQueue = false;
    }
  }

  /// Invoked when the current utterance finishes, cancels, or errors out.
  void _onUtteranceFinished() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;

    final finishedJob = _activeJob;
    _activeJob = null;
    _isSpeaking = false;
    _currentUrgency = null;
    _currentText = null;

    if (finishedJob != null && !finishedJob.completer.isCompleted) {
      finishedJob.completer.complete(true);
    }

    // Process next queued message if available.
    // Wrapped in try/catch to prevent queue processor errors from
    // permanently locking the speech pipeline.
    try {
      _processQueue();
    } catch (e) {
      debugPrint('[TTS] _processQueue error after utterance finished: $e');
    }
  }

  /// Preempts active speech and clears lower-priority queued messages for an urgent hazard.
  ///
  /// CALLBACK SUPPRESSION: `_tts.stop()` on Android fires the cancel handler
  /// synchronously, which would call `_onUtteranceFinished` -> `_processQueue`
  /// before we've finished setting up the urgent preemption. We clear `_activeJob`
  /// first and rely on the reentrancy guard in `_processQueue` to handle this safely.
  Future<void> _preemptForUrgent() async {
    debugPrint('[TTS] Preempting active speech for urgent obstacle warning');
    _watchdogTimer?.cancel();
    _watchdogTimer = null;

    // Remove all non-urgent queued items
    _queue.removeWhere((job) {
      if (job.urgency != Urgency.urgent) {
        if (!job.completer.isCompleted) job.completer.complete(false);
        return true;
      }
      return false;
    });

    final active = _activeJob;
    _activeJob = null;
    _isSpeaking = false;
    _currentUrgency = null;
    _currentText = null;

    if (active != null && !active.completer.isCompleted) {
      active.completer.complete(false);
    }

    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// Cancels currently playing speech (e.g. on explicit user action or voice query).
  ///
  /// Same callback suppression pattern as [_preemptForUrgent].
  Future<void> _cancelActiveSpeech() async {
    debugPrint('[TTS] Cancelling active speech');
    _watchdogTimer?.cancel();
    _watchdogTimer = null;

    final active = _activeJob;
    _activeJob = null;
    _isSpeaking = false;
    _currentUrgency = null;
    _currentText = null;

    if (active != null && !active.completer.isCompleted) {
      active.completer.complete(false);
    }

    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// Immediately cancels any active speech and flushes all queued requests.
  Future<void> stop() async {
    debugPrint('[TTS] stop() called: flushing ${_queue.length} queued items');
    _watchdogTimer?.cancel();
    _watchdogTimer = null;

    for (final job in _queue) {
      if (!job.completer.isCompleted) job.completer.complete(false);
    }
    _queue.clear();

    final active = _activeJob;
    _activeJob = null;
    _isSpeaking = false;
    _currentUrgency = null;
    _currentText = null;

    if (active != null && !active.completer.isCompleted) {
      active.completer.complete(false);
    }

    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// Releases resources when app or provider disposes.
  Future<void> dispose() async {
    await stop();
  }
}
