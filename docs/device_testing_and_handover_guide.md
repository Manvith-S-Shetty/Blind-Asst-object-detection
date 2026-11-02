# Blind Assistant AI — Device Testing, Verification & Handover Guide

**Project:** Voice-First Blind Assistant AI (On-Device YOLO Navigation & Calibrated Monocular Guidance)  
**Date:** October 2026  
**Status:** Verification Complete (Analysis: PASS; Automated Tests: 82/82 PASS; APK Build: PASS)

---

## 1. Executive Summary & Architecture

The **Blind Assistant AI** application delivers voice-first, accessible obstacle perception and directional guidance for blind and low-vision users. It operates on a strict **offline-first** architecture:

- **Core Offline Navigation:** Executes 100% on-device on the user's Android phone using:
  - [LocalDetector](file:///c:/Blind-Asst-object-detection/frontend/lib/services/local_detector.dart) running an optimized TensorFlow Lite model (`yolo11n_float16.tflite`) with Non-Maximum Suppression (NMS) and cross-class suppression.
  - [MonocularDistanceEstimator](file:///c:/Blind-Asst-object-detection/frontend/lib/services/distance_estimator.dart) providing calibrated distance estimation with rigorous uncertainty gating.
  - [LocalGuidanceEngine](file:///c:/Blind-Asst-object-detection/frontend/lib/services/local_guidance_engine.dart) tracking obstacles across frames, reducing flicker, ordering hazards by priority, and formulating natural instructions.
  - [TtsService](file:///c:/Blind-Asst-object-detection/frontend/lib/services/tts_service.dart) guaranteeing single active speech serialization, urgent warning preemption, frame guidance coalescing, deduplication, and deadlock-free queue watchdog recovery.
- **Optional FastAPI Server:** Used strictly for optional developer telemetry, mDNS LAN discovery, and multimodal cloud features (BLIP scene captioning, RapidOCR text reading, and YOLO-World open-vocabulary search). Core navigation does **NOT** require the server.

> [!CAUTION]
> **CRITICAL MOBILITY AID DISCLAIMER:**  
> This application is an experimental assistive research prototype. **It is NOT certified as safe for use as a sole mobility aid or primary navigation tool.** It must NEVER replace a primary mobility aid such as a white cane, guide dog, or attentive human companion. Obstacle detection is probabilistic and monocular; drop-offs, transparent glass, or fast-moving hazards may not be detected in time.

---

## 2. Technical Deep-Dive: Implemented Features

### 2.1 Depth Sensing Investigation & Calibrated Monocular Distance
- **Mobile Camera Pipeline Investigation:**  
  Flutter's `camera: ^0.11.0+2` plugin accesses standard Android Camera2 / CameraX preview streams configured with `ImageFormatGroup.yuv420`. The Camera2 API only exposes depth streams (`ImageFormat.DEPTH16` or `DEPTH_POINT_CLOUD`) on rare devices equipped with specialized Time-of-Flight (ToF) hardware, which Flutter's camera stream API does not support. Hardware depth sensing is therefore **unsupported** by the mobile camera pipeline.
- **Calibrated Geometric Model:**  
  Implemented [MonocularDistanceEstimator](file:///c:/Blind-Asst-object-detection/frontend/lib/services/distance_estimator.dart) using a pinhole camera projection model:
  $$\text{Distance} = \frac{f_y \times H_{\text{real}}}{h_{\text{bbox\_px}}}$$
  Where:
  - $f_y = \frac{H_{\text{image}}}{2 \times \tan(\text{VFOV} / 2)} \approx 0.96 \times H_{\text{image}}$ for typical smartphone cameras in portrait orientation ($\text{VFOV} \approx 55^\circ$).
  - $H_{\text{real}}$: Calibrated physical height priors for predictable objects: `person` (1.70m), `chair` (0.85m), `couch` (0.85m), `car` (1.50m), `bicycle` (1.00m), `motorcycle` (1.15m), `bus` (3.20m), `truck` (3.00m), `dining table` (0.75m), `toilet` (0.75m), `bed` (0.65m), `dog` (0.60m).
- **Uncertainty & Rejection Criteria:**  
  The estimator never invents a number. It outputs `distanceMeters = null` (represented visually as `dist: unk`) when:
  1. Class is uncalibrated or has high height variance (`backpack`, `umbrella`, `handbag`, `book`, `potted plant`, etc.).
  2. Bounding box touches top or bottom frame edges ($y_1 \le 4\text{px}$ or $y_2 \ge H - 4\text{px}$) where truncation would severely overestimate distance.
  3. Aspect ratio is anomalous (e.g. seated or crouching person with $h/w < 1.0$).
  4. Calculated distance is outside the reliable optical range ($< 0.5\text{m}$ or $> 6.0\text{m}$).
  5. Box height is below 15 pixels.

### 2.2 Direction Classification & Obstacle Prioritization
- **Direction Partitioning:**
  - `Left`: Object center $X < 0.33 \times W_{\text{image}}$.
  - `Center`: Object center $0.33 \times W_{\text{image}} \le X \le 0.67 \times W_{\text{image}}$.
  - `Right`: Object center $X > 0.67 \times W_{\text{image}}$.
  - `inPath`: Center direction OR bounding box overlap with central forward path ($x_1 < 0.65W$ and $x_2 > 0.35W$).
- **Multi-Factor Priority Ordering:**
  - Rank 0: Immediate forward path hazard ($\le 1.5\text{m}$ or `imminent` in path).
  - Rank 1: Immediate flank hazard ($\le 1.5\text{m}$ on sides).
  - Rank 2: Potential forward path hazard ($1.5 - 2.5\text{m}$ in path).
  - Rank 3: Potential flank hazard ($1.5 - 2.5\text{m}$ on sides).
  - Rank 4: Forward awareness ($> 2.5\text{m}$ in path).
  - Rank 5: Flank awareness ($> 2.5\text{m}$ on sides).
  - Tie-breakers: Closer estimated distance $\to$ higher temporal persistence (`consecutiveFrames`) $\to$ higher confidence.
- **Natural Spoken Guidance:**
  - Valid distance: *"Obstacle ahead, approximately 1.5 meters. Stop."*, *"Person on your left, approximately 2.0 meters."*
  - Unknown distance: *"Stop. Chair directly ahead."*, *"Person on your left."*, *"Possible obstacle on your right. Proceed cautiously."*
  - Approaching triggers: Distance reduction $\ge 0.5\text{m}$ bypasses cooldown and reannounces immediately.
  - Safety rule: Never speaks words like "safe" or "path clear" when 0 obstacles are detected.

### 2.3 Serialized Speech Queue & Anti-Overlap Architecture
Refactored [TtsService](file:///c:/Blind-Asst-object-detection/frontend/lib/services/tts_service.dart) to eliminate speech collisions:
- **Strict FIFO Serialized Queue:** At most one active utterance at any moment; ordinary queued messages play sequentially once active speech completes.
- **Urgent Hazard Preemption:** Urgent warnings (`Urgency.urgent`) immediately call `_tts.stop()`, flush non-urgent queued items, and speak the urgent warning without delay.
- **Urgent Protection:** Routine status updates, voice queries, or info guidance cannot interrupt an active urgent hazard warning unless explicitly commanded by user action (`interrupt: true`).
- **Guidance Coalescing:** When frequent frame updates arrive while an utterance is playing, new guidance replaces any pending guidance in the queue rather than building an obsolete backlog.
- **Stale Guidance Removal:** Guidance waiting $> 3.5$ seconds in the queue is automatically discarded.
- **Deadlock-Free Watchdog:** A 6.0-second safety watchdog automatically advances the queue if the native Android TTS engine drops completion callbacks.
- **Call-Site Audit:** Verified all call sites in `navigation_controller.dart` and `voice_command_button.dart` route through `TtsService`.

### 2.4 Safety & Dark User Interface
- **Dark Theme:** High-contrast dark styling (`Colors.black`, high-contrast text) preserved.
- **Clear STOP Hazard Banner:** High-contrast red banner (`_StopHazardWarningBanner`) appears with a stop hand icon when an imminent forward obstacle is detected.
- **Enhanced Overlay Painter:** Bounding boxes are color-coded by risk (Red = Imminent, Amber = Potential, Green = Awareness). The label badge displays: `[LABEL] [CONF%] [DIRECTION] ~X.Xm (est)` or `[dist: unk]`, explicitly distinguishing estimated from measured distance.
- **Prominent Footnote:** Constant disclaimer: *"Perception assistance aid only. Does not guarantee collision avoidance."*

---

## 3. Installation and Deployment Commands

### 3.1 Verification Commands
From `c:\Blind-Asst-object-detection\frontend`:

```powershell
# 1. Static Analysis (Zero issues required)
flutter analyze

# 2. Automated Test Suite (All 82 tests)
flutter test

# 3. Build Debug APK
flutter build apk --debug
```

### 3.2 Installing to Your Connected Phone
1. Connect your Android phone via USB and enable **USB Debugging** in Developer Options.
2. Verify connection:
   ```powershell
   & "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" devices
   ```
3. Install the APK directly:
   ```powershell
   & "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" install -r "c:\Blind-Asst-object-detection\frontend\build\app\outputs\flutter-apk\app-debug.apk"
   ```
4. Or run directly with hot-reload:
   ```powershell
   flutter run -d <your_device_id>
   ```

---

## 4. Manual Physical-Device Testing Protocol

Execute the following manual tests on your Android phone to verify hardware behavior:

| Step | Test Objective | Procedure | Expected Phone Behavior | Verification |
|:---:|---|---|---|:---:|
| **1** | **Cold Launch & Offline State** | Launch app with Wi-Fi and Mobile Data disabled. | Dark UI appears. Teal status banner shows *"On-Device AI ready (Offline mode)"*. No backend errors. | [ ] |
| **2** | **Permission Denial Recovery** | Fresh install or revoke camera. Tap Start button. Deny permission once. | TTS speaks: *"Camera permission is required to detect obstacles. Please grant camera permission."* Preview shows accessible grant card. | [ ] |
| **3** | **Permanent Denial Deep-Link** | Deny permission permanently ("Don't ask again"). | TTS explains settings requirement. Tap **"Open App Settings"**; device settings screen opens directly. Grant camera access and return. | [ ] |
| **4** | **Live Offline Detection** | Tap Start Navigation button. | TTS announces: *"Navigation started. On-device detection active."* Live camera preview streams smoothly. | [ ] |
| **5** | **Calibrated Distance Display** | Point camera at a person or chair ~1.5m away. | Red/amber bounding box appears. Label displays `~1.5m (est)`. TTS announces: *"Obstacle ahead, approximately 1.5 meters. Stop."* | [ ] |
| **6** | **Distance Uncertainty Gating** | Point camera so the object touches the top or bottom frame edge (truncated). | Distance changes to `[dist: unk]`. TTS does NOT invent numeric meters; speaks: *"Stop. [Label] directly ahead."* | [ ] |
| **7** | **Direction Partitioning** | Pan camera so obstacle shifts to the left, center, and right. | Bounding box label reflects `[left]`, `[center]`, and `[right]`. Directional audio warns accordingly (*"Person on your left."*). | [ ] |
| **8** | **Speech Non-Overlap & Coalescing** | Pan quickly across multiple objects. | Speech NEVER overlaps. Only one voice output plays at a time. Intermediate frame updates coalesce into the newest hazard. | [ ] |
| **9** | **Urgent Hazard Preemption** | While routine speech is playing, suddenly bring a large chair close into the forward path. | Routine speech is immediately cut off; TTS announces: *"Stop. Obstacle ahead..."* and red STOP banner appears. | [ ] |
| **10** | **Approaching Hazard Reannouncement** | Walk toward an obstacle from 3 meters to 1.5 meters. | As distance drops $\ge 0.5\text{m}$, TTS reannounces the approaching hazard before the 5.0s cooldown expires. | [ ] |
| **11** | **Lifecycle Pause & Resume** | Press Home button or lock screen for 10 seconds. Return to app. | Camera releases safely (no overheating/battery drain). Navigation resumes cleanly without frozen preview or crashes. | [ ] |
| **12** | **Stop Navigation** | Tap Stop button. | TTS confirms *"Navigation stopped."* Camera releases immediately. | [ ] |

---

## 5. Summary of Changed & Added Files

| File | Type | Changes & Responsibility |
|---|:---:|---|
| [distance_estimator.dart](file:///c:/Blind-Asst-object-detection/frontend/lib/services/distance_estimator.dart) | **New** | Calibrated monocular distance estimator with pinhole projection, size priors, and uncertainty rejection. |
| [local_detector.dart](file:///c:/Blind-Asst-object-detection/frontend/lib/services/local_detector.dart) | **Modified** | Integrated `MonocularDistanceEstimator`, directional thresholds (`0.33W`, `0.67W`), path corridor overlap, and distance assignment. |
| [local_guidance_engine.dart](file:///c:/Blind-Asst-object-detection/frontend/lib/services/local_guidance_engine.dart) | **Modified** | Tracked obstacle distance smoothing (EMA), priority rank sorting, approach detection ($\ge 0.5\text{m}$), and natural concise speech formulation. |
| [tts_service.dart](file:///c:/Blind-Asst-object-detection/frontend/lib/services/tts_service.dart) | **Modified** | Serialized single-speech queue, urgent preemption, routine message coalescing, stale guidance purge, deduplication, and watchdog timeout recovery. |
| [navigation_screen.dart](file:///c:/Blind-Asst-object-detection/frontend/lib/features/navigation/navigation_screen.dart) | **Modified** | High-contrast `_StopHazardWarningBanner`, risk-colored bounding boxes, label badge with `~X.Xm (est)` vs `dist: unk`, and safety disclaimer. |
| [distance_and_priority_test.dart](file:///c:/Blind-Asst-object-detection/frontend/test/distance_and_priority_test.dart) | **New** | 18 unit tests for distance calibration, uncertainty bounds, left/center/right partitioning, priority ordering, and TTS queue. |
| [local_guidance_and_navigation_test.dart](file:///c:/Blind-Asst-object-detection/frontend/test/local_guidance_and_navigation_test.dart) | **Modified** | Updated TTS queue serialization tests to assert sequential advancement and preemption. |
