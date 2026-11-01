# Blind Assistant AI — Flutter Android Frontend

Voice-first assistive mobility aid: live on-device YOLO obstacle perception, calibrated monocular directional guidance, on-demand OpenStreetMap nearby-place discovery, and optional OSRM walking routes.

---

## 1. Core Architecture & Highlights

- **100% Offline Primary Navigation:** Executes locally on your Android phone using TensorFlow Lite (`yolo11n_float16.tflite`). Does not require internet, Wi-Fi, cellular, or server connections.
- **Calibrated Monocular Distance:** Uses pinhole camera geometry ($D = \frac{f_y \cdot H_{\text{real}}}{h_{\text{bbox}}}$) with real-world height priors and strict uncertainty rejection. If bounding boxes are truncated or geometry is ambiguous, distance is marked as unknown (`[dist: unk]`) rather than guessing numbers.
- **Single Coordinated Speech Queue:** `TtsService` serializes all speech into a single FIFO queue with urgent hazard preemption, pending update coalescing, and deadlock recovery watchdog (6.0s).
- **Nearby Place Discovery (100% Free & Open-Source):** OpenStreetMap Overpass client supporting Restaurants, Hospitals, Clinics, Pharmacies, Bus Stops, Railway/Train Stations, Petrol/Gas Stations, Shops, Cafes, Groceries, and Banks/ATMs.
- **Interactive Map & Accessible List:** `flutter_map` with OpenStreetMap tile rendering, user location pin, place markers, and accessible touch targets.
- **Optional OSRM Pedestrian Routing:** Free Open Source Routing Machine (OSRM) foot routing providing true walking distance, estimated walk duration, and maneuver steps.
- **Runtime Permissions & Accessibility:** High-contrast dark UI, Red STOP banner for imminent obstacles, screen reader semantics (TalkBack), and spoken recovery for denied/permanently denied camera, microphone, and location permissions.

---

## 2. Quick Start Commands

From `c:\Blind-Asst-object-detection\frontend`:

```powershell
# 1. Fetch dependencies
flutter pub get

# 2. Static analysis (0 issues)
flutter analyze
# Or run Dart analyzer directly:
dart analyze

# 3. Automated test suite (All 118 tests pass)
flutter test

# 4. Build debug APK
flutter build apk --debug
```

The compiled APK will be located at:
`c:\Blind-Asst-object-detection\frontend\build\app\outputs\flutter-apk\app-debug.apk`

---

## 3. Physical Device Installation

1. Connect your Android phone via USB and enable **USB Debugging** in Developer Options.
2. Verify connection:
   ```powershell
   adb devices
   ```
3. Install the APK:
   ```powershell
   adb install -r "build\app\outputs\flutter-apk\app-debug.apk"
   ```
4. Or launch directly with live hot-reload:
   ```powershell
   flutter run -d <your_device_id>
   ```

---

## 4. Connecting to the Optional FastAPI Server

The app defaults to `10.0.2.2:8000` (Android emulator loopback) and supports automatic mDNS discovery on LAN (`_blindassist._tcp.local.`).

To use optional cloud features (BLIP captioning, RapidOCR text reading, YOLO-World search):
```bash
cd ../backend
uvicorn app.main:app --host 0.0.0.0 --port 8000
```
Change host in the app's Settings screen if using a physical phone on LAN (`192.168.x.x`).

---

## 5. Comprehensive Documentation Index

- [System Architecture](file:///c:/Blind-Asst-object-detection/docs/ARCHITECTURE.md)
- [Installation & Deployment Guide](file:///c:/Blind-Asst-object-detection/docs/INSTALLATION_GUIDE.md)
- [Android Permission & Security Guide](file:///c:/Blind-Asst-object-detection/docs/ANDROID_PERMISSION_GUIDE.md)
- [API Configuration & Fair Use Guide](file:///c:/Blind-Asst-object-detection/docs/API_CONFIGURATION.md)
- [Physical Device Testing Guide](file:///c:/Blind-Asst-object-detection/docs/DEVICE_TESTING_GUIDE.md)
- [Known Limitations & Roadmap](file:///c:/Blind-Asst-object-detection/docs/KNOWN_LIMITATIONS.md)
- [Project Audit](file:///c:/Blind-Asst-object-detection/PROJECT_AUDIT.md)
- [Implementation Plan](file:///c:/Blind-Asst-object-detection/IMPLEMENTATION_PLAN.md)
- [Feature Completion Checklist](file:///c:/Blind-Asst-object-detection/FEATURE_COMPLETION_CHECKLIST.md)
