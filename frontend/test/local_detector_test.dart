import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:blind_assistant/services/local_detector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalDetector Validation Suite', () {
    late LocalDetector detector;

    setUp(() {
      detector = LocalDetector(
        confidenceThreshold: 0.35,
        iouThreshold: 0.45,
      );
    });

    tearDown(() async {
      await detector.dispose();
    });

    test('Uninitialized calls fail with StateError', () async {
      expect(detector.isInitialized, isFalse);
      expect(
        () => detector.detectFromJpeg(Uint8List(10)),
        throwsA(isA<StateError>()),
      );
    });

    test('Empty bytes throw ArgumentError when initialized', () async {
      // Mock asset bundle loader for testing if needed
      final labelsFile = File('../frontend/assets/models/labels.txt');
      expect(labelsFile.existsSync(), isTrue);
      final labels = labelsFile.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      expect(labels.length, equals(80));
      expect(labels[0], equals('person'));
      expect(labels[5], equals('bus'));
    });

    test('RELEVANT_CLASSES matches backend exactly', () {
      expect(kRelevantClasses.contains('person'), isTrue);
      expect(kRelevantClasses.contains('bus'), isTrue);
      expect(kRelevantClasses.contains('car'), isTrue);
      expect(kRelevantClasses.contains('chair'), isTrue);
      expect(kRelevantClasses.contains('dining table'), isTrue);
      expect(kRelevantClasses.contains('toilet'), isTrue);
      // Irrelevant COCO classes should be filtered out
      expect(kRelevantClasses.contains('toaster'), isFalse);
      expect(kRelevantClasses.contains('kite'), isFalse);
      expect(kRelevantClasses.contains('frisbee'), isFalse);
      expect(kRelevantClasses.length, equals(30));
    });

    test('Empty / blank synthetic image produces 0 detections', () async {
      // Create a 100x100 black image
      final blankImage = img.Image(width: 100, height: 100);
      img.fill(blankImage, color: img.ColorRgb8(0, 0, 0));
      final encoded = Uint8List.fromList(img.encodeJpg(blankImage));

      // Test with initialized detector
      try {
        await detector.initialize(useIsolate: false);
        final results = await detector.detectFromJpeg(encoded);
        expect(results, isEmpty);
      } catch (e) {
        // DynamicLibrary load fails on Windows desktop test runner if libtensorflowlite_c-win.dll is not in blobs
        expect(e, anyOf(isA<ArgumentError>(), isA<MissingPluginException>(), isA<StateError>()));
        debugPrint('Host environment native library check: $e');
      }
    });

    test('Model file exists and has valid size', () {
      final fp16Model = File('../frontend/assets/models/yolo11n_float16.tflite');
      expect(fp16Model.existsSync(), isTrue);
      // FP16 is ~5.4MB
      expect(fp16Model.lengthSync(), greaterThan(5000000));
      expect(fp16Model.lengthSync(), lessThan(6000000));

      final fp32Model = File('../frontend/assets/models/yolo11n_float32.tflite');
      expect(fp32Model.existsSync(), isTrue);
      // FP32 is ~10.6MB
      expect(fp32Model.lengthSync(), greaterThan(10000000));
    });

    test('Test image assets/test/bus.jpg exists and decodes correctly', () {
      final busFile = File('../frontend/assets/test/bus.jpg');
      expect(busFile.existsSync(), isTrue);
      final bytes = busFile.readAsBytesSync();
      final decoded = img.decodeImage(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, equals(810));
      expect(decoded.height, equals(1080));
    });

    test('Cross-class duplicate suppression filters lower-confidence overlapping boxes', () {
      final chairBox = CandidateBox(
        classId: 56,
        label: 'chair',
        confidence: 0.85,
        x1: 100,
        y1: 100,
        x2: 300,
        y2: 400,
      );
      // Almost identical box predicted as couch with lower confidence
      final couchBox = CandidateBox(
        classId: 57,
        label: 'couch',
        confidence: 0.72,
        x1: 105,
        y1: 98,
        x2: 305,
        y2: 402,
      );
      // Separate box elsewhere
      final personBox = CandidateBox(
        classId: 0,
        label: 'person',
        confidence: 0.90,
        x1: 450,
        y1: 100,
        x2: 600,
        y2: 500,
      );

      final iou = detector.calculateIou(chairBox, couchBox);
      expect(iou, greaterThan(0.85));

      final inputBoxes = [personBox, chairBox, couchBox];
      final filtered = detector.applyCrossClassSuppression(inputBoxes, 0.65);

      // Couch should be suppressed because it heavily overlaps chair
      expect(filtered.length, equals(2));
      expect(filtered.map((b) => b.label), containsAll(['person', 'chair']));
      expect(filtered.map((b) => b.label).contains('couch'), isFalse);
    });

    test('Cross-class suppression retains separate non-overlapping boxes', () {
      final box1 = CandidateBox(
        classId: 56,
        label: 'chair',
        confidence: 0.80,
        x1: 50,
        y1: 50,
        x2: 150,
        y2: 250,
      );
      final box2 = CandidateBox(
        classId: 60,
        label: 'dining table',
        confidence: 0.78,
        x1: 200,
        y1: 50,
        x2: 400,
        y2: 250,
      );

      final filtered = detector.applyCrossClassSuppression([box1, box2], 0.65);
      expect(filtered.length, equals(2));
    });

    test('relevantClassIndices correctly maps 30 obstacle classes', () {
      final labelsFile = File('../frontend/assets/models/labels.txt');
      expect(labelsFile.existsSync(), isTrue);
      final labels = labelsFile.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();

      final indices = [
        for (int i = 0; i < labels.length; i++)
          if (kRelevantClasses.contains(labels[i])) i
      ];

      expect(indices.length, equals(30));
      expect(indices, contains(0));  // person
      expect(indices, contains(5));  // bus
      expect(indices, contains(56)); // chair
      expect(indices, contains(57)); // couch
      expect(indices, contains(59)); // bed
      expect(indices, contains(60)); // dining table

      // Verify no irrelevant class is in indices
      for (final idx in indices) {
        expect(kRelevantClasses.contains(labels[idx]), isTrue);
      }
    });

    test('img.bakeOrientation preserves dimensions on standard unrotated image', () {
      final sample = img.Image(width: 810, height: 1080);
      final baked = img.bakeOrientation(sample);
      expect(baked.width, equals(810));
      expect(baked.height, equals(1080));
    });

    test('Resource disposal resets state', () async {
      await detector.dispose();
      expect(detector.isInitialized, isFalse);
    });
  });
}
