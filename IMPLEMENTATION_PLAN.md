# Blind Assistant AI — Master Implementation Plan

**Project:** Blind Assistant (On-Device YOLO Navigation & Calibrated Monocular Guidance)  
**Target Platform:** Flutter Android (Android 11+, API 21–34)  
**Date:** November 2026  
**Status:** In Progress — Phase 1 Complete

---

## Architecture Principles
1. **100% Free & Open-Source:** Zero paid APIs, zero subscriptions, zero mandatory credit card accounts.
2. **Offline-First:** Core YOLO obstacle perception and spoken navigation run 100% on-device on the phone without needing any server or internet connectivity.
3. **Calibrated Geometry:** Monocular distance estimation with strict uncertainty gating. If geometry is uncertain, the distance is explicitly unknown; numbers are never guessed.
4. **Single Coordinated Speech Queue:** All spoken guidance, voice query answers, and places announcements flow through a single serialized queue with urgent hazard preemption.
5. **Clear Assistive Boundaries:** The app is an assistive research aid and must never claim a path is clear, safe, or replace a white cane or guide dog.

---

## Detailed Implementation Plan (Phases 1–15)

### Phase 1 — Project Audit & Documentation
- [x] Inspect existing project structure, code, tests, and configuration.
- [x] Verify analyzer status (`dart analyze frontend`: 0 issues).
- [x] Verify automated test suite (`flutter test`: 107 tests passing).
- [x] Create `PROJECT_AUDIT.md`.
- [x] Create `IMPLEMENTATION_PLAN.md`.
- [x] Create `FEATURE_COMPLETION_CHECKLIST.md`.

### Phase 2 — Core Object Detection Improvement
- [x] Preserve existing FP16 YOLOv11n TFLite model (`assets/models/yolo11n_float16.tflite`).
- [x] Verify tensor shapes: `[1, 640, 640, 3]` input, `[1, 84, 8400]` output.
- [x] Maintain RGB normalization (`/ 255.0`) and letterbox transformation.
- [x] Verify greedy Non-Maximum Suppression (IoU 0.45) and cross-class duplicate suppression (IoU 0.65).
- [x] Confirm off-thread inference via `IsolateInterpreter` with fallback to main interpreter.
- [ ] Ensure all relevant obstacle classes from COCO taxonomy are properly mapped.
- [ ] Re-verify that unsupported classes (stairs, doors, drop-offs, curbs) are never claimed as detectable.

### Phase 3 — Navigation & Distance Guidance
- [x] Left, center, and right directional classification ($0.33W$ and $0.67W$ thresholds).
- [x] Forward path corridor overlap checking ($X_1 < 0.65W$ and $X_2 > 0.35W$).
- [x] Monocular distance estimation using pinhole projection ($D = \frac{f_y \cdot H_{\text{real}}}{h_{\text{bbox}}}$).
- [x] Bounded size priors and uncertainty gating (border truncation, aspect ratio, min/max range).
- [x] Multi-factor obstacle prioritization (6 priority ranks).
- [x] Approach trigger ($\ge 0.5\text{m}$ distance reduction reannounces immediately).
- [x] Direction hysteresis buffers to prevent oscillation on border boundaries.
- [x] Strict safety rule: When 0 obstacles are detected, never announce that the path is "safe" or "clear".

### Phase 4 — Voice System Architecture
- [x] Android TTS configuration with fallback handling and language initialization.
- [x] Single FIFO speech queue with urgent preemption in `TtsService`.
- [x] Coalescing of frequent guidance updates and automatic purging of stale guidance (>3.5s).
- [x] Deadlock watchdog timer (6.0s) ensuring native completion callbacks never hang the queue.
- [x] On-demand microphone permission request with spoken explanations upon denial.
- [ ] Add explicit support for "Repeat" / "Repeat result" / "Say again" voice commands.
- [ ] Verify speech recognition recovery when native speech engine stops listening.

### Phase 5 — GPS Location Service
- [x] Geolocator package configuration (`geolocator: ^14.1.2`).
- [x] Android location permissions (`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`).
- [x] On-demand GPS acquisition (only during nearby place search).
- [x] Check for enabled location hardware and permission states (denied, permanently denied).
- [x] Graceful fallback to `getLastKnownPosition` when GPS times out.
- [x] Decoupled from camera navigation so camera never blocks on GPS.

### Phase 6 — Nearby Place Search (OpenStreetMap Overpass API)
- [x] 100% Free OpenStreetMap Overpass client (`PlacesClient`).
- [x] In-memory caching with 5-minute TTL and 2-second rate-limiting cooldown.
- [x] Great-circle straight-line distance and cardinal direction calculation.
- [x] Duplicate detection removal by OSM ID, coordinates, and name.
- [ ] Expand supported categories to include:
  - **Railway Station** (`railway=station`, `station=subway`)
  - **Petrol Station** (`amenity=fuel`)
  - **Clinic / Healthcare** (`amenity=clinic`, `amenity=doctors`)
- [ ] Update Overpass query generator in `PlacesClient` for new categories.
- [ ] Update category taxonomy in `models/place.dart`.

### Phase 7 — Voice-Based Nearby Search Integration
- [x] Voice command parser (`PlaceIntentParser`) recognizing nearby queries.
- [x] Automatic navigation to `/places` screen with preselected category.
- [x] Spoken announcements for closest result and total results found.
- [x] Voice command for "Next Place" (`announceNextPlace()`).
- [ ] Voice command for "Repeat Place" (`repeatCurrentPlace()`).
- [ ] Expand parser dictionary for railway stations, petrol stations, and clinics.

### Phase 8 — Map & Nearby Results Interface
- [x] Accessible map interface using `flutter_map: ^8.3.2` with OpenStreetMap tile provider.
- [x] Prominent OpenStreetMap copyright attribution (`RichAttributionWidget`).
- [x] User location marker and numbered place pins.
- [x] Accessible scrollable list view with large touch targets and high contrast.
- [x] Tap to announce place details aloud via `TtsService`.
- [ ] Add category filter chips for Railway Stations and Petrol Stations.

### Phase 9 — Optional Directions & Routing (OSRM Free Walking Router)
- [ ] Implement `RoutingService` using free, public Open Source Routing Machine (OSRM) Foot API (`https://router.project-osrm.org/route/v1/foot/...`).
- [ ] Retrieve walking polyline coordinates, total walking distance (distinct from straight-line distance), and step-by-step maneuvers.
- [ ] Display walking route polyline on `flutter_map` when a place is selected.
- [ ] Strict Safety Invariants:
  - Prominently declare: "Experimental walking route from OSRM. Does NOT account for construction, steps, or real-time hazards. Never replace your white cane or guide dog."
  - Handle network failures gracefully without affecting nearby search or camera navigation.

### Phase 10 — Backend & Offline Architecture
- [x] Core YOLO detection and guidance remain 100% operational offline.
- [x] Backend connectivity managed via `BackendConnectionManager` with exponential backoff.
- [x] Clean status banner: "On-Device AI ready (Offline mode)" without intrusive error popups.
- [x] Clear indication when internet-dependent nearby search is offline.

### Phase 11 — Accessibility & Safety Verification
- [x] High-contrast dark styling (`AppTheme.dark`).
- [x] Semantics labels and live regions for screen readers (TalkBack).
- [x] High-contrast red STOP hazard banner for imminent in-path obstacles.
- [x] Persistent safety footnote: "Perception assistance aid only. Does not guarantee collision avoidance."

### Phase 12 — Automated Testing Expansion
- [x] Maintain 107 existing tests passing.
- [ ] Add unit tests for `repeatCurrentPlace` voice command.
- [ ] Add unit tests for new categories (Railway Station, Petrol Station, Clinic).
- [ ] Add unit tests for `RoutingService` (OSRM response parsing, polyline decoding, failure fallback).
- [ ] Re-run full test suite and ensure 100% pass rate.

### Phase 13 — Autonomous Engineering Loop
- [ ] Iterative execution: make focused code edits $\to$ run analyzer $\to$ run tests $\to$ resolve any errors.
- [ ] Maintain zero compiler warnings and zero analyzer issues.

### Phase 14 — Android APK Build & Verification
- [ ] Run `flutter clean` & `flutter pub get`.
- [ ] Run `dart analyze frontend`.
- [ ] Run `flutter test`.
- [ ] Build debug APK: `flutter build apk --debug`.
- [ ] Check connected physical Android device status via `adb devices`.

### Phase 15 — Documentation & Delivery
- [ ] Update `README.md`.
- [ ] Generate comprehensive documentation in `docs/`:
  - `docs/ARCHITECTURE.md`
  - `docs/INSTALLATION_GUIDE.md`
  - `docs/ANDROID_PERMISSION_GUIDE.md`
  - `docs/API_CONFIGURATION.md`
  - `docs/DEVICE_TESTING_GUIDE.md`
  - `docs/KNOWN_LIMITATIONS.md`
- [ ] Provide final detailed completion report.

