# Baseline Model Evaluation Report: YOLOv11 Nano TFLite

**Document Version:** 1.0  
**Date:** October 25, 2026  
**Target System:** Blind Assistant On-Device Navigation System  
**Model Under Test:** `frontend/assets/models/yolo11n_float16.tflite` (5.4 MB, FP16)  
**Evaluation Script:** `backend/evaluate_detector.py`  
**Artifact Output:** `backend/evaluation_report.json`

---

## 1. Executive Summary & Safety Notice

> [!WARNING]
> **Assistive Prototype Notice:** This application is an experimental assistive tool designed to aid obstacle awareness. It is **NOT** a certified safety device and must **never** be used for independent navigation without primary mobility aids (such as a white cane, guide dog, or sighted companion).

> [!IMPORTANT]
> **Smoke Test vs. True Accuracy:** The initial evaluation metrics presented below are derived from a single reference image (`bus.jpg`). This single-image evaluation is strictly a **smoke test** designed to verify:
> 1. Tensor input/output shapes and letterbox preprocessing alignment.
> 2. Normalization and color channel order (RGB vs. BGR).
> 3. Transposition and confidence thresholding across 8,400 candidate anchor boxes.
> 4. Per-class greedy Non-Maximum Suppression (NMS) and cross-class duplicate suppression.
> 
> **These results do NOT represent general real-world accuracy for indoor blind navigation.** Comprehensive real-world metrics will be established once genuine indoor obstacle datasets are collected and annotated using the Phase 3 protocol.

---

## 2. Model Architecture & Tensor Specifications

The baseline model currently deployed in the Flutter application has the following verified tensor layout:

| Parameter | Specification | Notes |
| :--- | :--- | :--- |
| **Model File** | `frontend/assets/models/yolo11n_float16.tflite` | FP16 quantized weights |
| **File Size** | 5,401,444 bytes (~5.15 MB) | Optimized for mobile deployment |
| **Input Tensor** | `[1, 640, 640, 3]`, `float32` | Letterbox resized, normalized `/ 255.0`, RGB |
| **Output Tensor** | `[1, 84, 8400]`, `float32` | 4 bounding box coordinates + 80 COCO class scores |
| **Anchor Count** | 8,400 grid anchors | Multi-scale feature pyramids (80x80, 40x40, 20x20) |
| **Label Set** | 80 classes (`frontend/assets/models/labels.txt`) | Standard COCO taxonomy |
| **Frontend Filter** | 30 classes (`kRelevantClasses`) | Filtered in `LocalDetector` service |

---

## 3. Supported vs. Unsupported Navigation Obstacle Classes

### A. Supported Classes in Current COCO-80 Baseline
The current model can detect the following indoor and outdoor obstacles:

| Obstacle Category | Classes Detected by Current Baseline Model |
| :--- | :--- |
| **People & Collision Hazards** | `person` (0) |
| **Furniture & Path Obstacles** | `chair` (56), `couch` (57), `bed` (59), `dining table` (60) |
| **Floor & Luggage Obstacles** | `backpack` (24), `suitcase` (28), `handbag` (26), `potted plant` (58) |
| **Restroom Fixtures** | `toilet` (61) |
| **Electronics & Desks** | `tv` (62), `laptop` (63) |
| **Kitchen Appliances** | `microwave` (68), `oven` (69), `sink` (71), `refrigerator` (72) |
| **Domestic Animals** | `dog` (16), `cat` (15) |
| **Small Objects** | `bottle` (39), `cup` (41), `book` (73) |

### B. Critical Navigation Classes NOT Supported by Current Model

> [!CAUTION]
> The current baseline COCO model **CANNOT** detect any of the following critical navigation hazards. It is vital not to pretend or assume these objects can be detected:
> - **`door` / `doorway` / `doorframe`:** Cannot detect open doors, closed doors, or glass doors.
> - **`stairs` / `steps` / `staircase`:** Cannot detect ascending or descending staircases (critical fall risk).
> - **`curb` / `drop-off` / `platform edge`:** Cannot detect elevation changes or tripping drop-offs.
> - **`wall` / `hallway` / `floor`:** Bounded object detector cannot perform surface or corridor segmentation.
> - **`trash can` / `wastebasket`:** Not present in standard COCO-80 dataset.
> - **`rug` / `carpet edge`:** Cannot detect loose flooring or low tripping edges.

*Note:* Incorporating `door` and `stairs` requires custom fine-tuning using the Phase 3 collection guide with `backend/train_yolo.py` and updating `frontend/assets/models/labels.txt`.

---

## 4. Smoke Test Benchmark Results

The smoke test was executed against `backend/evaluation_dataset/` with confidence threshold `0.35`, evaluation IoU threshold `0.50`, and cross-class NMS threshold `0.65`.

### Overall Summary Metrics (Smoke Test Only)
- **Total Images Evaluated:** 1 (`bus.jpg`, 810 × 1080)
- **Total Ground Truth Obstacles:** 5
- **True Positives (TP):** 5
- **False Positives (FP):** 0
- **Missed Obstacles (FN):** 0
- **Duplicate Detections:** 0
- **Overall Precision:** 100.0%
- **Overall Recall:** 100.0%
- **Overall F1-Score:** 100.0%

### Per-Class Performance
| Class Label | Ground Truth | TP | FP | FN | Duplicate Detections | Precision | Recall | F1-Score |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **`person`** | 4 | 4 | 0 | 0 | 0 | 100.0% | 100.0% | 100.0% |
| **`bus`** | 1 | 1 | 0 | 0 | 0 | 100.0% | 100.0% | 100.0% |
| *All Other 28 Classes* | 0 | 0 | 0 | 0 | 0 | N/A* | N/A* | N/A* |

*\*Note: No ground-truth samples for indoor furniture or household obstacles are present in the one-image smoke test.*

---

## 5. Latency and Inference Speed

Measurements captured on host execution (Python 3.10, TensorFlow Lite CPU XNNPACK delegate, 640×640 input):

| Pipeline Stage | Latency (ms) | Percentage of Frame Time |
| :--- | :---: | :---: |
| **Letterbox Preprocessing & Normalization** | 11.5 ms | ~6.7% |
| **TFLite Forward Inference Pass** | 119.6 ms | ~69.5% |
| **Transpose, Filtering & NMS Postprocessing** | 41.0 ms | ~23.8% |
| **Total Pipeline Latency** | **172.1 ms** | **100% (~5.8 FPS)** |

*Mobile On-Device Comparison:* On modern Android smartphones (Snapdragon 8 Gen 2 / Google Tensor G3 with NNAPI / GPU delegate), inference typically achieves 25–45 ms (~20–30 FPS), leaving substantial headroom for Flutter camera stream throttling.

---

## 6. How to Reproduce Baseline Evaluation

To reproduce this benchmark or evaluate on newly collected indoor test data, run:

```powershell
# Benchmark using the evaluation dataset definition
python backend/evaluate_detector.py --data backend/evaluation_dataset/dataset.yaml

# Benchmark on a custom indoor test split
python backend/evaluate_detector.py --model frontend/assets/models/yolo11n_float16.tflite --dataset data/indoor_obstacles --split val --conf 0.35
```

The script prints the full metrics table to the terminal and updates `backend/evaluation_report.json`.

---

## 7. Fine-Tuning Comparison Template

When custom indoor training data is annotated and fine-tuning is conducted, record comparative metrics in the table below:

| Metric | Baseline Model (`yolo11n_float16`) | Fine-Tuned Model (`best.tflite`) | Delta |
| :--- | :---: | :---: | :---: |
| **Validation Image Count** | *(Smoke test: 1)* | *[Enter Count]* | — |
| **Overall Precision** | *[Pending Indoor Data]* | *[Pending]* | — |
| **Overall Recall** | *[Pending Indoor Data]* | *[Pending]* | — |
| **Overall F1-Score** | *[Pending Indoor Data]* | *[Pending]* | — |
| **`chair` Recall** | *[Pending Indoor Data]* | *[Pending]* | — |
| **`person` Recall** | *[Pending Indoor Data]* | *[Pending]* | — |
| **`dining table` Recall**| *[Pending Indoor Data]* | *[Pending]* | — |
| **`bed` Recall** | *[Pending Indoor Data]* | *[Pending]* | — |
| **`backpack` / `suitcase` Recall** | *[Pending Indoor Data]* | *[Pending]* | — |
| **Door Detection Capability** | **Unsupported (0%)** | *[Pending Custom Head]* | — |
| **Stairs Detection Capability** | **Unsupported (0%)** | *[Pending Custom Head]* | — |
| **Mean Inference Time (ms)** | 119.6 ms (Host CPU) | *[Enter ms]* | — |
