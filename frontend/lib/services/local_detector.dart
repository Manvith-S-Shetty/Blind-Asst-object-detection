import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/detection.dart';
import 'distance_estimator.dart';

/// Obstacle and navigation classes filtered from standard COCO-80,
/// identical to backend app/pipeline/real/yolo_detector.py RELEVANT_CLASSES.
const Set<String> kRelevantClasses = {
  'person', 'bicycle', 'car', 'motorcycle', 'bus', 'train', 'truck',
  'traffic light', 'fire hydrant', 'stop sign', 'bench', 'backpack',
  'umbrella', 'handbag', 'suitcase', 'chair', 'couch', 'potted plant',
  'bed', 'dining table', 'toilet', 'tv', 'laptop', 'microwave',
  'oven', 'sink', 'refrigerator', 'book', 'dog', 'cat',
};

class LetterboxTransform {
  final double ratio;
  final double dw;
  final double dh;
  final int origWidth;
  final int origHeight;

  LetterboxTransform({
    required this.ratio,
    required this.dw,
    required this.dh,
    required this.origWidth,
    required this.origHeight,
  });
}

class CandidateBox {
  final int classId;
  final String label;
  final double confidence;
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  CandidateBox({
    required this.classId,
    required this.label,
    required this.confidence,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  double get area => max(0.0, x2 - x1) * max(0.0, y2 - y1);
}

/// On-device YOLO object detector running via TensorFlow Lite.
/// Loads model and label metadata once, keeping memory footprints light.
/// Supports running inference off the UI thread via IsolateInterpreter.
class LocalDetector {
  Interpreter? _interpreter;
  IsolateInterpreter? _isolateInterpreter;
  List<String> _labels = [];
  List<int> _relevantClassIndices = [];
  bool _isInitialized = false;
  String? _lastError;

  final double confidenceThreshold;
  final double iouThreshold;
  final double crossClassIouThreshold;
  final int inputSize;
  final MonocularDistanceEstimator distanceEstimator;

  LocalDetector({
    this.confidenceThreshold = 0.35,
    this.iouThreshold = 0.45,
    this.crossClassIouThreshold = 0.65,
    this.inputSize = 640,
    this.distanceEstimator = const MonocularDistanceEstimator(),
  });

  bool get isInitialized => _isInitialized;
  String? get lastError => _lastError;
  List<String> get labels => List.unmodifiable(_labels);
  List<int> get relevantClassIndices {
    if (_relevantClassIndices.isEmpty && _labels.isNotEmpty) {
      _relevantClassIndices = [
        for (int i = 0; i < _labels.length; i++)
          if (kRelevantClasses.contains(_labels[i])) i
      ];
    }
    return List.unmodifiable(_relevantClassIndices);
  }

  /// Initializes the local detector with the TFLite model and labels asset.
  /// Throws descriptive exceptions on failures while cleaning up resources.
  Future<void> initialize({
    String modelAsset = 'assets/models/yolo11n_float16.tflite',
    String labelsAsset = 'assets/models/labels.txt',
    int numThreads = 4,
    bool useIsolate = true,
  }) async {
    if (_isInitialized) {
      return;
    }

    try {
      // 1. Load labels
      final labelsData = await rootBundle.loadString(labelsAsset);
      _labels = labelsData
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();

      if (_labels.isEmpty) {
        throw StateError('Labels file is empty: $labelsAsset');
      }

      _relevantClassIndices = [
        for (int i = 0; i < _labels.length; i++)
          if (kRelevantClasses.contains(_labels[i])) i
      ];

      // 2. Configure Interpreter Options
      final options = InterpreterOptions()..threads = numThreads;

      // 3. Load model from asset bundle
      _interpreter = await Interpreter.fromAsset(modelAsset, options: options);

      // Verify tensor shapes
      final inputTensors = _interpreter!.getInputTensors();
      if (inputTensors.isEmpty) {
        throw StateError('Model has no input tensors');
      }
      final outputTensors = _interpreter!.getOutputTensors();
      if (outputTensors.isEmpty) {
        throw StateError('Model has no output tensors');
      }
      debugPrint('LocalDetector tensors verified: Input=${inputTensors.first.shape}, Output=${outputTensors.first.shape}');

      // 4. Optionally spawn background IsolateInterpreter for UI-offloaded inference
      if (useIsolate) {
        try {
          _isolateInterpreter = await IsolateInterpreter.create(
            address: _interpreter!.address,
            debugName: 'YoloLocalDetectorIsolate',
          );
        } catch (e) {
          debugPrint('Warning: IsolateInterpreter creation failed ($e), falling back to main interpreter.');
          _isolateInterpreter = null;
        }
      }

      _isInitialized = true;
      _lastError = null;
    } catch (e, stack) {
      _lastError = e.toString();
      _isInitialized = false;
      await dispose();
      debugPrint('LocalDetector initialization error: $e\n$stack');
      rethrow;
    }
  }

  /// Runs object detection on a live [CameraImage] from the camera stream.
  Future<List<Detection>> detectFromCameraImage(
    CameraImage cameraImage, {
    int sensorOrientation = 0,
  }) async {
    _ensureInitialized();
    var image = convertCameraImage(cameraImage);
    if (image == null) {
      throw ArgumentError('Failed to convert CameraImage to processable format');
    }

    if (sensorOrientation == 90) {
      image = img.copyRotate(image, angle: 90);
    } else if (sensorOrientation == 270) {
      image = img.copyRotate(image, angle: 270);
    } else if (sensorOrientation == 180) {
      image = img.copyRotate(image, angle: 180);
    }

    return detectFromImage(image);
  }

  /// Converts a [CameraImage] (YUV420 on Android, BGRA8888 on iOS, or JPEG) to [img.Image].
  img.Image? convertCameraImage(CameraImage cameraImage) {
    try {
      if (cameraImage.format.group == ImageFormatGroup.yuv420) {
        return _convertYuv420ToImage(cameraImage);
      } else if (cameraImage.format.group == ImageFormatGroup.bgra8888) {
        return _convertBgra8888ToImage(cameraImage);
      } else if (cameraImage.format.group == ImageFormatGroup.jpeg) {
        return img.decodeImage(cameraImage.planes[0].bytes);
      }
    } catch (e) {
      debugPrint('Error converting CameraImage: $e');
    }
    return null;
  }

  img.Image _convertYuv420ToImage(CameraImage cameraImage) {
    final width = cameraImage.width;
    final height = cameraImage.height;
    final outImg = img.Image(width: width, height: height);

    final yPlane = cameraImage.planes[0];
    final uPlane = cameraImage.planes[1];
    final vPlane = cameraImage.planes[2];

    final yBytes = yPlane.bytes;
    final uBytes = uPlane.bytes;
    final vBytes = vPlane.bytes;

    final yRowStride = yPlane.bytesPerRow;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int y = 0; y < height; y++) {
      final yOffset = y * yRowStride;
      final uvRowOffset = (y >> 1) * uvRowStride;
      for (int x = 0; x < width; x++) {
        final yVal = yBytes[yOffset + x];
        final uvOffset = uvRowOffset + (x >> 1) * uvPixelStride;
        if (uvOffset >= uBytes.length || uvOffset >= vBytes.length) {
          continue;
        }
        final uVal = uBytes[uvOffset];
        final vVal = vBytes[uvOffset];

        final r = (yVal + 1.402 * (vVal - 128)).round().clamp(0, 255);
        final g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128))
            .round()
            .clamp(0, 255);
        final b = (yVal + 1.772 * (uVal - 128)).round().clamp(0, 255);

        outImg.setPixelRgb(x, y, r, g, b);
      }
    }
    return outImg;
  }

  img.Image _convertBgra8888ToImage(CameraImage cameraImage) {
    final width = cameraImage.width;
    final height = cameraImage.height;
    final outImg = img.Image(width: width, height: height);
    final bytes = cameraImage.planes[0].bytes;
    int srcIdx = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final b = bytes[srcIdx++];
        final g = bytes[srcIdx++];
        final r = bytes[srcIdx++];
        srcIdx++; // skip alpha
        outImg.setPixelRgb(x, y, r, g, b);
      }
    }
    return outImg;
  }

  /// Runs object detection on JPEG image bytes (e.g. captured from CameraController).
  Future<List<Detection>> detectFromJpeg(Uint8List jpegBytes) async {
    _ensureInitialized();
    if (jpegBytes.isEmpty) {
      throw ArgumentError('Empty JPEG byte buffer');
    }

    var decoded = img.decodeImage(jpegBytes);
    if (decoded == null) {
      throw ArgumentError('Failed to decode image from JPEG bytes');
    }
    decoded = img.bakeOrientation(decoded);

    return detectFromImage(decoded);
  }

  /// Runs object detection on an [img.Image].
  Future<List<Detection>> detectFromImage(img.Image originalImage) async {
    _ensureInitialized();

    // 1. Letterbox resize image to 640x640 keeping aspect ratio
    final (letterboxedImg, transform) = _letterbox(originalImage, inputSize, inputSize);

    // 2. Preprocess into Float32 RGB tensor normalized to [0.0, 1.0] (NHWC: 1 x 640 x 640 x 3)
    final inputBytes = _imageToFloat32Bytes(letterboxedImg, inputSize, inputSize);

    // 3. Prepare output tensor [1, 84, 8400]
    // 84 channels: [0..3: cx, cy, w, h; 4..83: 80 class confidences] across 8400 anchor predictions
    final outputShape = [1, 84, 8400];
    final outputList = List.filled(1 * 84 * 8400, 0.0).reshape(outputShape);

    // 4. Run inference (using IsolateInterpreter off UI thread if active)
    try {
      if (_isolateInterpreter != null) {
        await _isolateInterpreter!.run(inputBytes, outputList);
      } else {
        _interpreter!.run(inputBytes, outputList);
      }
    } catch (e) {
      throw StateError('Inference execution failed: $e');
    }

    // 5. Decode output predictions and map bounding boxes back to original coordinate system
    return _postprocess(outputList, transform);
  }

  /// Decodes raw tensor outputs, filters by confidence and RELEVANT_CLASSES,
  /// and performs Non-Maximum Suppression (NMS).
  List<Detection> _postprocess(
    List<dynamic> rawOutput,
    LetterboxTransform transform,
  ) {
    // rawOutput is [1, 84, 8400]
    final batch0 = rawOutput[0] as List; // 84 rows, each of length 8400
    const numAnchors = 8400;

    final candidates = <CandidateBox>[];

    final relIndices = relevantClassIndices.isNotEmpty
        ? relevantClassIndices
        : List.generate(_labels.isNotEmpty ? _labels.length : 80, (i) => i);

    for (int a = 0; a < numAnchors; a++) {
      // Find highest class confidence specifically among relevant obstacle classes for anchor `a`
      double bestScore = 0.0;
      int bestClassId = -1;

      for (int i = 0; i < relIndices.length; i++) {
        final classId = relIndices[i];
        final score = (batch0[4 + classId][a] as num).toDouble();
        if (score > bestScore) {
          bestScore = score;
          bestClassId = classId;
        }
      }

      if (bestScore < confidenceThreshold || bestClassId < 0) {
        continue;
      }

      final label = bestClassId < _labels.length ? _labels[bestClassId] : 'unknown';

      // Box coordinates in 640x640 space (cx, cy, w, h)
      final cx = (batch0[0][a] as num).toDouble();
      final cy = (batch0[1][a] as num).toDouble();
      final w = (batch0[2][a] as num).toDouble();
      final h = (batch0[3][a] as num).toDouble();

      // Convert from center coordinates to x1, y1, x2, y2 in 640x640 space
      double x1 = cx - w / 2.0;
      double y1 = cy - h / 2.0;
      double x2 = cx + w / 2.0;
      double y2 = cy + h / 2.0;

      // Invert letterbox transform to map back to original image space
      x1 = (x1 - transform.dw) / transform.ratio;
      y1 = (y1 - transform.dh) / transform.ratio;
      x2 = (x2 - transform.dw) / transform.ratio;
      y2 = (y2 - transform.dh) / transform.ratio;

      // Clamp coordinates to image boundaries
      x1 = x1.clamp(0.0, transform.origWidth.toDouble());
      y1 = y1.clamp(0.0, transform.origHeight.toDouble());
      x2 = x2.clamp(0.0, transform.origWidth.toDouble());
      y2 = y2.clamp(0.0, transform.origHeight.toDouble());

      if (x2 > x1 && y2 > y1) {
        candidates.add(CandidateBox(
          classId: bestClassId,
          label: label,
          confidence: bestScore,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
        ));
      }
    }

    if (candidates.isEmpty) {
      return const [];
    }

    // Apply per-class Non-Maximum Suppression (NMS)
    final nmsBoxes = _applyNms(candidates, iouThreshold);

    // Suppress cross-class duplicates (e.g. model predicting both chair and couch on the same box)
    final suppressedBoxes = _applyCrossClassSuppression(
      nmsBoxes,
      crossClassIouThreshold,
    );

    // Convert to application Detection models with direction, path corridor, distance, and risk metadata
    return suppressedBoxes.map((box) {
      final centerX = (box.x1 + box.x2) / 2.0;
      final String direction;
      if (centerX < transform.origWidth * 0.33) {
        direction = 'left';
      } else if (centerX > transform.origWidth * 0.67) {
        direction = 'right';
      } else {
        direction = 'center';
      }

      final bool inPath = (direction == 'center') ||
          (box.x1 < transform.origWidth * 0.65 && box.x2 > transform.origWidth * 0.35);

      final estimate = distanceEstimator.estimateDistance(
        label: box.label,
        x1: box.x1,
        y1: box.y1,
        x2: box.x2,
        y2: box.y2,
        origWidth: transform.origWidth,
        origHeight: transform.origHeight,
        confidence: box.confidence,
      );

      final distanceM = estimate.distanceMeters;
      final proximityBand = estimate.proximityBand;

      final String riskLevel;
      if (inPath) {
        if ((distanceM != null && distanceM <= 1.5) || proximityBand == 'immediate') {
          riskLevel = 'imminent';
        } else if ((distanceM != null && distanceM <= 2.5) || proximityBand == 'near') {
          riskLevel = 'potential';
        } else {
          riskLevel = 'awareness';
        }
      } else {
        if ((distanceM != null && distanceM <= 1.2) || proximityBand == 'immediate') {
          riskLevel = 'potential';
        } else {
          riskLevel = 'awareness';
        }
      }

      return Detection(
        label: box.label,
        confidence: double.parse(box.confidence.toStringAsFixed(2)),
        bbox: BoundingBox(
          x1: double.parse(box.x1.toStringAsFixed(1)),
          y1: double.parse(box.y1.toStringAsFixed(1)),
          x2: double.parse(box.x2.toStringAsFixed(1)),
          y2: double.parse(box.y2.toStringAsFixed(1)),
        ),
        distanceM: distanceM,
        direction: direction,
        inPath: inPath,
        proximityBand: proximityBand,
        riskLevel: riskLevel,
        frameWidth: transform.origWidth,
        frameHeight: transform.origHeight,
      );
    }).toList();
  }

  /// Standard greedy Non-Maximum Suppression (NMS) per class.
  List<CandidateBox> _applyNms(List<CandidateBox> boxes, double iouThresh) {
    final Map<int, List<CandidateBox>> byClass = {};
    for (final box in boxes) {
      byClass.putIfAbsent(box.classId, () => []).add(box);
    }

    final result = <CandidateBox>[];

    for (final classBoxes in byClass.values) {
      // Sort boxes by confidence descending
      classBoxes.sort((a, b) => b.confidence.compareTo(a.confidence));

      final active = List<bool>.filled(classBoxes.length, true);

      for (int i = 0; i < classBoxes.length; i++) {
        if (!active[i]) continue;
        final current = classBoxes[i];
        result.add(current);

        for (int j = i + 1; j < classBoxes.length; j++) {
          if (!active[j]) continue;
          final other = classBoxes[j];
          final iou = _calculateIou(current, other);
          if (iou >= iouThresh) {
            active[j] = false;
          }
        }
      }
    }

    // Sort final detections by confidence descending
    result.sort((a, b) => b.confidence.compareTo(a.confidence));
    return result;
  }

  /// Suppresses duplicate bounding boxes across different classes that overlap
  /// significantly (e.g., model oscillating between 'chair' and 'couch' on same obstacle).
  List<CandidateBox> _applyCrossClassSuppression(
    List<CandidateBox> boxes,
    double threshold,
  ) {
    if (boxes.length <= 1) return boxes;
    // Boxes are already sorted descending by confidence from _applyNms
    final kept = <CandidateBox>[];
    final active = List<bool>.filled(boxes.length, true);

    for (int i = 0; i < boxes.length; i++) {
      if (!active[i]) continue;
      final current = boxes[i];
      kept.add(current);

      for (int j = i + 1; j < boxes.length; j++) {
        if (!active[j]) continue;
        final other = boxes[j];
        final iou = _calculateIou(current, other);
        if (iou >= threshold) {
          active[j] = false;
        }
      }
    }
    return kept;
  }

  @visibleForTesting
  List<CandidateBox> applyCrossClassSuppression(
    List<CandidateBox> boxes,
    double threshold,
  ) => _applyCrossClassSuppression(boxes, threshold);

  @visibleForTesting
  double calculateIou(CandidateBox a, CandidateBox b) => _calculateIou(a, b);

  /// Calculates Intersection over Union (IoU) between two bounding boxes.
  double _calculateIou(CandidateBox a, CandidateBox b) {
    final interX1 = max(a.x1, b.x1);
    final interY1 = max(a.y1, b.y1);
    final interX2 = min(a.x2, b.x2);
    final interY2 = min(a.y2, b.y2);

    final interW = max(0.0, interX2 - interX1);
    final interH = max(0.0, interY2 - interY1);
    final interArea = interW * interH;

    if (interArea <= 0.0) return 0.0;

    final unionArea = a.area + b.area - interArea;
    return unionArea > 0 ? (interArea / unionArea) : 0.0;
  }

  /// Letterbox resize: maintains aspect ratio and adds gray padding (114, 114, 114)
  (img.Image, LetterboxTransform) _letterbox(
    img.Image src,
    int targetW,
    int targetH,
  ) {
    final origW = src.width;
    final origH = src.height;

    final r = min(targetW / origW, targetH / origH);
    final newW = (origW * r).round();
    final newH = (origH * r).round();

    final resized = img.copyResize(
      src,
      width: newW,
      height: newH,
      interpolation: img.Interpolation.linear,
    );

    final canvas = img.Image(width: targetW, height: targetH);
    // Fill canvas with 114 gray background (standard YOLO letterbox color)
    img.fill(canvas, color: img.ColorRgb8(114, 114, 114));

    final dw = (targetW - newW) / 2.0;
    final dh = (targetH - newH) / 2.0;

    img.compositeImage(
      canvas,
      resized,
      dstX: dw.round(),
      dstY: dh.round(),
    );

    return (
      canvas,
      LetterboxTransform(
        ratio: r,
        dw: dw,
        dh: dh,
        origWidth: origW,
        origHeight: origH,
      )
    );
  }

  /// Converts RGB Image to normalized Float32 bytes [1, targetH, targetW, 3].
  Uint8List _imageToFloat32Bytes(img.Image image, int targetW, int targetH) {
    final float32List = Float32List(1 * targetH * targetW * 3);
    int bufferIdx = 0;

    for (int y = 0; y < targetH; y++) {
      for (int x = 0; x < targetW; x++) {
        final pixel = image.getPixel(x, y);
        float32List[bufferIdx++] = pixel.r / 255.0;
        float32List[bufferIdx++] = pixel.g / 255.0;
        float32List[bufferIdx++] = pixel.b / 255.0;
      }
    }

    return float32List.buffer.asUint8List();
  }

  void _ensureInitialized() {
    if (!_isInitialized || _interpreter == null) {
      throw StateError(
        'LocalDetector is not initialized. Call initialize() first. Last error: $_lastError',
      );
    }
  }

  /// Releases native TensorFlow Lite interpreter and isolate resources.
  Future<void> dispose() async {
    try {
      await _isolateInterpreter?.close();
    } catch (_) {}
    _isolateInterpreter = null;

    try {
      _interpreter?.close();
    } catch (_) {}
    _interpreter = null;

    _isInitialized = false;
  }
}
