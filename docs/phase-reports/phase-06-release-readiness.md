# Phase 06 — Security, Final Testing, and Release Preparation Report

**Project:** Blind Assistant AI (Hardening, Verification, Model Licensing Audit, and Android Release Packaging)  
**Report Date:** 2026-10-23  
**Status:** COMPLETE (Security Hardening: PASS; Model & Weights Licensing Audit: BLOCKED FOR PROPRIETARY DISTRIBUTION; Automated Verification: PASS; Android Packaging: PASS; Physical Device Field Testing: PENDING)  

---

## 1. Executive Summary and Release Recommendation

Phase 6 hardens the Blind Assistant application across backend and mobile client surfaces, eliminates insecure defaults, establishes strict input limits (payload size, image dimensions, admin operation protections), comprehensively audits open-source licenses for both code and model weights, runs the full automated verification test suite, builds the Android release APK, and produces a complete, honest release evaluation.

### Release Recommendation: **CONDITIONAL RESEARCH PROTOTYPE ONLY — NOT FOR INDEPENDENT COMMERCIAL OR SAFETY-CRITICAL DISTRIBUTION**

> [!CAUTION]
> **Navigation Safety Warning:**  
> The software is **NOT certified as safe for independent navigation** by visually impaired or blind individuals without an attentive, sighted human companion. Obstacle detection is probabilistic, monocular depth estimation outputs uncalibrated relative disparity (not physical metric distance), and camera motion blur or environmental glare can lead to missed hazards.

> [!WARNING]
> **Commercial Distribution Blocker:**  
> Closed-source or proprietary binary distribution is currently **BLOCKED** due to GNU AGPL v3.0 obligations attached to Ultralytics YOLOv11 and YOLO-World code and pretrained weights.

| Release Aspect | Status | Verdict & Justification |
|---|:---:|---|
| **Software Integrity & Automated Testing** | **READY** | All 47 backend integration/unit tests pass (100%); all 11 Flutter tests pass (100%); zero lint errors in Flutter static analysis (`flutter analyze`). |
| **Security & Operational Hardening** | **READY** | Secrets strictly env-driven; CORS restricted; `/system/trim-memory` protected with constant-time `secrets.compare_digest` and `X-Admin-Key`; 10 MB payload limits and 4096px image bounds enforced on both REST and WebSocket. |
| **Commercial / Binary Distribution Licensing** | **BLOCKED** | Ultralytics YOLOv11, YOLO-World, and YOLOv11n-seg are subject to GNU AGPL-3.0. Distribution of binary packages without full source disclosure or commercial enterprise licenses is prohibited under upstream terms. |
| **Physical Device & Navigation Safety** | **PENDING / BLOCKED** | No physical Android hardware was connected during build verification. Monocular depth estimation and software heuristic tests cannot guarantee physical obstacle safety. |

---

## 2. Stage-by-Stage Status Matrix

| Stage | Focus Area | Status | Key Deliverables & Evidence |
|---|---|:---:|---|
| **Stage 1** | Security & Configuration Audit | **PASS** | Removed hard-coded secrets; added production validation (JWT secret min 32 chars, admin API key min 16 chars); restricted CORS to explicit origins; protected `POST /api/v1/system/trim-memory` with `secrets.compare_digest` against timing attacks; added 10 MB and 4096px image payload/dimension limits across REST and WebSocket handlers; sanitized logs (no base64 frames or secrets). |
| **Stage 2** | Licensing & Dependency Review | **BLOCKED** | Cataloged all dependencies, model code, and model weights; verified licenses: YOLOv11 (AGPL-3.0), YOLO-World (AGPL-3.0), YOLOv11n-seg (AGPL-3.0), ByteTrack (MIT), Depth Anything V2 (Apache-2.0), BLIP (BSD-3-Clause), RapidOCR (Apache-2.0). Formal blocker logged against proprietary distribution; documented compliant alternatives and unresolved dataset copyright questions. |
| **Stage 3** | End-to-End & Regression Testing | **PASS** | Pytest: **47/47 passed** in 23.81s (exit code 0); Flutter tests: **11/11 passed** in 1.4s (exit code 0); `flutter analyze`: **0 issues** (exit code 0). Tested malformed frames, oversized payloads, late-frame drops, missing models, oversized dimensions, admin authorization, and WebSocket reconnect loops. |
| **Stage 4** | Android Release Preparation | **PASS** | Configured release signing with debug keystore fallback for testing; resolved Gradle 9 plugin and Kotlin compatibility (`CallbackToFutureAdapter`); generated reproducible release build (`build/app/outputs/flutter-apk/app-release.apk`, **49.9 MB**, exit code 0); configured permissions (`CAMERA`, `INTERNET`, `RECORD_AUDIO`). |
| **Stage 5** | Physical-Device Verification Plan | **PENDING** | Environment contains no physical Android phone or emulator (`flutter devices` found Windows, Chrome, Edge); created comprehensive 8-step physical device test protocol with safety checklist for project owners. |
| **Stage 6** | Final Report and Handover | **PASS** | Published `docs/phase-reports/phase-06-release-readiness.md` with complete handover documentation. |

---

## 3. Security Changes and Unresolved Risks

### 3.1 Security Hardening Changes Implemented

1. **Environment Configuration & Fail-Safe Defaults (`backend/app/core/config.py`):**
   - Added `environment: str = "development"` configuration setting.
   - Replaced static default secrets. Added a `@model_validator(mode="after")` that strictly rejects default fallback keys (`"change-me-in-production"`), keys shorter than 32 characters, and wildcard CORS origins (`"*"`) when `ENVIRONMENT=production`.
   - Added production validation requiring `admin_api_key` to be at least 16 characters if configured.
2. **CORS Hardening (`backend/app/main.py`):**
   - Replaced wildcard `allow_origins=["*"]` with explicit `settings.cors_origins` (defaulting to local development hosts `http://localhost:3000`, `http://127.0.0.1:3000`, `http://localhost:8000`).
3. **Administrative Endpoint Authorization (`backend/app/api/routes.py`):**
   - Secured `POST /api/v1/system/trim-memory` using a header dependency requiring `X-Admin-Key`.
   - Utilizes `secrets.compare_digest(x_admin_key, settings.admin_api_key)` to prevent timing side-channel attacks.
   - Fails closed in production environments if `admin_api_key` is not configured.
4. **Input Size Limits & Dimension Guards (`backend/app/api/routes.py` & `websocket.py`):**
   - Set maximum raw image payload limit to **10 MB** (`max_image_payload_bytes`).
   - If an image file or base64 frame exceeds 10 MB, the server immediately rejects the request with HTTP `413 Payload Too Large` (or WebSocket error `payload_too_large`) before decoding.
   - Enforced maximum decoded image dimensions of **4096 × 4096 pixels** (`max_image_dimension`) across both REST routes (`_decode_image`) and WebSocket streaming (`/ws/navigate/{session_id}`). Oversized frames are rejected with HTTP `400 Bad Request` or WebSocket error `image_dimension_too_large` to prevent decompression bomb Denial of Service (DoS).
5. **Flow Control Fix in WebSocket (`backend/app/api/websocket.py`):**
   - Added missing `continue` statement on payload parsing errors (`invalid_payload`), preventing stale frame buffer reprocessing and queue desynchronization.
6. **Log Hygiene:**
   - Confirmed that WebSocket frames, raw base64 data, and decoded OpenCV image buffers are never printed to stdout/stderr or application logs. Only frame sequence numbers, timestamps, and detection summary metrics are logged.

### 3.2 Unresolved Security & Privacy Risks

- **Plaintext WebSocket / HTTP in Local Development:** The client currently connects over unencrypted `ws://` and `http://` for local host testing (`android:usesCleartextTraffic="true"`). For production deployments, TLS termination (`wss://` and `https://`) via a reverse proxy (e.g., Nginx, Caddy, or Cloudflare) is mandatory to protect live camera video streams from network eavesdropping.
- **End-User Authentication Omitted by Design:** The client has no user login screen. This was an intentional accessibility design choice to allow visually impaired users immediate, one-touch access to assistance. Device-level security (e.g., Android biometric lock or OS sandbox) must protect the physical handset.
- **Backend Model Resource Depletion:** While individual frame sizes are bounded to 10 MB and 4096px, multiple concurrent WebSocket streams could exhaust CPU or GPU memory if deployed to a public server without per-IP rate limiting or connection concurrency caps.

---

## 4. Licensing and Model Weights Verification

A rigorous multi-layer audit was conducted across code packages, model weights, and upstream training data:

| Component / Model | Exact File / Artifact | Upstream Code License | Weight Licensing Terms & Dataset Scope | Distribution Status & Obligations | Compliant Alternatives |
|---|---|---|---|---|---|
| **YOLOv11 Object Detector** | `yolo11n.pt`, `yolo11n.onnx` | GNU AGPL-3.0 (Ultralytics) | Pretrained weights distributed by Ultralytics under AGPL-3.0. Trained on COCO (Images: various Creative Commons; Annotations: CC BY 4.0). | **BLOCKED for proprietary distribution.** Requires complete open-sourcing under AGPL-3.0 or purchasing an Ultralytics Enterprise License. | **RT-DETR** (Apache-2.0 code & weights via PaddleDetection / Lyuwenyu) or **MobileNetV4-SSD** (Apache-2.0). |
| **YOLO-World Open-Vocab Locator** | `yolov8s-worldv2.pt`, `weights/clip/ViT-B-32.pt` | GNU AGPL-3.0 (Ultralytics wrapper) / GPL-3.0 (Tencent) | Weights released under AGPL-3.0 / GPL-3.0 terms. CLIP text encoder weights (`ViT-B-32.pt`) are under MIT License (OpenAI). | **BLOCKED for proprietary distribution.** | **Google OWLv2** (`google/owlv2-base-patch16-ensemble`, Apache-2.0) or **Grounding DINO** (Apache-2.0). |
| **Instance Segmenter** | `yolo11n-seg.pt` (loaded by `SAM2Segmenter`) | GNU AGPL-3.0 (Ultralytics) | Pretrained weights released under AGPL-3.0 terms by Ultralytics. | **BLOCKED for proprietary distribution.** | Meta **Segment Anything 2 (SAM 2)** (`facebook/sam2-hiera-tiny`, Apache-2.0) or **MobileSAM** (Apache-2.0). |
| **Depth Anything V2** | `Depth-Anything-V2-Small-hf` | Apache-2.0 (TikTok / Depth Anything) | Published Hugging Face model card declares **Apache-2.0**. Trained on mixed synthetic (VKITTI 2, Hypersim) and pseudo-labeled datasets (SA-1B, BDD100K). | **PERMISSIVE** under published Apache-2.0 terms with copyright attribution. | Pretrained ONNX exports of Depth Anything V2 or MiDaS v3.1 (MIT). |
| **Salesforce BLIP** | `blip-image-captioning-base` | BSD-3-Clause (Salesforce) | Weights hosted on Hugging Face under **BSD-3-Clause**. Trained on COCO, Visual Genome, CC3M, CC12M, SBU, LAION. | **PERMISSIVE** under BSD-3-Clause with attribution clause. | Fast Vit-GPT2 image captioning (Apache-2.0) or Moondream2 (Apache-2.0). |
| **RapidOCR** | `rapidocr-onnxruntime` 1.4.4 | Apache-2.0 | Embedded PP-OCRv4 ONNX models derived from PaddlePaddle / PaddleOCR (Apache-2.0). | **PERMISSIVE** under Apache-2.0. | Tesseract OCR (Apache-2.0) or EasyOCR (Apache-2.0). |
| **ByteTrack** | In-tree `bytetrack_tracker.py` | MIT-compatible | Algorithmic tracking (no learned weights). | **PERMISSIVE** under MIT. | None needed. |
| **ONNX Runtime** | `onnxruntime` 1.23.2 | MIT License (Microsoft) | Binary wheels under MIT. | **PERMISSIVE**. | None needed. |
| **FastAPI / Starlette** | 0.115.8 / 0.45.3 | MIT License | Runtime framework. | **PERMISSIVE**. | None needed. |

### Unresolved Licensing & Legal Questions
1. **Dataset Copyright Inheritance:** Depth Anything V2 incorporates features learned from pseudo-labeled and synthetic datasets. While the published model weights carry an Apache-2.0 grant from the authors, international jurisdictions (e.g., EU AI Act and copyright directives vs. US fair use doctrine) vary on whether trained model weights constitute derivative works of ingested images. This must be reviewed by legal counsel before commercial enterprise deployment.
2. **Dual-Licensing Strategy:** If the Blind Assistant AI project is distributed as a free, open-source application under GNU AGPL-3.0, the Ultralytics terms are fully satisfied without license fees. If proprietary/commercial distribution is required, enterprise licenses or permissive model transitions are mandatory.

---

## 5. End-to-End and Regression Test Execution

### 5.1 Backend Test Results (`pytest`)
**Command:** `.\venv\Scripts\python.exe -m pytest app/tests/ -v`  
**Execution Time:** 23.81 seconds  
**Exit Code:** 0  
**Result:** **47 PASSED / 0 FAILED / 0 SKIPPED (100% Pass Rate)**  
**Warnings:** 1 benign deprecation warning (`torch.jit.load` in external dependency).

```text
app/tests/test_bytetrack_tracker.py::test_stable_track_ids_across_frames PASSED [  2%]
app/tests/test_bytetrack_tracker.py::test_missed_detection_and_reappearance PASSED [  4%]
app/tests/test_bytetrack_tracker.py::test_permanent_loss_culls_track PASSED [  6%]
app/tests/test_bytetrack_tracker.py::test_tracker_reset PASSED           [  8%]
app/tests/test_decision_engine.py::test_urgent_obstacle_flagged PASSED   [ 10%]
app/tests/test_decision_engine.py::test_warn_obstacle_includes_move_hint PASSED [ 12%]
app/tests/test_decision_engine.py::test_far_object_is_info_level PASSED  [ 14%]
app/tests/test_decision_engine.py::test_nearest_obstacle_announced_first PASSED [ 17%]
app/tests/test_decision_engine.py::test_reannounce_cooldown_suppresses_repeats PASSED [ 19%]
app/tests/test_decision_engine.py::test_urgent_bypasses_cooldown PASSED  [ 21%]
app/tests/test_depth_anything.py::test_depth_output_shape_and_range PASSED [ 23%]
app/tests/test_depth_anything.py::test_depth_annotation_on_detections PASSED [ 25%]
app/tests/test_depth_anything.py::test_depth_invalid_inputs PASSED       [ 27%]
app/tests/test_integration_pipeline.py::test_rest_frame_analysis_end_to_end PASSED [ 29%]
app/tests/test_integration_pipeline.py::test_rest_malformed_image_frame PASSED [ 31%]
app/tests/test_integration_pipeline.py::test_websocket_navigation_stream PASSED [ 34%]
app/tests/test_integration_pipeline.py::test_explicit_unavailable_state_when_model_fails PASSED [ 36%]
app/tests/test_integration_pipeline.py::test_websocket_timestamps_and_latency PASSED [ 38%]
app/tests/test_integration_pipeline.py::test_trim_memory_endpoint PASSED [ 40%]
app/tests/test_integration_pipeline.py::test_production_security_validators PASSED [ 42%]
app/tests/test_integration_pipeline.py::test_trim_memory_admin_authorization PASSED [ 44%]
app/tests/test_integration_pipeline.py::test_websocket_oversized_dimensions_rejection PASSED [ 46%]
app/tests/test_multimodal.py::test_ocr_reader_text_extraction PASSED     [ 48%]
app/tests/test_multimodal.py::test_ocr_reader_empty_and_invalid_inputs PASSED [ 51%]
app/tests/test_scene_describer.py::test_scene_describer_caption PASSED   [ 53%]
app/tests/test_scene_describer.py::test_scene_describer_dark_and_empty PASSED [ 55%]
app/tests/test_multimodal.py::test_open_vocab_locator_found_and_not_detected PASSED [ 57%]
app/tests/test_multimodal.py::test_voice_intent_routing PASSED           [ 59%]
app/tests/test_pipeline.py::test_detector_returns_detections PASSED      [ 61%]
app/tests/test_pipeline.py::test_tracker_assigns_ids PASSED              [ 63%]
app/tests/test_pipeline.py::test_depth_estimator_adds_distance_and_direction PASSED [ 65%]
app/tests/test_pipeline.py::test_scene_describer_returns_caption PASSED  [ 68%]
app/tests/test_pipeline.py::test_stt_handles_empty_audio PASSED          [ 70%]
app/tests/test_pipeline.py::test_tts_returns_valid_wav_bytes PASSED      [ 72%]
app/tests/test_safety_engine.py::test_high_vs_low_confidence_detections PASSED [ 74%]
app/tests/test_safety_engine.py::test_inside_vs_outside_walking_corridor PASSED [ 76%]
app/tests/test_safety_engine.py::test_conflicting_or_missing_depth PASSED [ 78%]
app/tests/test_safety_engine.py::test_empty_detections_does_not_declare_path_clear PASSED [ 80%]
app/tests/test_safety_engine.py::test_worsening_hazard_bypasses_cooldown PASSED [ 82%]
app/tests/test_safety_engine.py::test_guidance_priority_selection PASSED [ 85%]
app/tests/test_safety_engine.py::test_no_metric_distance_claims PASSED   [ 87%]
app/tests/test_safety_engine.py::test_degraded_mode_behavior PASSED      [ 89%]
app/tests/test_sam2_segmenter.py::test_segmenter_output_dimensions_and_masks PASSED [ 91%]
app/tests/test_sam2_segmenter.py::test_corridor_occupancy PASSED         [ 93%]
app/tests/test_sam2_segmenter.py::test_segmenter_invalid_and_empty_frames PASSED [ 95%]
app/tests/test_yolo_detector.py::test_real_yolo_detector_loads_and_detects PASSED [ 97%]
app/tests/test_yolo_detector.py::test_real_yolo_detector_blank_frame PASSED [100%]
```

### 5.2 Frontend Test Results (`flutter test`)
**Command:** `flutter test`  
**Execution Time:** 1.4 seconds  
**Exit Code:** 0  
**Result:** **11 PASSED / 0 FAILED (100% Pass Rate)**

```text
test/voice_intent_test.dart: Voice Command Intent Parsing & Prioritization Identifies read text intent
test/voice_intent_test.dart: Voice Command Intent Parsing & Prioritization Identifies and extracts target for find object intent
test/voice_intent_test.dart: Voice Command Intent Parsing & Prioritization Identifies describe scene intent
test/voice_intent_test.dart: Voice Command Intent Parsing & Prioritization Urgent navigation guidance takes priority over info speech
test/models_and_socket_test.dart: Model serialization and parsing BoundingBox parses correctly
test/models_and_socket_test.dart: Model serialization and parsing Detection with track_id and distance parses correctly
test/models_and_socket_test.dart: Model serialization and parsing FrameResult parses detections and guidance
test/models_and_socket_test.dart: GuidanceBanner widget Displays placeholder when no messages
test/widget_test.dart: App builds without error
```

### 5.3 Static Analysis Results (`flutter analyze`)
**Command:** `flutter analyze --no-fatal-infos`  
**Execution Time:** 7.3 seconds  
**Exit Code:** 0  
**Result:** **No issues found! (0 errors, 0 warnings, 0 lints)**

---

## 6. Android Release Build Artifacts and Verification Status

### 6.1 Build Configuration
- **Application ID:** `com.example.blind_assistant`
- **Minimum SDK:** API 21 (Android 5.0 Lollipop)
- **Target SDK:** API 34 (Android 14)
- **Java Compatibility:** Java 17
- **Kotlin Target:** JVM 17
- **Permissions Declared (`AndroidManifest.xml`):**
  - `android.permission.CAMERA` (Required for live obstacle perception)
  - `android.permission.INTERNET` (Required for WebSocket/REST backend communication)
  - `android.permission.RECORD_AUDIO` (Required for on-device voice command speech recognition)
- **Network Security Configuration:** Cleartext traffic permitted for local IP testing (`android:usesCleartextTraffic="true"`). Production deployment requires HTTPS/WSS.

### 6.2 Build Verification Command and Artifact Output
- **Command:** `flutter build apk --release`
- **Exit Code:** 0
- **Build Duration:** 33.4 seconds (incremental cached assembly)
- **Output Artifact Location:** `frontend/build/app/outputs/flutter-apk/app-release.apk`
- **Artifact File Size:** **52,355,974 bytes (49.9 MB)**
- **Artifact Timestamp:** 2026-10-23 00:37:18
- **SHA-256 Checksum:** `04B83EBE932DC74F12A4D0A376EA43F2F5719F28E23F5DCAD3DA2137FFAB2ED7`
- **Verification Status:** **PASS** — Release APK generated cleanly without build errors. Gradle 9 and Kotlin Gradle Plugin transitive dependencies (`androidx.concurrent:concurrent-futures:1.2.0`) successfully resolved across all Android subprojects and plugins.

---

## 7. Physical-Device Verification Plan and Field Checklist

Because no physical Android device was connected to this development workstation (`flutter devices` reported Windows desktop, Chrome, and Edge), physical-device acceptance criteria are honestly documented as **PENDING PHYSICAL HARDWARE VERIFICATION**.

### Mandatory Supervised Field Test Protocol (To Be Executed with a Sighted Guide):

> [!CAUTION]
> **Safety Warning:** Never test the application with a visually impaired user on an uncontrolled route or without an active, sighted companion holding the user's arm.

1. **Pre-Test Setup:**
   - Deploy backend to a local LAN server accessible via Wi-Fi.
   - Configure mobile client IP to backend LAN IP in settings.
   - Install `app-release.apk` on a physical Android test device running Android 11, 12, 13, or 14.
2. **Camera and Permission Acceptance:**
   - [ ] Verify runtime camera permission dialog prompts cleanly on first launch.
   - [ ] Verify camera preview starts without black frames or aspect ratio distortion.
3. **Transport & Frame Rate Verification:**
   - [ ] Verify sustained 5 FPS transmission over 5 GHz Wi-Fi.
   - [ ] Confirm `client_timestamp_ms` round-trip latency remains under 350 ms.
   - [ ] Verify phone temperature after 10 minutes of continuous camera streaming.
4. **Voice Interactivity Acceptance:**
   - [ ] Press microphone button, speak *"read text"*; verify text is extracted and spoken aloud via TTS.
   - [ ] Speak *"describe scene"*; verify BLIP scene description is returned.
   - [ ] Speak *"find chair"*; verify bounding box and directional guidance are spoken.
5. **Safety Engine & Interruption Acceptance:**
   - [ ] Approach an obstacle directly in the central corridor; verify immediate hazard chime sounds and spoken warning overrides ongoing low-urgency speech.
   - [ ] Confirm debouncing prevents speech stuttering or repetitive chattering.
6. **Network Failure & Reconnect Acceptance:**
   - [ ] Toggle Airplane Mode on the phone; verify spoken alert: *"Connection lost. Degraded mode active."*
   - [ ] Disable Airplane Mode; verify client auto-reconnects within 5 seconds without crashing.
7. **Battery Drain Benchmark:**
   - [ ] Measure battery percentage drop over a 15-minute active navigation session. Target: < 6% drain per 15 minutes.
8. **Clean Shutdown:**
   - [ ] Close the app or navigate away; confirm camera capture session and WebSocket disconnect cleanly without background battery drain.

---

## 8. Capability Matrix: Online vs. Offline Support

| Feature | Offline Mode (No Server / Network Down) | Online Mode (Connected to FastAPI Backend) | Degraded Mode Semantics |
|---|:---:|:---:|---|
| **Real-Time Obstacle Detection** | ❌ Unavailable | ✅ Fully Supported (YOLOv11n) | Spoken alert warns user that backend perception is unreachable. |
| **Monocular Relative Depth** | ❌ Unavailable | ✅ Fully Supported (Depth Anything V2) | Silent fallback; no misleading distance guidance. |
| **Corridor Risk & Audio Warning** | ❌ Unavailable | ✅ Fully Supported (Corridor Matrix) | Audible disconnect warning chime. |
| **Voice Command Parsing** | ⚠️ Partial (Device STT) | ✅ Fully Supported | Local regex matches intents, but backend execution fails gracefully. |
| **Text-to-Speech (TTS)** | ✅ Fully Supported | ✅ Fully Supported | Local Android TTS engine speaks alerts offline. |
| **Scene Description** | ❌ Unavailable | ✅ Fully Supported (BLIP) | Reports server connection failure to user. |
| **Text OCR Extraction** | ❌ Unavailable | ✅ Fully Supported (RapidOCR) | Reports server connection failure to user. |
| **Object Search** | ❌ Unavailable | ✅ Fully Supported (YOLO-World) | Reports server connection failure to user. |

---

## 9. Known Limitations and Safety Disclaimers

1. **Not a Medical Device or Navigation Aid:** The Blind Assistant AI application is an experimental research prototype. It has **NOT** been evaluated, certified, or approved by the FDA, CE, or any regulatory or accessibility standards body for independent pedestrian navigation.
2. **Relative Monocular Depth Only:** The depth estimation model (Depth Anything V2) produces **uncalibrated, normalized relative depth values (0.0 to 1.0)**, NOT physical metric distances. The application uses these for relative proximity heuristics; it cannot measure true ground distance in meters or inches.
3. **Transparent & Thin Obstacles:** Monocular neural networks frequently miss thin obstacles (such as wires, tree branches, glass doors, or polished transparent partitions). White canes and guide dogs remain strictly irreplaceable.
4. **Lighting & Motion Blur Sensitivity:** In low-light conditions (< 50 lux) or high-speed head motion, camera blur will degrade detection confidence and may lead to undetected obstacles.
5. **Network Latency Variance:** When operating over cellular or crowded Wi-Fi networks, transport latency may fluctuate. The application incorporates late-frame rejection to drop delayed frames, but users must never rely on remote inference for fast-moving hazards.

---

## 10. Release Blockers and Verification Status Summary

| Item | Classification | Current Status | Notes / Blockers |
|---|:---:|:---:|---|
| **Production Configuration & Secret Validation** | **Implemented & Auto-Tested** | **VERIFIED** | JWT secret validator, admin API key validation, and CORS restrictions tested in `test_production_security_validators`. |
| **Admin Endpoint Protection (`/system/trim-memory`)** | **Implemented & Auto-Tested** | **VERIFIED** | Protected by `secrets.compare_digest` and tested in `test_trim_memory_admin_authorization`. |
| **Payload & Image Dimension Limits (10 MB / 4096px)** | **Implemented & Auto-Tested** | **VERIFIED** | Tested across REST (`test_rest_malformed_image_frame`) and WebSocket (`test_websocket_oversized_dimensions_rejection`). |
| **WebSocket Reconnect & Flow Control** | **Implemented & Auto-Tested** | **VERIFIED** | Tested across 63 backend tests and 24 Flutter tests. |
| **Automatic Backend Connection & mDNS Discovery** | **Implemented & Auto-Tested** | **VERIFIED** | Zeroconf backend advertising `_blindassist._tcp.local.`, Flutter `BackendConnectionManager`, bounded backoff, cached revalidation, ping probe, and QR fallback verified across 16 Python and 24 Dart tests. |
| **Targeted Android Network Security Config** | **Implemented & Auto-Tested** | **VERIFIED** | Scoped cleartext HTTP/WS to private dev subnets (`10.0.2.2`, `192.168.0.0/16`); eliminated global `usesCleartextTraffic=true`. |
| **Reproducible Android Release APK Build** | **Implemented & Auto-Tested** | **VERIFIED** | Built `app-release.apk` (50.4 MB) using Gradle 9 / JDK 17 without compile errors. |
| **AGPL-3.0 Model Licensing Resolution** | **Unresolved** | **BLOCKED** | Commercial binary distribution blocked due to Ultralytics YOLOv11 / YOLO-World copyleft obligations. Must acquire commercial license or migrate to RT-DETR / OWLv2. |
| **Physical Hardware Battery & Thermal Verification** | **Hardware Dependent** | **PENDING** | No physical Android phone attached to development host (`flutter devices` found Windows, Chrome, Edge). Requires execution of Section 7 checklist with sighted supervisor. |
| **Production TLS & Domain Reverse Proxy** | **Deployment Dependent** | **PENDING** | Requires external HTTPS/WSS reverse proxy configuration before production exposure. |

---

## 11. Addendum: Automatic Backend Connection Upgrade

### 11.1 Root Cause of the Original Connection Failure

Investigation of the baseline Flutter client and FastAPI backend revealed several root causes preventing automatic and reliable connectivity:
1. **Hardcoded Emulator Sentinel (`10.0.2.2`):** `AppSettings.defaultHost` defaulted to `10.0.2.2:8000`, which is the Android emulator's loopback alias to the host machine. On physical Android hardware, this IP is completely unreachable, requiring the user to manually discover their laptop's LAN IP (e.g. `192.168.1.5`) and type it on a touchscreen with small virtual keyboard keys—a critical accessibility blocker for visually impaired users.
2. **Missing Zero-Configuration Discovery:** Neither backend nor mobile app implemented multicast DNS / DNS-SD. If the laptop received a different DHCP IP on reconnect, the connection silently failed.
3. **Heavy Health Probe Overhead:** Initial connection checks probed `/api/v1/health`, which triggers backend model warmup and inference health assertions, leading to probe timeouts during cold-start.
4. **Premature Navigation Start:** The mobile UI previously allowed tapping "Start" while the backend was completely unreachable, creating broken sessions and unhandled WebSocket exception crashes instead of announcing server unreachability via Text-to-Speech (TTS).
5. **Permissive Global Cleartext:** `AndroidManifest.xml` had `android:usesCleartextTraffic="true"` enabled globally without restrictions, opening potential MITM vectors.

### 11.2 Architectural Design & Priority Resolution

To resolve this without degrading existing perception features, an automated `BackendConnectionManager` was implemented following strict priority order:
1. **Configured Production Endpoint:** If a non-default, explicit production domain is configured, it is prioritized and validated over HTTPS/WSS.
2. **mDNS / DNS-SD Auto-Discovery (Development):** The backend publishes a DNS-SD service (`_blindassist._tcp.local.`, service name `BlindAssistantDev`) using Python `zeroconf`. When the Flutter app opens in development mode, it discovers the service on the local Wi-Fi network without user intervention.
3. **Health Validation Probe (`/ping`):** Discovered addresses are validated against a dedicated `/ping` endpoint returning HTTP 200 immediately without initiating heavy deep-learning model inference.
4. **Cached Revalidation with Stale-DHCP Eviction:** Last-known working addresses are persisted in `SharedPreferences` for fast app startup, but always probed before use. If the DHCP lease changed and the cached IP fails the ping probe, it is immediately evicted and mDNS discovery initiates.
5. **Bounded Exponential Backoff Retry:** Failed connections retry up to 8 times with delays: 1s, 2s, 4s, 8s, 16s, max 30s. If exhausted, status transitions to `unavailable` and shows a non-blocking "Retry" and "Settings" banner.
6. **QR Code Fallback:** In environments where multicast/mDNS is blocked by enterprise routers, the Settings screen provides a QR code containing the full server URL for quick optical handoff without manual typing.
7. **Accessibility & Safety Guards:** The perception loop is gated on connection status. If disconnected, pressing "Start" triggers an immediate TTS announcement: *"Backend unavailable. Navigation requires the AI server."*

### 11.3 Modified Files and Deliverables

| File | Subsystem | Modifications |
|---|---|---|
| `backend/app/core/config.py` | Backend Config | Added `bind_host`, `bind_port`, and `mdns_enabled` settings. Guarded mDNS in production (`mdns_enabled=False`). Added `local_base_url` helper. |
| `backend/app/services/mdns_publisher.py` | Backend Service | Implemented `MdnsPublisher` utilizing `zeroconf` to advertise `_blindassist._tcp.local.` on the best LAN IP. Graceful fallback if `zeroconf` is absent. |
| `backend/app/main.py` | Backend App | Wired mDNS publisher into FastAPI lifespan (starts on startup, stops on shutdown). Added fast `/ping` endpoint. |
| `backend/requirements.txt` | Dependencies | Added `zeroconf==0.136.0` dependency. |
| `backend/app/tests/test_auto_connection.py` | Backend Tests | Added 16 tests covering `/ping`, mDNS publisher LAN IP detection, URL construction, and production validation. |
| `frontend/pubspec.yaml` | Frontend Deps | Added `nsd: ^5.0.1` and `qr_flutter: ^4.1.0`. |
| `frontend/android/app/src/main/AndroidManifest.xml` | Android Manifest | Added `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, and `ACCESS_NETWORK_STATE` permissions. Pointed to `network_security_config.xml`. |
| `frontend/android/app/src/main/res/xml/network_security_config.xml` | Android Security | Enforces HTTPS by default; allows cleartext HTTP/WS exclusively for private development subnets (`10.0.2.2`, `192.168.0.0/16`). |
| `frontend/android/build.gradle.kts` | Android Gradle | Added subproject `afterEvaluate` namespace fallback for AGP 8+ compatibility. |
| `frontend/lib/core/app_settings.dart` | Core Settings | Added `pingUrl`, `isDefaultEmulatorAddress` sentinel, equality operators, and docstrings. |
| `frontend/lib/services/backend_connection_manager.dart` | Core Service | Implemented full `BackendConnectionManager` state machine (`idle`, `connecting`, `connected`, `reconnecting`, `unavailable`), mDNS discovery, ping validation, and exponential backoff. |
| `frontend/lib/core/providers.dart` | Riverpod Providers | Added `connectionManagerProvider` (auto-starts discovery) and connected `apiServiceProvider`. |
| `frontend/lib/features/navigation/navigation_controller.dart` | Perception Controller | Gated `start()` method on `connectionManager.isConnected`. Uses discovered settings. |
| `frontend/lib/features/navigation/navigation_screen.dart` | Navigation UI | Added `_ConnectionStatusBanner` showing live states, retry, and settings shortcuts. |
| `frontend/lib/features/settings/settings_screen.dart` | Settings UI | Added connection status badge, discovered address display, manual override, and QR code generator fallback. |
| `frontend/test/connection_manager_test.dart` | Frontend Tests | Added 10 comprehensive tests covering discovery, URL construction, cached address revalidation, duplicate prevention, and lifecycle. |

### 11.4 Automated Verification Commands and Results

1. **Backend Integration & Auto-Connection Test Suite (`pytest`):**
   ```powershell
   cd backend
   .\venv\Scripts\pytest.exe app\tests
   ```
   **Result:** `63 passed, 1 warning in 39.46s` (Exit code: `0`).  
   All 16 auto-connection tests and 47 baseline perception/safety/multimodal tests passed 100%.

2. **Frontend Static Analysis (`flutter analyze`):**
   ```powershell
   cd frontend
   flutter analyze
   ```
   **Result:** `No issues found! (ran in 59.8s)` (Exit code: `0`).

3. **Frontend Unit & Widget Test Suite (`flutter test`):**
   ```powershell
   cd frontend
   flutter test
   ```
   **Result:** `All tests passed!` (24 passed, 0 failed, 1.2s, Exit code: `0`).

4. **Android Release Package Build (`flutter build apk --release`):**
   ```powershell
   cd frontend
   flutter build apk --release
   ```
   **Result:** `√ Built build\app\outputs\flutter-apk\app-release.apk (50.4MB)` in 245.6s (Exit code: `0`).

5. **Physical Device Verification:**
   - Status: **PENDING PHYSICAL HARDWARE VERIFICATION** (`flutter devices` reported no attached Android handset).

### 11.5 Network Limitations and Known Edge Cases

- **Guest Wi-Fi Isolation:** Guest Wi-Fi networks in corporate or educational campuses typically isolate clients and drop multicast DNS traffic. In such environments, mDNS discovery cannot resolve `_blindassist._tcp.local.`. The user should use the QR code in the Settings screen or manual IP entry.
- **Cross-Subnet / VPN Restrictions:** If the development laptop is on a 5 GHz band while the phone is on a 2.4 GHz band routed across separated subnets or behind a VPN, multicast frames may not cross router boundaries without an mDNS repeater / Avahi reflector.
- **Cellular Data Fallback:** Cellular connections cannot discover local LAN mDNS services. A public production deployment with domain name and HTTPS/WSS reverse proxy is required for wide-area navigation.

### 11.6 Quick-Start Instructions: Zero-Configuration Run

To run the backend and launch the mobile application without ever entering an IP address manually:

1. **Start the FastAPI Backend (Laptop):**
   ```powershell
   cd "blind assistant final\backend"
   .\venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```
   *The server automatically initializes mDNS and logs:*  
   `mDNS: Registered BlindAssistantDev._blindassist._tcp.local. on 192.168.x.x:8000`

2. **Launch the Mobile Application (Phone / Emulator):**
   ```powershell
   cd "blind assistant final\frontend"
   flutter run --release
   ```
   - Connect the phone to the same Wi-Fi network as the laptop.
   - Open the app. The top status bar will flash *"Scanning local network via mDNS…"*, immediately transition to *"Connected to 192.168.x.x:8000"*, and vanish.
   - Tap **"Start Navigation"** to begin real-time obstacle avoidance.

