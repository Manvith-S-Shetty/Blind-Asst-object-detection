# Blind Assistant AI: Assistive Navigation & Object Perception System

**Version:** 2.0  
**Target Environment:** Android 11+ Mobile (minSdk 21, targetSdk 34)  
**Primary Framework:** Flutter 3.47+ / Dart 3.13+  
**AI / ML Engine:** TensorFlow Lite On-Device YOLO11n (`yolo11n_float16.tflite`, FP16)  

---

## 1. Project Overview

**Blind Assistant AI** is an open-source assistive mobility prototype engineered for blind and low-vision individuals. It provides:
1. **100% Offline On-Device Object Perception:** Real-time obstacle detection using a quantized YOLOv11 nano model on TensorFlow Lite.
2. **Calibrated Monocular Direction & Distance:** Pinhole camera geometry model with real-world height priors and strict uncertainty gating (`[dist: unk]` when geometric assumptions are violated; never fabricates numbers).
3. **Single Coordinated Voice Queue:** Serialized FIFO speech queue via `TtsService` with urgent hazard preemption, pending frame guidance coalescing, deduplication, and a 6-second deadlock recovery watchdog.
4. **On-Demand Nearby Place Search:** 100% free and open-source geographical discovery via OpenStreetMap Overpass API (Restaurants, Hospitals, Clinics, Pharmacies, Bus Stops, Train/Metro Stations, Petrol Stations, Cafes, Groceries, ATMs).
5. **Interactive Map & OSRM Pedestrian Routing:** `flutter_map` with OpenStreetMap tile rendering, user location pin, place markers, and optional walking route polylines and maneuvers via Open Source Routing Machine (OSRM).
6. **Optional FastAPI Companion Server:** For developer telemetry, mDNS LAN auto-discovery, and cloud multimodal features (BLIP scene captioning, RapidOCR text reading, YOLO-World open-vocabulary search).

---

## 2. Repository Layout

```text
C:\Blind-Asst-object-detection\
├── backend/                              # Optional FastAPI companion server
│   ├── app/                              # REST & WebSocket endpoints, mDNS, pipeline
│   ├── requirements.txt                  # Python dependencies
│   ├── evaluate_detector.py              # Precision, recall, and tensor evaluation script
│   └── verify_models.py                  # TFLite model shape and quantization verifier
├── data/                                 # Indoor obstacle evaluation datasets & frames
├── docs/                                 # Comprehensive technical documentation
│   ├── ARCHITECTURE.md                   # System architecture and pipeline specifications
│   ├── INSTALLATION_GUIDE.md             # Complete build and deployment steps
│   ├── ANDROID_PERMISSION_GUIDE.md       # Runtime permission design & recovery
│   ├── API_CONFIGURATION.md              # OpenStreetMap & OSRM free service configurations
│   ├── DEVICE_TESTING_GUIDE.md           # 17-step physical device test protocol
│   └── KNOWN_LIMITATIONS.md              # Assistive boundaries, safety rules & roadmap
├── frontend/                             # Flutter Android Application
│   ├── android/                          # Native Android Gradle configuration
│   ├── assets/models/                    # YOLOv11n TFLite models & labels
│   │   ├── yolo11n_float16.tflite        # Optimized 5.4MB FP16 quantized model
│   │   └── labels.txt                    # 80 COCO category taxonomy
│   ├── lib/
│   │   ├── core/                         # Routing, theme, app settings, Riverpod providers
│   │   ├── features/
│   │   │   ├── navigation/               # Camera preview, bounding boxes, STOP hazard banner
│   │   │   ├── places/                   # Nearby places screen, OSM map, category chips
│   │   │   ├── settings/                 # Host/port settings, mDNS status, QR code pairing
│   │   │   └── voice/                    # Voice command microphone button & intent routing
│   │   ├── models/                       # Detection, BoundingBox, Guidance, PlaceResult
│   │   └── services/                     # LocalDetector, DistanceEstimator, GuidanceEngine,
│   │                                     # TtsService, LocationService, PlacesClient, RoutingService
│   ├── test/                             # 118 automated unit and widget tests (100% passing)
│   └── pubspec.yaml                      # Dependencies & asset declarations
├── PROJECT_AUDIT.md                      # Comprehensive codebase audit
├── IMPLEMENTATION_PLAN.md                # 15-phase master implementation plan
└── FEATURE_COMPLETION_CHECKLIST.md       # Master engineering verification checklist
```

---

## 3. Quick Verification Commands

From `c:\Blind-Asst-object-detection\frontend`:

```powershell
# Verify zero static analysis issues
dart analyze
# Or via Flutter:
flutter analyze

# Run full automated test suite (All 118 tests passing)
flutter test

# Build debug APK
flutter build apk --debug
```

**Compiled APK Location:**  
`c:\Blind-Asst-object-detection\frontend\build\app\outputs\flutter-apk\app-debug.apk` (215 MB)

---

## 4. Physical Android Phone Installation

1. Connect your Android phone via USB and enable **USB Debugging** in Developer Options.
2. Install the APK:
   ```powershell
   adb install -r "frontend\build\app\outputs\flutter-apk\app-debug.apk"
   ```
3. Follow the detailed 17-step testing protocol in [docs/DEVICE_TESTING_GUIDE.md](file:///c:/Blind-Asst-object-detection/docs/DEVICE_TESTING_GUIDE.md).

---

## 5. Assistive Safety Disclaimer

> [!CAUTION]
> **CRITICAL MOBILITY NOTICE:**  
> This software is an experimental assistive research prototype. **It is NOT certified as safe for use as a sole mobility aid or primary navigation tool.** It must NEVER replace traditional orientation aids such as a white cane, guide dog, or attentive human companion. Obstacle detection is monocular and probabilistic; stairs, curbs, drop-offs, transparent glass, or fast-moving hazards may not be detected in time.

