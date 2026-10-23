# Phase 00 — Repository Baseline Assessment

**Project:** Blind Assistant AI (Navigation & Object Detection)
**Report date:** 2026-10-21
**Prepared by:** Antigravity audit agent
**Status:** Complete — ready for review before Phase 1 begins

---

## 1. Executive Summary

The Blind Assistant AI project is a hybrid assistive application targeting blind and low-vision users. It consists of a Python/FastAPI backend and a Flutter/Dart mobile frontend that communicate over WebSocket and REST.

**The backend is in a functional, demo-ready state.** The core architectural scaffolding — pipeline interfaces, mock-vs-real model toggle, decision engine, session management — is real, well-structured code. The object detector (YOLOv11n via `ultralytics`) is wired in and running. All 12 automated backend tests pass cleanly. Application logs confirm it has been run and connected to a WebSocket client on multiple occasions between August and October 2026.

**The Flutter frontend is structurally correct but has one critical defect that must be fixed before Phase 1 begins.** `flutter analyze` confirms a `creation_with_non_type` compile error in `test/widget_test.dart` — the default Flutter boilerplate test was never updated when `MyApp` was replaced with `BlindAssistantApp`. The voice command button actions (describe, read, find) are wired to placeholder TTS strings rather than real backend API calls. Two additional informational warnings are present.

**Seven of nine AI pipeline stages remain mocked.** Only the object detector is real. Depth estimation, scene description, tracking, OCR, speech-to-text, text-to-speech, segmentation, and open-vocabulary location all return deterministic synthetic responses. This is appropriate for the current stage but is the primary technical gap to close.

The repository is ready to enter Phase 1 subject to one mandatory fix (the broken widget test) and acknowledgement of the five priority issues listed in Section 11.

---

## 2. Verified Repository Structure

```
blind assistant final/
├── backend/
│   ├── app/
│   │   ├── main.py                      ← FastAPI app, CORS, startup detector warmup
│   │   ├── api/
│   │   │   ├── routes.py                ← REST: health, session, frame, OCR, voice-command
│   │   │   └── websocket.py             ← /ws/navigate/{session_id} streaming endpoint
│   │   ├── core/
│   │   │   ├── config.py                ← Settings: mock/real toggle, JWT, DB URL, thresholds
│   │   │   └── logging_config.py        ← Rotating file + console logger
│   │   ├── models/
│   │   │   └── schemas.py               ← Pydantic data contracts (Detection, Guidance…)
│   │   ├── pipeline/
│   │   │   ├── interfaces.py            ← Abstract base classes for all 9 AI components
│   │   │   ├── factory.py               ← Builds Pipeline; mock-vs-real switch per component
│   │   │   ├── mock/
│   │   │   │   ├── detection.py         ← MockDetector, MockTracker
│   │   │   │   ├── perception.py        ← MockDepth, MockScene, MockOCR, MockSeg, MockLocator
│   │   │   │   └── voice.py             ← MockSTT, MockTTS
│   │   │   └── real/
│   │   │       └── yolo_detector.py     ← REAL: YOLOv11n via ultralytics 8.4.115
│   │   ├── services/
│   │   │   ├── decision_engine.py       ← REAL: urgency classification, cooldown suppression
│   │   │   └── session_manager.py       ← In-memory session store, per-session engine instance
│   │   └── tests/
│   │       ├── test_decision_engine.py  ← 6 unit tests — all PASS
│   │       └── test_pipeline.py         ← 6 unit tests — all PASS
│   ├── logs/app.log                     ← Evidence of prior runs (Aug–Oct 2026)
│   ├── yolo11n.pt                       ← Pre-downloaded weights (~5.4 MB)
│   ├── requirements.txt
│   ├── pytest.ini
│   └── README.md
│
├── frontend/
│   ├── lib/
│   │   ├── main.dart                    ← Entry point; ProviderScope + MaterialApp.router
│   │   ├── core/
│   │   │   ├── app_settings.dart        ← Backend host/port; SharedPreferences persistence
│   │   │   ├── providers.dart           ← Riverpod providers: settings, apiService, ttsService
│   │   │   ├── router.dart              ← GoRouter: "/" → NavigationScreen, "/settings" → SettingsScreen
│   │   │   └── theme.dart               ← High-contrast dark theme, large touch targets
│   │   ├── features/
│   │   │   ├── navigation/
│   │   │   │   ├── navigation_screen.dart      ← Main UI: camera preview + guidance banner
│   │   │   │   └── navigation_controller.dart  ← StateNotifier: camera, WebSocket, TTS orchestration
│   │   │   ├── settings/
│   │   │   │   └── settings_screen.dart        ← Host/port config + live health-check test
│   │   │   └── voice/
│   │   │       └── voice_command_button.dart   ← On-device STT; actions NOT wired to backend
│   │   ├── models/
│   │   │   └── detection.dart           ← BoundingBox, Detection, GuidanceMessage, FrameResult
│   │   ├── services/
│   │   │   ├── api_service.dart         ← HTTP: startSession, endSession, describeScene, readText, findObject
│   │   │   ├── navigation_socket.dart   ← WebSocket wrapper; frame stream + error stream
│   │   │   └── tts_service.dart         ← flutter_tts wrapper; urgent interrupts current speech
│   │   └── widgets/
│   │       └── guidance_banner.dart     ← Colour-coded guidance cards (urgent/warn/info)
│   ├── test/
│   │   └── widget_test.dart             ← BROKEN: references non-existent class 'MyApp'
│   ├── android/app/src/main/
│   │   └── AndroidManifest.xml          ← CAMERA, RECORD_AUDIO, INTERNET declared
│   ├── assets/                          ← Empty (no bundled assets)
│   ├── pubspec.yaml
│   └── pubspec.lock                     ← Resolved; flutter pub get has been run
│
└── docs/
    └── phase-reports/
        └── phase-00-repository-baseline.md  ← This file
```

**Observation:** There is no top-level README, `.gitignore`, `docker-compose.yml`, CI/CD configuration, or `.env` file at the repository root. Each sub-project has its own README.

---

## 3. Frontend and Backend Technology Inventory

### 3.1 Backend — Verified Package Versions

| Component | Technology | Version |
|-----------|-----------|---------|
| Language | Python | 3.10.8 |
| Web framework | FastAPI | 0.115.0 |
| ASGI server | Uvicorn (standard) | 0.30.6 |
| Data validation | Pydantic v2 | 2.9.2 |
| Settings | pydantic-settings | 2.5.2 |
| WebSocket | websockets (via uvicorn) | 13.1 |
| Object detector | ultralytics (YOLOv11) | 8.4.115 |
| Image processing | Pillow | 10.4.0 |
| Numerical arrays | NumPy | 2.2.6 |
| Auth library | python-jose + passlib | 3.3.0 / 1.7.4 |
| Database ORM | SQLAlchemy + aiosqlite | 2.0.35 / 0.20.0 |
| HTTP client (tests) | HTTPX | 0.27.2 |
| Test runner | pytest + pytest-asyncio | 8.3.3 / 0.24.0 |
| Form parsing | python-multipart | 0.0.9 |
| Package manager | pip | 26.1.1 |

**Notable findings:**
- SQLAlchemy and aiosqlite are declared but no database model or migration exists. The `database_url` setting points to an SQLite file that is never created. These are premature dependencies anticipating a future admin dashboard.
- JWT / passlib are declared for admin authentication but no admin route has been implemented. The `jwt_secret` defaults to `"change-me-in-production"` — a production security risk.
- Pydantic class-based `Config` is deprecated in v2 and will break in v3.
- `asyncio_default_fixture_loop_scope` not set in pytest.ini — deprecation notice from pytest-asyncio.

### 3.2 Frontend — Declared and Resolved Package Versions

| Component | Technology | Declared | Resolved |
|-----------|-----------|---------|---------|
| Language | Dart | >=3.3.0 <4.0.0 | 3.13.3 |
| UI framework | Flutter | >=3.19.0 | 3.47.4 |
| State management | flutter_riverpod | ^2.5.1 | (in lock) |
| Routing | go_router | ^14.2.0 | (in lock) |
| Camera | camera | ^0.11.0+2 | 0.11.4 |
| WebSocket | web_socket_channel | ^3.0.1 | (in lock) |
| HTTP | http | ^1.2.2 | (in lock) |
| On-device TTS | flutter_tts | ^4.0.2 | (in lock) |
| On-device STT | speech_to_text | ^7.0.0 | (in lock) |
| Permissions | permission_handler | ^11.3.1 | (in lock) |
| Persistence | shared_preferences | ^2.3.2 | (in lock) |
| Test framework | flutter_test (SDK) | — | 3.47.4 |
| Lint | flutter_lints | ^4.0.0 | (in lock) |

**Android build tooling:**
- Flutter SDK: `C:\src\flutter` (from local.properties)
- Android SDK: `C:\Users\Manvith S shetty\AppData\Local\Android\sdk`
- compileSdk / minSdk / targetSdk / ndkVersion: delegated to Flutter's Gradle variables — exact values not independently verified.
- applicationId: `com.example.blind_assistant` (default — must change before any store build).

### 3.3 Camera-to-Spoken-Guidance Data Flow

```
[Android Camera]
    |  takePicture() every 400 ms
    v
[navigation_controller.dart]
    |  JPEG bytes -> base64
    v
[navigation_socket.dart]
    |  WebSocket: {"image_base64": "..."}
    v
[websocket.py  /ws/navigate/{session_id}]
    |  Throttle: skip frames arriving faster than 0.3 s
    |  Decode base64 -> numpy uint8 array
    v
[YoloDetector.detect()]                    <- REAL inference
    |  YOLO("yolo11n.pt"), conf >= 0.4
    |  Filtered to 33 navigation-relevant COCO classes
    v
[MockTracker.update()]                     <- MOCK
    |  Label + centre-distance match; assigns sequential track IDs
    v
[MockDepthEstimator.estimate()]            <- MOCK  *** SAFETY-CRITICAL GAP ***
    |  distance_m = heuristic(bbox_height, vertical_position)  [uncalibrated]
    |  direction  = "left" | "center" | "right" from horizontal centre
    v
[DecisionEngine.generate_guidance()]       <- REAL logic
    |  Sort nearest-first
    |  Classify: urgent (<=0.8 m), warn (<=2.0 m), info (>2.0 m)
    |  4-second cooldown per track_id; urgent bypasses cooldown
    v
[WebSocket response]
    |  {"session_id", "frame_id", "detections": [...], "guidance": [...]}
    v
[navigation_controller.dart  _onFrameResult()]
    |  Update Riverpod state -> rebuild GuidanceBanner
    v
[TtsService.speakGuidance()]               <- On-device flutter_tts
    |  Urgent -> _tts.stop() first (safety over politeness)
    v
[User hears spoken guidance]
```

---

## 4. Real / Mock / Missing AI Component Matrix

| # | Component | Role | Status | File | Notes |
|---|-----------|------|--------|------|-------|
| 1 | Detector | Find obstacles | REAL | real/yolo_detector.py | YOLOv11n, conf>=0.4, 33 COCO classes, asyncio.to_thread |
| 2 | Tracker | Stable IDs across frames | MOCK | mock/detection.py | Label+proximity match. Target: real/bytetrack_tracker.py (absent) |
| 3 | Depth Estimator | Measure distance | MOCK | mock/perception.py | Uncalibrated heuristic. SAFETY-CRITICAL. Target: real/depth_anything.py (absent) |
| 4 | Scene Describer | Caption the scene | MOCK | mock/perception.py | Mean brightness -> "indoor"/"outdoor". Target: real/florence2.py (absent) |
| 5 | Open-Vocab Locator | "Find my keys" | MOCK | mock/perception.py | Fixed centre bbox regardless of query. Target: real/locate_anything.py (absent) |
| 6 | OCR Reader | Read text | MOCK | mock/perception.py | Always "Sample detected text". Target: real/paddle_ocr.py (absent) |
| 7 | Segmenter | Pixel-level masks | MOCK | mock/perception.py | Rectangular fill. Not called in any route. Target: real/sam2_segmenter.py (absent) |
| 8 | Speech-to-Text | Transcribe voice | MOCK | mock/voice.py | Always "what is in front of me". Target: real/whisper_stt.py (absent) |
| 9 | Text-to-Speech | Backend voice output | MOCK | mock/voice.py | Silent 0.25s WAV. Flutter uses on-device TTS instead. Target: real/piper_tts.py (absent) |

**Summary: 1 of 9 real. 8 of 9 mocked. 7 of 8 mocked components have no code in app/pipeline/real/.**

### 4.1 Frontend AI/Sensor Components

| Component | Status | Notes |
|-----------|--------|-------|
| Camera capture | Real | camera pkg, back-facing, ResolutionPreset.medium, 400 ms interval |
| On-device TTS | Real | flutter_tts, rate 0.55, urgent interrupts playback |
| On-device STT | Wired but incomplete | speech_to_text initialised; _handleCommand() returns placeholders only — no API calls made |
| Bounding-box overlay | Missing | Detections received in state but never painted on camera preview |
| Accessibility (Semantics) | Partial | Semantics on buttons and liveRegion on guidance cards; no TalkBack integration test |

---

## 5. Test and Build Baseline

### 5.1 Backend Tests

**Command:** `venv\Scripts\python.exe -m pytest app/tests/ -v --tb=short`
**Date:** 2026-10-21

| Test | File | Result |
|------|------|--------|
| test_urgent_obstacle_flagged | test_decision_engine.py | PASS |
| test_warn_obstacle_includes_move_hint | test_decision_engine.py | PASS |
| test_far_object_is_info_level | test_decision_engine.py | PASS |
| test_nearest_obstacle_announced_first | test_decision_engine.py | PASS |
| test_reannounce_cooldown_suppresses_repeats | test_decision_engine.py | PASS |
| test_urgent_bypasses_cooldown | test_decision_engine.py | PASS |
| test_detector_returns_detections | test_pipeline.py | PASS |
| test_tracker_assigns_ids | test_pipeline.py | PASS |
| test_depth_estimator_adds_distance_and_direction | test_pipeline.py | PASS |
| test_scene_describer_returns_caption | test_pipeline.py | PASS |
| test_stt_handles_empty_audio | test_pipeline.py | PASS |
| test_tts_returns_valid_wav_bytes | test_pipeline.py | PASS |

**Result: 12/12 PASSED in 1.08 seconds.**

Non-fatal warnings:
- pytest-asyncio: asyncio_default_fixture_loop_scope not set
- Pydantic: class-based Config deprecated

Not covered by current suite:
- Real YoloDetector path (all pipeline tests use mocks)
- REST endpoints (no HTTPX TestClient integration test)
- WebSocket streaming endpoint
- Voice-command routing logic in routes.py

### 5.2 Flutter Static Analysis

**Command:** `flutter analyze --no-fatal-infos`
**Date:** 2026-10-21  **Duration:** 63.8 s  **Exit code:** 1

| Severity | Location | Issue | Rule |
|----------|----------|-------|------|
| ERROR | test/widget_test.dart:16 | 'MyApp' is not a class (boilerplate test never updated) | creation_with_non_type |
| info | lib/models/detection.dart:1 | Dangling library doc comment | dangling_library_doc_comments |
| info | lib/widgets/guidance_banner.dart:41 | withOpacity() deprecated | deprecated_member_use |

**Result: 1 compile error, 2 informational warnings. flutter test cannot run.**

### 5.3 Flutter Widget Tests

`flutter test` was NOT RUN during this phase. The static analyser confirmed a compile error that prevents the test binary from building. Result is recorded as a known failure.

### 5.4 Backend Server Startup Evidence (from app.log)

The application log confirms the server has been run on multiple prior occasions, each with successful model loading and at least one WebSocket session.

| Date | Event | Detail |
|------|-------|--------|
| 2026-08-05 10:57 | First run | YOLOv11 load ~10 s; warmup ~11 s; 3 WebSocket sessions completed |
| 2026-08-11 15:34 | Second run | Load ~0.15 s (OS cache); 1 session ~8 min |
| 2026-09-03 18:44 | Third run | Load ~0.17 s; 1 session |
| 2026-09-04 | Two separate runs | Multiple short sessions |
| 2026-09-16 23:03 | Run | Model loaded; no session logged |
| 2026-10-08 22:24 | Most recent run | Model loaded; log truncated before warmup entry |

Model load time dropped from ~10 s on first run to ~0.15 s on subsequent runs — consistent with OS disk-caching the 5.4 MB weight file. No errors appear in any log entry.

---

## 6. Known Bugs and Risks (Prioritised by Severity)

### CRITICAL

**BUG-01 — Depth estimation is entirely synthetic (safety risk)**
- File: `app/pipeline/mock/perception.py` — MockDepthEstimator
- Detail: Distance values sent to the decision engine are computed from a heuristic formula using bounding-box height and vertical position only. There is no physical calibration to any real camera. The formula produces incorrect distances for wide-angle lenses, partially visible objects, and unusual depth cues (e.g. a tall distant object appears near; a small close object can appear far).
- Risk: The decision engine uses these distances to trigger urgent "Stop" announcements. A user could receive a false urgent warning or — more dangerously — receive no warning for an obstacle the heuristic misjudges as far away.
- Action: Implement Depth Anything V2 in Phase 1 as the first post-tracker real model.

**BUG-02 — Flutter widget test has a compile error**
- File: `test/widget_test.dart:16`
- Detail: The auto-generated boilerplate counter-app test references `MyApp`, which does not exist in this project. `BlindAssistantApp` is the correct class name.
- Risk: `flutter test` fails to compile. Any CI pipeline yields a permanently red status.
- Action: Replace `MyApp()` with `BlindAssistantApp()` — one-line fix, must be done before Phase 1.

### HIGH

**BUG-03 — Voice command button not connected to backend**
- File: `lib/features/voice/voice_command_button.dart` — `_handleCommand()`
- Detail: Recognises "read", "find", and "describe/what/around" but responds with hard-coded TTS placeholders: "Reading text is not yet connected", etc. `ApiService.readText()`, `findObject()`, and `describeScene()` exist and are correct but are never invoked.
- Risk: A core advertised feature is non-functional. Any user or evaluator who speaks a command receives a placeholder.
- Action: Wire `_handleCommand()` to the appropriate `ApiService` method in Phase 1. Requires passing the current camera frame from `NavigationController`.

**BUG-04 — No detection overlay on camera preview**
- File: `lib/features/navigation/navigation_screen.dart` — `_CameraPreviewArea`
- Detail: `NavigationState.detections` is updated every frame but never drawn. The real YOLO output is invisible.
- Risk: Cannot visually verify that detection is functioning. Reduces demo credibility significantly.
- Action: Add a `CustomPainter` overlay on `CameraPreview` in Phase 1.

**BUG-05 — Default JWT secret is a public placeholder**
- File: `app/core/config.py`
- Detail: `jwt_secret = "change-me-in-production"`. No admin routes exist yet but the secret is loaded unconditionally. Deploying without a `.env` override leaves any future admin endpoint trivially exploitable.
- Action: Add a startup assertion that raises if the default value is used and `DEBUG != True`.

### MEDIUM

**BUG-06 — Pydantic v2 class-based Config is deprecated**
- File: `app/core/config.py`
- Action: Replace with `model_config = ConfigDict(env_file=".env", env_nested_delimiter="__")`.

**BUG-07 — pytest-asyncio loop scope not set**
- File: `pytest.ini`
- Action: Add `asyncio_default_fixture_loop_scope = function`.

**BUG-08 — Session store is in-memory only**
- File: `app/services/session_manager.py`
- Detail: A server restart silently loses all sessions and cooldown history. SQLAlchemy is declared as a dependency but never used.
- Action: Acceptable for Phase 1; address in Phase 2 with admin dashboard work.

**BUG-09 — applicationId is the Flutter default**
- File: `frontend/android/app/build.gradle.kts`
- Detail: `com.example.blind_assistant` cannot be published to the Play Store and may conflict with other dev apps on the same device.
- Action: Change before the first physical-device or Play Store build.

### LOW

**BUG-10 — usesCleartextTraffic enabled for all builds**
- File: `android/app/src/main/AndroidManifest.xml`
- Detail: Required for local dev (plain http://) but must be disabled for production HTTPS connections.
- Action: Move to a debug-only manifest overlay before production.

**BUG-11 — withOpacity() deprecated**
- File: `lib/widgets/guidance_banner.dart:41`
- Action: Replace with `.withValues(alpha: ...)`.

**BUG-12 — Segmenter instantiated but never called**
- Files: `app/pipeline/factory.py`, `routes.py`, `websocket.py`
- Detail: `pipeline.segmenter` is created at startup but no endpoint calls `segment()`. Free-space perception is structurally absent.
- Action: Either wire into the navigation loop in Phase 1 or remove from the active pipeline until it is needed.

---

## 7. Model Compatibility and Licensing Questions

| Model | Stage | Licence | Verified | Notes |
|-------|-------|---------|---------|-------|
| YOLOv11n | Detector | AGPL-3.0 | Yes | AGPL-3.0 requires source disclosure on distribution. Closed commercial apps need a commercial ultralytics licence. Must be decided before any public release. |
| ByteTrack | Tracker | MIT | No | Verify the specific library (e.g. supervision). |
| Depth Anything V2 | Depth estimator | Apache-2.0 | No | Apache-2.0 is permissive. Verify weight-specific terms on the HuggingFace model card. |
| Florence-2 | Scene describer | MIT (Microsoft) | No | Fine-tuned variants may carry different terms. |
| NVIDIA Locate Anything-3B | Open-vocab locator | Not verified | No | NVIDIA licences vary. 3B parameters implies significant runtime requirements; assess hardware. |
| PaddleOCR | OCR reader | Apache-2.0 | No | Generally permissive. |
| SAM2 / FastSAM | Segmenter | Apache-2.0 (Meta) | No | Weights must be downloaded separately. |
| Whisper Large-v3 | Speech-to-text | MIT (OpenAI) | No | ~3 GB. Consider `base` or `small` for latency-sensitive or on-device use. |
| Piper TTS | Text-to-speech | MIT | No | Fully offline. Voice model licences vary by voice pack. |

**Most urgent licensing action:** The AGPL-3.0 constraint on YOLOv11 must be resolved before any public or commercial distribution.

---

## 8. Recommended Implementation Order for Phase 1

| Priority | Task | Rationale |
|----------|------|-----------|
| 1 | Fix test/widget_test.dart compile error | Unblocks flutter test; 1-line change |
| 2 | Wire voice command button to ApiService REST calls | Closes the only user-facing incomplete feature |
| 3 | Add detection bounding-box overlay on camera preview | Makes real YOLO output visible; critical for demos |
| 4 | Implement real ByteTrack tracker | Stable track IDs required for decision-engine cooldown to work correctly |
| 5 | Implement real Depth Anything V2 estimator | Replaces safety-critical uncalibrated heuristic with real monocular depth |
| 6 | Add backend integration tests (HTTPX TestClient) | Real detector path has zero automated coverage |
| 7 | Set asyncio_default_fixture_loop_scope in pytest.ini | Eliminates deprecation warning before it becomes a hard error |
| 8 | Migrate Pydantic config to ConfigDict | Eliminates Pydantic v2 deprecation warning |
| 9 | Add startup guard for default jwt_secret | Security hygiene before any admin endpoint is added |
| 10 | Change applicationId from com.example.* | Required for Play Store publication and clean device testing |

---

## 9. Commands Executed and Actual Results

All commands were non-destructive (read-only checks, test runners, static analyser). No code was modified during this audit.

```
COMMAND:  flutter --version
RESULT:   Flutter 3.47.4 (stable channel)
          Dart 3.13.3
          DevTools 2.60.0

COMMAND:  python --version
RESULT:   Python 3.10.8

COMMAND:  pip --version
RESULT:   pip 26.1.1

COMMAND:  venv\Scripts\python.exe -c "import fastapi; print(fastapi.__version__); ..."
RESULT:   fastapi      0.115.0
          uvicorn      0.30.6
          pydantic     2.9.2
          ultralytics  8.4.115
          numpy        2.2.6
          pillow       10.4.0

COMMAND:  venv\Scripts\python.exe -c "import pytest; ...; import httpx; ..."
RESULT:   pytest         8.3.3
          pytest-asyncio 0.24.0
          httpx          0.27.2

COMMAND:  venv\Scripts\python.exe -m pytest app/tests/ -v --tb=short
RESULT:   12 passed, 1 warning (1.08 s)
          Exit code: 0 (success)
          Warnings:
            - Pydantic class-based Config deprecated (non-fatal)
            - asyncio_default_fixture_loop_scope not set (non-fatal)

COMMAND:  flutter analyze --no-fatal-infos
RESULT:   3 issues found (63.8 s)
          Exit code: 1 (failure)
          [error]  test/widget_test.dart:16:35 — 'MyApp' isn't a class
          [info]   lib/models/detection.dart:1:1 — dangling library doc comment
          [info]   lib/widgets/guidance_banner.dart:41:43 — withOpacity() deprecated
```

---

## 10. Outstanding Questions and Unverified Items

### Measurements that require a live running system (not measured in this audit)

| Item | How to measure |
|------|---------------|
| End-to-end latency (camera frame -> spoken guidance) | Timestamp at websocket receive and send; log CameraController frame timestamps |
| YOLOv11 inference time on this machine | time.perf_counter() around detect() call; log per-frame |
| WebSocket frame loss rate | Compare client capture ticks vs. server frame_count increments |
| Camera frame rate and capture resolution | Log CameraController.value.previewSize at session start |
| CPU / RAM / GPU usage under load | psutil on backend; Flutter DevTools CPU/memory tab on frontend |
| Android minSdk / targetSdk exact values | Run flutter build apk --config-only; inspect generated build/app/outputs/apk/ |

### Decisions required from the project owner before Phase 1

1. **Depth model deployment target.** Will Depth Anything V2 run on the backend server (high RAM/VRAM) or on-device via ONNX/TFLite? On-device removes the network round-trip but requires model conversion and Android compatibility testing.
2. **STT primary path.** Phase 1: on-device `speech_to_text` (already wired in Flutter) or backend Whisper endpoint? Different latency and accuracy trade-offs.
3. **Admin dashboard scope.** SQLAlchemy and JWT are pre-declared. Is the admin dashboard Phase 1 or Phase 2?
4. **Free-space segmentation.** The Segmenter interface exists but is never called. Is walkable-floor detection a Phase 1 requirement?
5. **Network security.** Will WSS/HTTPS be required for Phase 1 (real device testing over the internet, regulatory compliance)?
6. **YOLOv11 licence.** AGPL-3.0 vs. commercial ultralytics licence — must be decided before any public distribution.

---

## 11. Handover Summary

### What was inspected

Every source file was read: 15 Python files across 7 backend modules; 15 Dart files across 6 frontend modules; AndroidManifest.xml; both build.gradle files; pubspec.yaml and pubspec.lock; application log (43 entries); both READMEs. The backend test suite was executed. Flutter static analysis was run.

### What is currently working

- **Backend:** FastAPI starts, loads YOLOv11n, warms up the detector, and serves WebSocket + REST. All 12 automated tests pass. Application logs confirm successful WebSocket sessions on multiple prior dates.
- **Decision engine:** Real urgency classification (urgent/warn/info thresholds), directional phrase generation, and per-track-ID cooldown suppression are all implemented and tested.
- **Flutter app structure:** Riverpod state management, GoRouter navigation, WebSocket streaming with throttle, on-device TTS with urgency interruption, Settings screen with health check, and session lifecycle management are all correctly implemented.

### What is broken or mocked

- **Broken (compile error):** `test/widget_test.dart` — `flutter test` cannot build.
- **Broken (functional gap):** Voice command button returns placeholder TTS strings; no backend call is made.
- **Mock (8 of 9 AI stages):** Tracker, depth estimator, scene describer, OCR reader, open-vocab locator, segmenter, STT, and backend TTS are all deterministic stubs. Depth values are physically uncalibrated — a safety concern.
- **Missing:** Detection bounding-box overlay on camera preview. Backend integration tests. Real implementations for all 8 mocked pipeline stages.

### Five highest-priority issues

1. **BUG-01 (CRITICAL):** Depth estimation is a heuristic. Distances are uncalibrated. The decision engine uses these values to trigger safety-critical "Stop" announcements.
2. **BUG-02 (CRITICAL):** `flutter test` fails to compile due to a stale `MyApp` reference in the boilerplate widget test.
3. **BUG-03 (HIGH):** Voice commands are wired to placeholder TTS strings only. The feature is non-functional end-to-end.
4. **BUG-04 (HIGH):** No bounding-box overlay on the camera preview. The real YOLO output is invisible to users and evaluators.
5. **Licensing (HIGH):** YOLOv11 is AGPL-3.0 by default. Closed distribution of the application requires a commercial ultralytics licence.

### Is the repository ready for Phase 1?

**Yes — with one mandatory pre-condition.** BUG-02 (`test/widget_test.dart`) must be fixed before Phase 1 begins; it is a one-line change. All other findings are Phase 1 work items. The architecture is clean. The pipeline factory pattern means real model implementations can be wired in one component at a time without touching any API, routing, or decision-engine code.

### Blockers to resolve before Phase 1

1. **Fix test/widget_test.dart** — replace `MyApp()` with `BlindAssistantApp()`.
2. **Resolve the AGPL-3.0 licence question** for YOLOv11 to determine distribution constraints.
3. **Decide the deployment target for Depth Anything V2** (backend server vs. on-device ONNX/TFLite) — this drives the Phase 1 implementation plan.
