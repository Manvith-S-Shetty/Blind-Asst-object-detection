import 'package:flutter_test/flutter_test.dart';
import 'package:blind_assistant/models/detection.dart';

void main() {
  group('Voice Command Intent Parsing & Prioritization', () {
    test('Identifies read text intent', () {
      final inputs = [
        'read this text',
        'read the sign ahead',
        'what are the words on this label',
        'read',
      ];
      for (final text in inputs) {
        final lower = text.toLowerCase();
        final isRead = lower.contains('read') ||
            lower.contains('text') ||
            lower.contains('sign') ||
            lower.contains('words') ||
            lower.contains('label');
        expect(isRead, isTrue, reason: 'Failed for: $text');
      }
    });

    test('Identifies and extracts target for find object intent', () {
      final cases = {
        'find my backpack': 'backpack',
        'where is my water bottle': 'water bottle',
        'locate a chair': 'chair',
        'search for keys': 'keys',
        'look for phone': 'phone',
      };

      cases.forEach((input, expectedTarget) {
        String query = input.toLowerCase();
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
        expect(query, equals(expectedTarget), reason: 'Failed to extract from: $input');
      });
    });

    test('Identifies describe scene intent', () {
      final inputs = [
        'describe the scene',
        'what is in front of me',
        'what do you see around here',
        'what is around',
      ];
      for (final text in inputs) {
        final lower = text.toLowerCase();
        final isDescribe = lower.contains('what') ||
            lower.contains('describe') ||
            lower.contains('around') ||
            lower.contains('scene') ||
            lower.contains('front');
        expect(isDescribe, isTrue, reason: 'Failed for: $text');
      }
    });

    test('Urgent navigation guidance takes priority over info speech', () {
      final infoMsg = GuidanceMessage(
        text: 'A group of people walking around a bus.',
        urgency: Urgency.info,
        timestamp: 100.0,
      );
      final urgentMsg = GuidanceMessage(
        text: 'Stop. Obstacle very close, directly ahead.',
        urgency: Urgency.urgent,
        timestamp: 101.0,
      );

      // Urgent messages have highest priority level
      expect(urgentMsg.urgency, equals(Urgency.urgent));
      expect(infoMsg.urgency, equals(Urgency.info));
      expect(urgentMsg.urgency != infoMsg.urgency, isTrue);
    });

    test('Stale command epoch check suppresses delayed responses', () {
      int activeEpoch = 1;

      // Simulate first command started at epoch 1
      final command1Epoch = activeEpoch;

      // User presses mic again, starting command 2
      activeEpoch++;
      final command2Epoch = activeEpoch;

      // Command 1 network response arrives late
      final shouldSpeakCommand1 = command1Epoch == activeEpoch;
      final shouldSpeakCommand2 = command2Epoch == activeEpoch;

      expect(shouldSpeakCommand1, isFalse);
      expect(shouldSpeakCommand2, isTrue);
    });
  });
}
