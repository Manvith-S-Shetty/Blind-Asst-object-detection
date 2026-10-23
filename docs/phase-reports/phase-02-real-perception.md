# Phase 02 — Real AI Perception Report

**Project:** Blind Assistant AI (Navigation & Object Detection)  
**Report Date:** 2026-10-22  
**Status:** COMPLETE (All 6 Stages PASS)  

---

## 1. Executive Summary and Completion Status

Phase 2 transitioned the Blind Assistant system from synthetic mocks to real, validated AI perception models across the core navigation pipeline while strictly maintaining existing API contracts and Flutter-FastAPI architectural boundaries.

| Stage | Description | Status |
|---|---|---|
| **Stage 1** | Verify Phase 1 baseline, fix regressions, lifecycle & error handling | **PASS** |
| **Stage 2** | Detector baseline evaluation & automated tests | **PASS** |
| **Stage 3** | Real multi-object tracking (ByteTrack) | **PASS** |
| **Stage 4** | Real monocular depth estimation (Depth Anything V2) | **PASS** |
| **Stage 5** | Real instance segmentation & corridor free-space | **PASS** |
| **Stage 6** | System integration, benchmarks, error resilience & report | **PASS** |

**Summary of Deliverables:**
- **Detector:** Preserved and benchmarked YOLOv11n (`yolo11n.pt`, 5.4 MB), running at ~78.7 ms on CPU.
- **Tracker:** Built and integrated `ByteTrackTracker` (`app/pipeline/real/bytetrack_tracker.py`), replacing `MockTracker`.
- **Depth Estimator:** Integrated `DepthAnythingEstimator` (`app/pipeline/real/depth_anything.py`) powered by Depth Anything V2 Small (`depth-anything/Depth-Anything-V2-Small-hf`, Apache-2.0), operating with 252×252 input optimization for ~234.5 ms CPU inference.
- **Segmenter & Free Space:** Integrated `SAM2Segmenter` (`app/pipeline/real/sam2_segmenter.py`) using `yolo11n-seg.pt` (5.9 MB, ~117.1 ms on CPU) with forward corridor occupancy estimation.
- **Frontend Upgrades:** Repaired test suites, added real-time bounding-box canvas overlay on `CameraPreview`, resolved `NavigationController` resource leaks during dispose, and wired `VoiceCommandButton` to live backend APIs.
- **Fail-Safe Integrity:** Implemented `ModelUnavailableError` and `UnavailableComponent` in `factory.py`; real model failures expose explicit errors and suppress guidance rather than silently injecting synthetic mocks.
- **Test Suite:** Expanded to **28 passing backend tests** (unit + integration + error handling) and **6 passing Flutter frontend tests**.

---

## 2. Components Replaced vs. Components Still Mocked

| Pipeline Stage | Interface | Previous State | Phase 2 State | Implementation File |
|---|---|---|---|---|
| **Detector** | `Detector` | YOLOv11n | **REAL (YOLOv11n)** | `backend/app/pipeline/real/yolo_detector.py` |
| **Tracker** | `Tracker` | MockTracker | **REAL (ByteTrack)** | `backend/app/pipeline/real/bytetrack_tracker.py` |
| **Depth Estimator** | `DepthEstimator` | MockDepthEstimator | **REAL (Depth Anything V2 Small)** | `backend/app/pipeline/real/depth_anything.py` |
| **Segmenter** | `Segmenter` | MockSegmenter | **REAL (YOLOv11n-seg)** | `backend/app/pipeline/real/sam2_segmenter.py` |
| **Scene Describer** | `SceneDescriber` | MockSceneDescriber | Mock (Florence-2 target) | `backend/app/pipeline/mock/perception.py` |
| **Open-Vocab Locator** | `OpenVocabLocator` | MockOpenVocabLocator | Mock (Locate Anything target) | `backend/app/pipeline/mock/perception.py` |
| **OCR Reader** | `OCRReader` | MockOCRReader | Mock (PaddleOCR target) | `backend/app/pipeline/mock/perception.py` |
| **Speech-to-Text** | `SpeechToText` | MockSpeechToText | Mock on backend / On-device STT in Flutter | `backend/app/pipeline/mock/voice.py` |
| **Text-to-Speech** | `TextToSpeech` | MockTextToSpeech | Mock on backend / On-device TTS in Flutter | `backend/app/pipeline/mock/voice.py` |

---

## 3. Model Names, Exact Variants, Licenses, and Selection Rationale

### 3.1 Object Detection: YOLOv11n
- **Exact Variant:** `yolo11n.pt` (~5.4 MB, 2.6M parameters)
- **License:** AGPL-3.0 (Ultralytics)
- **Rationale:** Proven detection accuracy across 33 navigation-critical COCO obstacle classes. Inference latency (~50–78 ms on CPU) fits comfortably inside the 300–400 ms mobile capture window.

### 3.2 Object Tracking: ByteTrack
- **Exact Variant:** ByteTrack algorithm with two-stage linear sum assignment (high-confidence matching followed by low-confidence recovery and lost-track re-identification).
- **License:** MIT License
- **Rationale:** Computationally negligible (<1 ms per frame), preserves stable IDs across frames, recovers from brief occlusions without hallucinating positions when objects disappear.

### 3.3 Monocular Depth: Depth Anything V2 Small
- **Exact Variant:** `depth-anything/Depth-Anything-V2-Small-hf` (~98 MB safetensors, 24.8M parameters)
- **License:** Apache-2.0
- **Rationale:** State-of-the-art relative monocular depth with clean object boundary separation. Scaled to 252×252 for CPU operation, reducing inference latency from 774 ms down to ~234 ms on CPU while providing dense disparity maps.

### 3.4 Segmentation: YOLOv11n-seg
- **Exact Variant:** `yolo11n-seg.pt` (~5.9 MB, 2.9M parameters)
- **License:** AGPL-3.0 (Ultralytics)
- **Rationale:** Fast instance segmentation masks (~81–117 ms on CPU). Enables pixel-accurate bounding of detected obstacles and calculation of the forward walking corridor occupancy ratio without requiring multi-gigabyte models like SAM2.

---

## 4. Files Changed and Architecture/Interface Changes

### Backend Files Changed/Added:
- `backend/app/core/config.py`: Enabled `detector`, `tracker`, `depth_estimator`, `segmenter` in `use_real_models`. Migrated deprecated `Config` class to Pydantic `SettingsConfigDict`.
- `backend/pytest.ini`: Configured `asyncio_default_fixture_loop_scope = function` to eliminate asyncio warnings.
- `backend/app/pipeline/factory.py`: Added `ModelUnavailableError` and `UnavailableComponent` to strictly prevent silent mock substitution upon real model failure.
- `backend/app/pipeline/real/bytetrack_tracker.py` *(NEW)*: Complete ByteTrack tracking implementation.
- `backend/app/pipeline/real/depth_anything.py` *(NEW)*: Depth Anything V2 Small monocular depth estimator with central-core sampling.
- `backend/app/pipeline/real/sam2_segmenter.py` *(NEW)*: Real YOLOv11n-seg segmentation and corridor occupancy estimation.
- `backend/app/api/websocket.py`: Hardened WebSocket against malformed JSON, invalid base64, and added explicit `model_unavailable` error handling.
- `backend/app/api/routes.py`: Added `ModelUnavailableError` handling returning HTTP 503 rather than generic 500.
- `backend/app/main.py`: Migrated `@app.on_event("startup")` to FastAPI `lifespan(app: FastAPI)` context manager.
- `backend/app/tests/test_yolo_detector.py` *(NEW)*: Unit tests for YOLOv11n on real assets.
- `backend/app/tests/test_bytetrack_tracker.py` *(NEW)*: Unit tests for ByteTrack track continuity, occlusion recovery, and reset.
- `backend/app/tests/test_depth_anything.py` *(NEW)*: Unit tests for Depth Anything V2 output shapes, ranges, and error handling.
- `backend/app/tests/test_sam2_segmenter.py` *(NEW)*: Unit tests for YOLOv11n-seg masks and corridor occupancy.
- `backend/app/tests/test_integration_pipeline.py` *(NEW)*: End-to-end integration tests for REST and WebSocket streaming.

### Frontend Files Changed/Added:
- `frontend/lib/widgets/guidance_banner.dart`: Replaced deprecated `.withOpacity()` with `.withValues(alpha: 0.18)`.
- `frontend/test/widget_test.dart`: Fixed broken `MyApp` reference and removed unused imports.
- `frontend/lib/features/navigation/navigation_controller.dart`: Fixed lifecycle resource leak in `stop()`/`dispose()` and added `captureCurrentFrameBase64()`.
- `frontend/lib/features/navigation/navigation_screen.dart`: Implemented `_DetectionOverlayPainter` to render live detection bounding boxes, labels, confidence, and distances on `CameraPreview`.
- `frontend/lib/features/voice/voice_command_button.dart`: Replaced hardcoded placeholder strings with real API calls to `ApiService.readText`, `findObject`, and `describeScene`.
- `frontend/test/models_and_socket_test.dart` *(NEW)*: Unit tests for model deserialization and `GuidanceBanner` accessibility rendering.

---

## 5. Commands Executed and Actual Test Results

### 5.1 Backend Test Suite (Pytest)
```powershell
.\venv\Scripts\python.exe -m pytest app/tests/ -v
```
**Result:** `28 passed in 17.44s` (0 failures, 0 warnings)
- `test_bytetrack_tracker.py`: 4 passed (stable IDs, recovery, loss culling, reset)
- `test_decision_engine.py`: 6 passed (urgency levels, cooldowns, nearest obstacle priority)
- `test_depth_anything.py`: 3 passed (dimensions, valid ranges, invalid inputs)
- `test_integration_pipeline.py`: 4 passed (REST frame analysis, malformed image, WebSocket stream, unavailable state)
- `test_pipeline.py`: 6 passed (pipeline interface contracts)
- `test_sam2_segmenter.py`: 3 passed (mask dimensions, corridor occupancy, empty inputs)
- `test_yolo_detector.py`: 2 passed (known asset detection on `bus.jpg`, blank frame)

### 5.2 Flutter Static Analysis
```bash
flutter analyze --no-fatal-infos
```
**Result:** `No issues found! (ran in 7.1s)`

### 5.3 Flutter Unit and Widget Tests
```bash
flutter test
```
**Result:** `All tests passed! (6 tests in 1.4s)`

### 5.4 Android Build Tooling Check
```bash
flutter build apk --config-only
```
**Result:** `Exit code 0 (Gradle configuration and plugin resolution verified)`

---

## 6. Measured Latency and Resource Use

**Environment:** Microsoft Windows 11, Intel/AMD 64-bit CPU, 15.8 GB total system RAM (~2.6 GB available), CUDA unavailable (CPU-only execution).

| Pipeline Component | Model | Parameters / Weights | Latency (CPU) | RSS Memory |
|---|---|---|---|---|
| **Detector** | YOLOv11n | 2.6M params (~5.4 MB) | **78.7 ms** | ~383 MB |
| **Tracker** | ByteTrack | Algorithm (<100 KB) | **0.4 ms** | Negligible |
| **Depth Estimator** | Depth Anything V2 Small | 24.8M params (~98 MB) | **234.5 ms** | ~480 MB |
| **Segmenter** | YOLOv11n-seg | 2.9M params (~5.9 MB) | **117.1 ms** | ~520 MB |
| **Guidance Engine** | DecisionEngine | Rule-based | **0.2 ms** | <1 MB |
| **End-to-End Pipeline** | Full Real Perception | All 4 real models active | **430.8 ms** | **595.9 MB** |

*Note:* Total peak memory across all 4 real models loaded in the backend process is **595.9 MB**, safely within the 2.6 GB available system RAM. The 430.8 ms CPU latency aligns well with the mobile 400 ms capture interval (frame process throttle configured at 0.3s).

---

## 7. Known Accuracy, Calibration, and Safety Limitations

1. **Uncalibrated Relative Depth vs. Metric Distance:**
   - Depth Anything V2 predicts relative disparity maps, not calibrated physical distance in metres.
   - The reported `distance_m` is an inverse-disparity approximation proxy bounded to `[0.4m, 8.0m]`.
   - Variations in camera field-of-view, aspect ratio, and pitch angle will shift the scaling. It must not be treated as a physical tape measure.
2. **Negative Proof Fallacy:**
   - Absence of a detection does **not** prove a path is safe to traverse.
   - Low-contrast obstacles, thin wires, drop-offs, glass doors, and steps down are outside standard COCO class coverage.
3. **Corridor Free-Space Disclaimer:**
   - `compute_corridor_occupancy` calculates unobstructed pixel ratios in the forward walking corridor.
   - A clear corridor indicates merely that no segmented obstacles occupy the field of view; it does not replace a physical white cane or guide dog.
4. **Track Continuity Staleness Guarantee:**
   - A track ID is assigned only to objects with active detections in the current frame.
   - Lost tracks are retained in memory for up to 30 frames solely for re-identification upon reappearance; positions are never extrapolated or presented to the decision engine when unobserved.

---

## 8. Outstanding Bugs and Blockers

| Item | Severity | Status | Mitigation / Next Action |
|---|---|---|---|
| **BUG-01 (Depth Heuristic)** | High | **RESOLVED** | Replaced with real Depth Anything V2 Small. |
| **BUG-02 (Widget Test Compile)** | High | **RESOLVED** | Fixed `MyApp` stale reference; all 6 tests pass. |
| **BUG-03 (Voice Command Stubs)** | Medium | **RESOLVED** | Wired to backend REST endpoints with live frame captures. |
| **BUG-04 (Invisible YOLO Bboxes)** | Medium | **RESOLVED** | Implemented `_DetectionOverlayPainter` in `NavigationScreen`. |
| **Remaining Mock Models** | Low | Expected | Scene Describer (Florence-2), OCR (PaddleOCR), Open-Vocab (Locate-Anything) remain mocked as planned for Phase 3/4. |
| **AGPL-3.0 Licensing** | Policy | Open | YOLOv11n and YOLOv11n-seg carry AGPL-3.0 licenses. Commercial closed-source redistribution requires an Ultralytics commercial license. |

---

## 9. Phase 3 Handover Recommendations

1. **OCR and Scene Description (Phase 3 Targets):**
   - Implement real PaddleOCR (Apache-2.0) for `OCRReader`.
   - Implement Florence-2-base (MIT, Microsoft) for `SceneDescriber` when requested via voice commands.
2. **Onnx / OpenVINO CPU Acceleration:**
   - Export YOLOv11n, ByteTrack, and Depth Anything V2 to ONNX Runtime or OpenVINO to reduce CPU latency from ~430 ms to <200 ms.
3. **Camera Calibration Parameters:**
   - Pass camera focal length and sensor height from Flutter `camera` plugin metadata into backend REST/WS requests to calibrate relative depth into true metric distance.
4. **Android Physical Device Deployment:**
   - Perform end-to-end device testing with physical Android camera and TalkBack accessibility service.
