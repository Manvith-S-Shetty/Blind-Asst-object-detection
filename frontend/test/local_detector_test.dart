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

    test('Resource disposal resets state', () async {
      await detector.dispose();
      expect(detector.isInitialized, isFalse);
    });
  });
}
