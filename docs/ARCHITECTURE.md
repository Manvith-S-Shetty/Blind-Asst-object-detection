# Blind Assistant AI — System Architecture & Technical Specifications

**Version:** 2.0  
**Date:** November 2026  
**Target Environment:** Android 11+ (API Level 21–34)  
**Primary Framework:** Flutter 3.47+ / Dart 3.13+  

---

## 1. High-Level Architectural Vision

**Blind Assistant AI** is an offline-first assistive mobility aid designed for blind and low-vision individuals. The architecture decouples local perception from remote cloud services:

```
+-----------------------------------------------------------------------------------+
|                                 ANDROID DEVICE                                    |
|                                                                                   |
|  +--------------------+     +--------------------------------------------------+  |
|  |   Camera Preview   | --> |                LocalDetector                     |  |
|  |  (Camera2 YUV420)  |     |  - YOLO11n FP16 TFLite (640x640)                 |  |
|  +--------------------+     |  - Greedy Per-Class NMS (IoU 0.45)               |  |
|                             |  - Cross-Class Suppression (IoU 0.65)            |  |
|                             +--------------------------------------------------+  |
|                                                      |                            |
|                                                      v                            |
|                             +--------------------------------------------------+  |
|                             |           MonocularDistanceEstimator             |  |
|                             |  - Pinhole Camera Geometry (D = f_y * H / h)     |  |
|                             |  - Physical Height Priors                        |  |
|                             |  - Edge Truncation & Aspect Ratio Rejection      |  |
|                             +--------------------------------------------------+  |
|                                                      |                            |
|                                                      v                            |
|                             +--------------------------------------------------+  |
|                             |              LocalGuidanceEngine                 |  |
|                             |  - Temporal IoU Object Tracking                  |  |
|                             |  - EMA Distance Smoothing                        |  |
|                             |  - Direction Hysteresis & Path Corridor          |  |
|                             |  - 6-Tier Priority Hazard Ranking                |  |
|                             +--------------------------------------------------+  |
|                                                      |                            |
|  +--------------------+                              v                            |
|  | VoiceCommandButton |     +--------------------------------------------------+  |
|  | (STT Confirmation) | --> |                  TtsService                      |  |
|  +--------------------+     |  - Serialized Single FIFO Queue                  |  |
|             |               |  - Urgent Hazard Preemption                      |  |
|             |               |  - Guidance Coalescing & Stale Job Purging       |  |
|             v               |  - Deadlock Recovery Watchdog (6.0s)             |  |
|  +--------------------+     +--------------------------------------------------+  |
|  | PlaceIntentParser  |                              ^                            |
|  +--------------------+                              |                            |
|             |                                        |                            |
|             v                                        |                            |
|  +--------------------+     +------------------------+-------------------------+  |
|  |  LocationService   | --> |             PlacesController & UI                |  |
|  |   (GPS On-Demand)  |     |  - PlacesScreen (flutter_map + OSM Tiles)        |  |
|  +--------------------+     |  - Overpass PlacesClient (5m Cache, Rate Limits) |  |
|                             |  - OSRM RoutingService (Free Walking Directions) |  |
|                             +--------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
                                       | (Optional WebSocket / REST)
                                       v
                     +-----------------------------------+
                     |       Optional FastAPI Server     |
                     |  - LAN mDNS Discovery             |
                     |  - BLIP Scene Captioning          |
                     |  - RapidOCR Text Reading          |
                     |  - YOLO-World Open Vocabulary     |
                     +-----------------------------------+
```

---

## 2. Core Subsystems

### 2.1 On-Device Object Perception (`LocalDetector`)
- **TFLite Engine:** Runs `assets/models/yolo11n_float16.tflite` directly via `tflite_flutter: ^0.12.1`.
- **Input Tensor:** Shape `[1, 640, 640, 3]`, Float32 normalized `/ 255.0` in RGB color space.
- **Output Tensor:** Shape `[1, 84, 8400]`, where 84 channels represent $[c_x, c_y, w, h]$ plus 80 COCO class probability scores across 8,400 anchors.
- **Letterbox Transformations:** Resizes incoming frames while maintaining aspect ratio, calculating padding deltas (`dw`, `dh`) to invert bounding box coordinates back to full camera resolution without geometric distortion.
- **Suppression:**
  1. *Per-Class Greedy NMS:* Eliminates multi-scale duplicate anchor firings for the same physical object ($IoU \ge 0.45$).
  2. *Cross-Class Suppression:* Resolves class ambiguities (e.g., model wavering between `chair` and `couch` on an armchair) by retaining the higher-confidence candidate when $IoU \ge 0.65$.

### 2.2 Calibrated Monocular Distance Estimation (`MonocularDistanceEstimator`)
- **Hardware Boundary:** Mobile preview streams do not expose hardware depth sensor channels.
- **Pinhole Geometry:**
  $$\text{Distance} = \frac{f_y \cdot H_{\text{real}}}{h_{\text{bbox\_px}}}$$
  Where:
  - $f_y = \frac{H_{\text{image}}}{2 \cdot \tan(\text{VFOV} / 2)} \approx 0.96 \cdot H_{\text{image}}$ for typical smartphone cameras ($VFOV \approx 55^\circ$).
  - $H_{\text{real}}$: Calibrated physical height prior (e.g., adult human = 1.70m, chair = 0.85m, dining table = 0.75m).
- **Uncertainty Gating:**
  If an obstacle touches the frame borders ($y_1 \le 4\text{px}$ or $y_2 \ge H - 4\text{px}$), has an abnormal aspect ratio (e.g. crouching person), is an uncalibrated class, or falls outside the reliable range (0.5m–6.0m), `distanceMeters` is strictly set to `null` (`[dist: unk]`). The system **never** invents numbers.

### 2.3 Priority Hazard Guidance (`LocalGuidanceEngine`)
- **Corridor Partitioning:**
  - `Left`: $X_{\text{center}} < 0.33 \cdot W_{\text{image}}$
  - `Center`: $0.33 \cdot W_{\text{image}} \le X_{\text{center}} \le 0.67 \cdot W_{\text{image}}$
  - `Right`: $X_{\text{center}} > 0.67 \cdot W_{\text{image}}$
  - `inPath`: Center direction OR bounding box overlap with central path ($x_1 < 0.65W$ and $x_2 > 0.35W$).
- **Priority Tiers:**
  - Tier 0: Immediate forward path hazard ($\le 1.5\text{m}$ or imminent in path).
  - Tier 1: Immediate flank hazard ($\le 1.5\text{m}$ on sides).
  - Tier 2: Potential forward hazard ($1.5 - 2.5\text{m}$ in path).
  - Tier 3: Potential flank hazard ($1.5 - 2.5\text{m}$ on sides).
  - Tier 4: Forward awareness ($> 2.5\text{m}$ in path).
  - Tier 5: Flank awareness ($> 2.5\text{m}$ on sides).
- **Approach Escalation:** If an obstacle moves $\ge 0.5\text{m}$ closer, it bypasses the 5-second cooldown and warns the user immediately.
- **Safety Directive:** When 0 obstacles are detected, the guidance engine outputs empty instructions. It **never** announces that the path is "safe" or "clear".

### 2.4 Coordinated Audio Queue (`TtsService`)
- Enforces strict single-utterance serialization.
- Genuinely urgent hazard warnings preempt lower-priority speech and clear the pending queue.
- Routine updates and voice query responses cannot interrupt an active urgent hazard warning unless commanded by explicit user action.
- Automatic queue watchdog (6.0 seconds) ensures the queue never hangs if native TTS engines drop callbacks.

### 2.5 Free & Open-Source Nearby Place Discovery
- **Provider:** OpenStreetMap Overpass API interpreter (`https://overpass-api.de/api/interpreter`).
- **Zero Credentials:** 100% free and open, zero API keys, zero subscriptions.
- **Rate-Limiting & Caching:** In-memory caching with 5-minute TTL and 2-second rate-limiting cooldown.
- **Categories:** Restaurants, Hospitals, Clinics, Pharmacies, Bus Stops, Railway Stations, Petrol Stations, Shops, Cafes, Groceries, Banks/ATMs.
- **Optional Routing:** Open Source Routing Machine (OSRM) Foot Routing API (`https://router.project-osrm.org`) providing walking polylines and step maneuvers, clearly declared as experimental pedestrian estimates.

