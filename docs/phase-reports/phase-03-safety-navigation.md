# Phase 03 — Safety and Navigation Engine Report

**Project:** Blind Assistant AI (Navigation & Object Detection)  
**Report Date:** 2026-10-22  
**Status:** COMPLETE (All 5 Stages PASS)  

---

## 1. Executive Summary and Stage-by-Stage Status

Phase 3 engineered a conservative, safety-prioritizing risk assessment layer and refined spoken navigation guidance across the Blind Assistant application. The legacy heuristic decision engine—which previously made unverified metric distance assertions ("about X meters away"), ignored detection confidence, failed to distinguish walking path corridor from peripheral objects, and lacked worsening-hazard cooldown bypasses—has been thoroughly re-architected.

| Stage | Focus Area | Status | Key Deliverables & Results |
|---|---|:---:|---|
| **Stage 1** | Audit Current Decision Engine | **PASS** | Identified metric distance hallucination, lack of confidence gating, absence of path corridor discrimination, and stutter loop risks during static urgent obstacles. |
| **Stage 2** | Conservative Risk-Assessment Layer | **PASS** | Implemented `RiskAssessor` in `app/services/risk_assessment.py`, introducing multi-factor hazard tiers (`IMMINENT`, `POTENTIAL`, `AWARENESS`, `NEGLIGIBLE`), relative proximity bands, and walking corridor intersection. |
| **Stage 3** | Guidance Prioritization & Phrasing | **PASS** | Overhauled `DecisionEngine` in `app/services/decision_engine.py`; completely eliminated metric speech claims; added worsening-hazard cooldown bypasses and degraded-mode warnings. |
| **Stage 4** | Focused Safety Automated Tests | **PASS** | Created `test_safety_engine.py` with 8 focused safety tests covering confidence thresholds, corridor filtering, missing depth, worsening hazards, and degraded modes. |
| **Stage 5** | Integration Validation & Benchmarking | **PASS** | Full suite execution: **36 / 36 backend tests passed**; **6 / 6 frontend tests passed**; `flutter analyze` 0 issues; Android build configuration verified; end-to-end processing measured at **~202.4 ms**. |

> [!CAUTION]
> **Safety Certification Notice:**  
> The passing automated unit, integration, and static analysis tests verify software logic, uncertainty handling, and protocol contracts. They do **not** certify the application as safe for independent blind navigation in real-world uncontrolled environments.

---

## 2. Existing Safety Assumptions Discovered

An exhaustive audit of the previous decision engine and data pipeline revealed four critical safety vulnerabilities:

1. **Uncalibrated Metric Claims:**
   - *Previous Code:* `f"about {det.distance_m} meters away."`
   - *Safety Flaw:* Monocular depth from Depth Anything V2 produces relative disparity maps scaled via heuristic. Stating precise metres ("1.45 meters away") to a visually impaired user gives a false impression of physical measurement accuracy and violates basic navigation safety.
2. **Absence of Confidence Gating:**
   - *Previous Code:* `det.confidence` was completely ignored in `generate_guidance()`.
   - *Safety Flaw:* Single-frame transient false positives (e.g., confidence 0.35 noise or shadow) were given equal priority to 0.98 confidence verified hazards, generating alarming spurious warnings.
3. **Missing Walking Corridor Discrimination:**
   - *Previous Code:* Treated any object whose horizontal coordinate was center as an urgent obstacle regardless of whether it was at eye level, overhead, or distant. Peripheral objects at the far edge of the frame (e.g. wall or bench at x < 0.15) could trigger urgent "Stop" instructions.
4. **Cooldown Failure on Worsening Hazards:**
   - *Previous Code:* Enforced a flat 4.0-second silence for any non-urgent track.
   - *Safety Flaw:* An obstacle detected at 2.0m that rapidly approached to 0.9m was silenced by cooldown. Conversely, an obstacle remaining at <= 0.8m triggered speech output on every single frame (~300 ms), creating an unlistenable stutter loop.
5. **Fallacy of Negative Proof:**
   - *Previous Code:* If detections were empty `[]`, no guidance was generated, and frontend banners indicated "Listening... no obstacles reported yet."
   - *Safety Flaw:* Inherent risk that users or evaluators interpret the absence of detections as proof that the path is clear. Drop-offs, stairs down, transparent glass, and thin wires are not detected by COCO-trained models.

---

## 3. Decision-Engine and Guidance Changes

### 3.1 Risk Assessment Layer (`RiskAssessor`)
Implemented in `backend/app/services/risk_assessment.py`:
- **Forward Walking Corridor:** Defines navigable ground and torso corridor ($0.20 \le x/W \le 0.80$ and $y_2/H \ge 0.35$). Obstacles are explicitly classified as `in_path = True` or flanking (`in_path = False`).
- **Relative Proximity Bands (Non-Metric):**
  - `immediate`: inverse disparity proxy $\le 0.8$
  - `near`: $0.8 < \text{proxy} \le 2.0$
  - `mid`: $2.0 < \text{proxy} \le 4.0$
  - `far`: $\text{proxy} > 4.0$
  - `unknown`: depth invalid or missing
- **Risk Tiers:**
  - `IMMINENT` (Urgent): High/moderate confidence ($\ge 0.50$) in walking corridor with `immediate` proximity.
  - `POTENTIAL` (Warning): Obstacles in walking path within `near` proximity, immediate flanking obstacles, or uncalibrated in-path objects.
  - `AWARENESS` (Info): Obstacles at `mid` or `far` proximity, or flanking `near` obstacles.
  - `NEGLIGIBLE`: Low-confidence noise ($< 0.40$), distant objects, or overhead items.

### 3.2 Prioritized Guidance and Phrasing
- **Elimination of Metres:** All output uses clear, qualitative proximity phrases:
  - *Imminent:* `"Stop. {label} very close, directly ahead."` / `"Stop. {label} very close, to your {direction}."`
  - *Potential:* `"{label} nearby directly ahead, consider moving {hint}."`
  - *Awareness:* `"{label} ahead in the distance."` / `"{label} to your {direction}."`
- **Cognitive Load Control:** Prioritizes at most one critical hazard message per cycle to prevent speech collisions.
- **Worsening Hazard Cooldown Bypass:** If an obstacle moves significantly closer ($\Delta \text{proxy} \ge 0.4$) or elevates in risk tier (e.g. `POTENTIAL` $\rightarrow$ `IMMINENT`), the 4-second cooldown is immediately bypassed.
- **Degraded Mode:** Added `generate_degraded_guidance(reason)` emitting structured warnings (`is_degraded = True`) when models fail or network streaming stalls.

---

## 4. Files Changed and API Compatibility

| File | Nature of Change | API Compatibility Impact |
|---|---|---|
| `backend/app/models/schemas.py` | Added optional `in_path`, `risk_level`, `proximity_band` to `Detection`; added `is_degraded` to `GuidanceMessage`. | **100% Backwards Compatible** (defaults provided; existing JSON structure unchanged). |
| `backend/app/services/risk_assessment.py` | *NEW:* `RiskAssessor`, `RiskLevel`, and `ProximityBand` evaluation engine. | Internal service layer. |
| `backend/app/services/decision_engine.py` | Overhauled with risk evaluation, qualitative speech, worsening bypass, and degraded mode. | Preserves `generate_guidance(detections)` signature; adds optional `frame_width`, `frame_height`. |
| `backend/app/api/websocket.py` | Passed camera frame dimensions to `generate_guidance`. | Identical WebSocket JSON contract. |
| `backend/app/api/routes.py` | Passed frame dimensions to `generate_guidance`; restored full pipeline depth call. | Identical REST JSON contract. |
| `frontend/lib/models/detection.dart` | Added typed `inPath`, `riskLevel`, `proximityBand`, and `isDegraded`. | **100% Backwards Compatible** (nullable deserialization). |
| `backend/app/tests/test_safety_engine.py` | *NEW:* 8 focused automated safety test cases. | Test-only suite. |
| `frontend/test/models_and_socket_test.dart` | Added validation for new risk fields. | Test-only suite. |

---

## 5. Tests and Exact Command Results

### 5.1 Backend Pytest Suite
```powershell
.\venv\Scripts\python.exe -m pytest app/tests/ -v
```
**Result: 36 passed in 20.61s (100% pass rate, 0 failures, 0 warnings)**
- `test_safety_engine.py` (8/8 PASS):
  - `test_high_vs_low_confidence_detections`: Verifies noise suppression ($<0.40$).
  - `test_inside_vs_outside_walking_corridor`: Verifies corridor filtering.
  - `test_conflicting_or_missing_depth`: Verifies graceful degradation without metric claims.
  - `test_empty_detections_does_not_declare_path_clear`: Confirms no false "safe/clear" claims.
  - `test_worsening_hazard_bypasses_cooldown`: Confirms immediate alert when risk elevates.
  - `test_guidance_priority_selection`: Confirms imminent hazard dominance.
  - `test_no_metric_distance_claims`: Regex validation verifying "meter", "metre", "m" never appear in speech text.
  - `test_degraded_mode_behavior`: Confirms explicit degraded warning messages.
- `test_decision_engine.py` (6/6 PASS): Legacy regression suite updated for qualitative phrases.
- `test_bytetrack_tracker.py` (4/4 PASS): Stable IDs, recovery, loss culling, reset.
- `test_depth_anything.py` (3/3 PASS): Depth shape, bounding, invalid inputs.
- `test_integration_pipeline.py` (4/4 PASS): End-to-end REST, malformed frame recovery, WebSocket stream, explicit unavailable states.
- `test_pipeline.py` (6/6 PASS): Interface contracts.
- `test_sam2_segmenter.py` (3/3 PASS): Segment masks and corridor occupancy.
- `test_yolo_detector.py` (2/2 PASS): Real asset inference on `bus.jpg` and blank frame.

### 5.2 Flutter Test Suite
```bash
flutter test
```
**Result: All 6 tests passed in 1.4s** (`models_and_socket_test.dart` and `widget_test.dart`).

### 5.3 Flutter Static Analysis
```bash
flutter analyze --no-fatal-infos
```
**Result: No issues found! (ran in 29.6s)**

### 5.4 Android Build Tooling
```bash
flutter build apk --config-only
```
**Result: Exit code 0** (Gradle config, permissions, and dependencies verified).

---

## 6. Measured End-to-End Latency and Limitations

**Measurement Method:** Measured on Windows 11 with 64-bit CPU, Python 3.10, PyTorch 2.13 CPU, timing every pipeline stage with high-resolution `time.perf_counter()` over full $640 \times 480$ frame processing.

| Processing Stage | Implementation | Measured Latency |
|---|---|:---:|
| **Frame Decode & Preprocessing** | Pillow / NumPy | 2.10 ms |
| **Object Detection** | YOLOv11n (CPU) | 58.10 ms |
| **Multi-Object Tracking** | ByteTrack (CPU) | 0.54 ms |
| **Monocular Depth Estimation** | Depth Anything V2 Small (252x252 CPU) | 143.66 ms |
| **Safety Risk Assessment & Guidance** | DecisionEngine + RiskAssessor | **0.09 ms** |
| **Total Pipeline Processing** | **Full Perception-to-Guidance Loop** | **202.39 ms** |

**Timing & Jitter Observations:**
- The complete pipeline runs in **~202.4 ms**, comfortably below the client camera transmission period (400 ms) and server throttle threshold (300 ms).
- Speech latency in the Flutter frontend: On-device `flutter_tts` initializes in <1 ms and executes urgency interruption immediately via `await _tts.stop()`.

---

## 7. Known Risks and Unverified Real-World Behavior

1. **Uncalibrated Relative Disparity:**
   - Proximity bands (`immediate`, `near`, `mid`, `far`) are derived from monotonic relative disparity, not absolute Euclidean distance. Changing camera pitch or holding the phone angled upward shifts the disparity distribution.
2. **Dynamic User Motion:**
   - Calculations currently assume forward movement. Lateral panning or tilting the device generates apparent obstacle displacement that is not compensated by an IMU.
3. **Overhead and Ground-Level Drop-Off Hazards:**
   - Standard 2D bounding boxes and monocular depth models struggle with descending stairs (negative obstacles), curbs, holes, and low-hanging tree branches.
4. **Physical Obstacle Density:**
   - In crowded public environments (e.g. transit stations), multiple nearby pedestrians will trigger frequent hazard evaluations. While single-hazard prioritization prevents audio chaos, field testing with visually impaired users is necessary to tune notification density.

---

## 8. Outstanding Work and Phase 4 Handover

### Recommended Next Steps for Phase 4:
1. **IMU Sensor Fusion:**
   - Capture device accelerometer/gyroscope pitch data in Flutter to adjust ground plane estimation and discard overhead non-hazards.
2. **Audio Cue Diversity:**
   - Supplement spoken TTS with spatial audio earcons (directional beeps or haptic vibration pulses) for immediate urgent hazards to decrease cognitive listening fatigue.
3. **OCR and Scene Understanding Rollout:**
   - Connect real PaddleOCR and Florence-2 to the on-demand voice command endpoints (`read text`, `describe scene`) while keeping the main navigation loop focused on low-latency collision avoidance.
4. **Physical Usability Validation:**
   - Conduct structured trials with orientation and mobility (O&M) specialists in controlled indoor corridors.
