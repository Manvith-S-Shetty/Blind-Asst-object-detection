# Blind Assistant AI — Complete Project Audit (Phase 1)

**Date:** November 2026  
**Auditor:** Senior Software Architect, AI/ML & Android Systems Engineer  
**Workspace:** `C:\Blind-Asst-object-detection`  
**Flutter Frontend:** `C:\Blind-Asst-object-detection\frontend`  
**Baseline Verification Status:**
- Dart Analyzer (`dart analyze frontend`): **0 issues found**
- Automated Tests (`flutter test`): **107 passing tests / 0 failing**
- Target Platform: Android (minSdk 21+, targetSdk 34+, Java 11 / Kotlin 1.9+)

---

## 1. Executive Architecture Overview

The **Blind Assistant AI** application provides voice-first, accessible assistive obstacle perception, directional guidance, and geographical point-of-interest discovery for blind and low-vision users.

The core architecture follows a strict **Offline-First / On-Device Primary** design:
1. **Perception & Local Guidance (100% On-Device & Offline):**
   - **Model:** `yolo11n_float16.tflite` (5.4 MB, FP16 quantization) running in `LocalDetector` via `tflite_flutter: ^0.12.1`.
   - **Tensors:** Input `[1, 640, 640, 3]` (RGB normalized to `[0.0, 1.0]`), Output `[1, 84, 8400]` (4 box coordinates + 80 COCO classes).
   - **Preprocessing:** Correct letterboxing with aspect-ratio preservation, stride-based pixel normalization, and off-thread UI execution via `IsolateInterpreter`.
   - **Postprocessing:** Per-class greedy Non-Maximum Suppression (IoU 0.45) followed by Cross-Class duplicate suppression (IoU 0.65) to eliminate classification jitter (e.g., chair vs couch).
   - **Distance Estimation:** [MonocularDistanceEstimator](file:///c:/Blind-Asst-object-detection/frontend/lib/services/distance_estimator.dart) using a calibrated pinhole camera projection model ($D = \frac{f_y \cdot H_{\text{real}}}{h_{\text{bbox}}}$) with physical height priors and strict uncertainty rejection (rejects truncated boxes, abnormal aspect ratios, uncalibrated classes, and distances outside 0.5m–6.0m).
   - **Guidance & Prioritization:** [LocalGuidanceEngine](file:///c:/Blind-Asst-object-detection/frontend/lib/services/local_guidance_engine.dart) tracking obstacles across frames with IoU matching, Exponential Moving Average (EMA) distance smoothing, direction hysteresis, and 6 priority tiers. Returns at most one single concise instruction per frame cycle.
   - **Speech Serialization:** [TtsService](file:///c:/Blind-Asst-object-detection/frontend/lib/services/tts_service.dart) enforcing a single-threaded FIFO speech queue, urgent hazard preemption, pending guidance coalescing, stale job purging (>3.5s), and a 6.0s watchdog recovery.
2. **Geographical Nearby Places (OpenStreetMap Overpass API):**
   - Free, open-source POI search via Overpass API without paid Google Places APIs, credentials, or billing accounts.
   - On-demand GPS acquisition via `geolocator: ^14.1.2`.
   - In-memory cache with 5-minute TTL and 2-second rate-limiting cooldown to comply with Overpass Fair Use Policy.
   - Interactive map and list view via `flutter_map: ^8.3.2` with required OpenStreetMap attribution.
3. **Optional FastAPI Backend:**
   - Used purely for developer telemetry, mDNS LAN discovery, and optional cloud multimodal tasks (BLIP scene captioning, RapidOCR text reading, YOLO-World open-vocabulary search).
   - Core offline navigation never blocks on backend availability.

---

## 2. Detailed Subsystem Audit

### 2.1 Object Detection (`LocalDetector`)
- **Strengths:**
  - Loads FP16 quantized model directly from Flutter assets without decompressing or modifying files.
  - Memory-safe YUV420 to RGB conversion with stride handling for Android Camera2 frames.
  - Greedy NMS and cross-class suppression prevent bounding box flicker.
  - Bounding box scaling correctly reverses letterbox transformation padding (`dw`, `dh`) and scaling ratio.
- **Identified Improvements Needed:**
  - Expand relevant obstacle class mapping to ensure all supported physical priors are seamlessly linked.
  - Explicitly document uncalibrated/unsupported obstacle types (doors, stairs, curbs, drop-offs) in all user-facing disclaimers.

### 2.2 Navigation Guidance (`LocalGuidanceEngine`)
- **Strengths:**
  - Rigorous safety rule: When 0 obstacles are detected, the engine emits `[]` and **never** announces that the path is "safe" or "clear".
  - Directional partitioning: Left ($X < 0.33W$), Center ($0.33W \le X \le 0.67W$), Right ($X > 0.67W$), and Central Path Corridor overlap ($X_1 < 0.65W$ and $X_2 > 0.35W$).
  - Proximity reannouncement: If an obstacle approaches by $\ge 0.5\text{m}$, it immediately bypasses the 5-second cooldown.
- **Identified Improvements Needed:**
  - Fine-tune direction hysteresis to prevent boundary flutter when an obstacle moves along the $0.33W$ or $0.67W$ boundary line.

### 2.3 Audio & Voice System (`TtsService` & `VoiceCommandButton`)
- **Strengths:**
  - Single coordinated speech queue prevents overlapping speech.
  - Urgent warnings immediately stop active routine speech and flush non-urgent items from queue.
  - Microphone permission requested strictly on-demand when voice button is pressed.
  - Android 11+ `<queries>` intents for `android.intent.action.TTS_SERVICE` and `android.speech.RecognitionService` declared in `AndroidManifest.xml`.
- **Identified Gaps:**
  - `PlaceIntentParser` and `PlacesController` support "Next" commands (`announceNextPlace`), but currently lack explicit handling for "Repeat" / "Say again" / "Repeat result" commands as requested in the Master Engineering Prompt.
  - Voice command grammar needs extension for additional nearby place categories: Railway stations, Petrol stations, and Clinics.

### 2.4 Location & GPS (`LocationService`)
- **Strengths:**
  - Wraps `GeolocatorPlatform` cleanly for comprehensive testability with mocks.
  - Distinguishes service disabled, permission denied, permission denied forever, and GPS timeouts.
  - Gracefully falls back to `getLastKnownPosition` when GPS acquisition times out.
  - Strict privacy: Location is accessed only on-demand during nearby search and does not run continuous background tracking.
- **Identified Improvements Needed:**
  - Ensure location status banners in `PlacesScreen` offer direct actionable buttons to enable GPS or open app settings.

### 2.5 Nearby Places Search (`PlacesClient` & `PlaceIntentParser`)
- **Strengths:**
  - 100% Free & Open-Source: queries Overpass API interpreter directly.
  - In-memory caching with grid-based key rounding (~110m) to minimize network dispatches.
  - Calculates straight-line great-circle distance and 8-point cardinal bearing ("north", "southwest", etc.).
  - Filters and deduplicates places by ID, coordinate proximity, and name.
- **Identified Gaps (To Implement in Phase 6 & 7):**
  - Category taxonomy currently covers: Restaurant, Hospital, Pharmacy, Bus Stop, Shop, Cafe, Grocery, Bank.
  - Missing categories from Master Prompt: **Railway stations** (`railway=station`), **Petrol/Gas stations** (`amenity=fuel`), and dedicated **Clinics** (`amenity=clinic`).
  - Need dedicated query builder for these categories in `PlacesClient`.

### 2.6 Map & Nearby Interface (`PlacesScreen`)
- **Strengths:**
  - Interactive `flutter_map` widget rendering OpenStreetMap tiles (`https://tile.openstreetmap.org/{z}/{x}/{y}.png`).
  - Required OpenStreetMap attribution (`RichAttributionWidget`) prominently displayed.
  - User location pin and indexed place markers with selection sync between map and list.
  - High-contrast dark styling, accessible list view, and floating action button for "Next Place".
- **Identified Gaps (To Implement in Phase 8 & 9):**
  - Add quick filters for Railway Stations and Petrol Stations in category chips.
  - Add optional walking route preview using free OSRM Foot Routing service (`https://router.project-osrm.org`) with prominent disclaimers and failure fallbacks.

### 2.7 Android Build & Native Configuration
- **Strengths:**
  - `minSdkVersion = 21`, `targetSdkVersion = 34`.
  - Android Gradle Plugin / Kotlin configuration unified on Java 11 / JVM 11 target.
  - AAPT option `noCompress("tflite")` ensures the model can be memory-mapped directly from APK assets.
  - Android permissions declared: Camera, Record Audio, Internet, Network State, Wi-Fi Multicast, Fine Location, Coarse Location.

---

## 3. Risks & Architectural Boundaries

| Risk / Constraint | Severity | Mitigation Strategy |
|---|:---:|---|
| **Zero Hardware Depth Sensing** | High | Mobile cameras cannot deliver ToF depth. Monocular estimator must strictly output `null` (unknown) when geometry is uncertain. Never fabricate numbers. |
| **Unsupported Obstacle Classes** | High | YOLO COCO-80 baseline cannot detect drop-offs, stairs, curbs, or doors. App must display prominent disclaimers and never claim a path is clear. |
| **Overpass API Rate Limits** | Medium | Client-side 5-minute caching, 2-second rate-limiting, bounded search radius (1000m), and friendly User-Agent. |
| **Speech Overlap / Collisions** | High | Single serialized `TtsService` queue with urgent preemption; all features (navigation, voice, places) route through this single queue. |
| **OSRM Route Limitations** | Medium | OSRM public demo server is strictly optional. Must be explicitly labeled as straight-line / experimental estimate and must never replace obstacle detection. |

---

## 4. Audit Conclusion & Next Actions

The codebase is exceptionally well-structured, modular, and in a clean state (0 analyzer issues, 107 passing tests). We will proceed directly to execute Phase 2 through Phase 15 per the Master Engineering Prompt.

