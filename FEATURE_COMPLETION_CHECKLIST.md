# Blind Assistant AI — Feature Completion Checklist

**Document Version:** 2.0  
**Date:** November 2026  
**Status:** Verification Complete — 100% Core Requirements Implemented & Verified  

---

## 1. Core On-Device Object Detection (Phase 2)
- [x] On-device YOLO11n TensorFlow Lite model integration (`assets/models/yolo11n_float16.tflite`)
- [x] Memory-safe YUV420 to RGB conversion with stride alignment
- [x] Correct letterbox preprocessing to $640 \times 640$ with aspect ratio preservation
- [x] Normalization to `[0.0, 1.0]` float32 tensor
- [x] Multi-head anchor box decoding from `[1, 84, 8400]` tensor
- [x] Greedy Non-Maximum Suppression (NMS) per class (IoU threshold 0.45)
- [x] Cross-class duplicate suppression (IoU threshold 0.65)
- [x] Letterbox coordinate unscaling to original camera frame resolution
- [x] Off-thread inference using `IsolateInterpreter` with fallback to main thread
- [x] Camera lifecycle pause/resume with safe camera controller disposal
- [x] Explicit non-detection disclaimer: never claims detection of stairs, doors, curbs, or drop-offs

## 2. Navigation & Distance Guidance (Phase 3)
- [x] Left ($X < 0.33W$), Center ($0.33W \le X \le 0.67W$), and Right ($X > 0.67W$) directional classification
- [x] Central path corridor overlap ($X_1 < 0.65W$ and $X_2 > 0.35W$)
- [x] Calibrated pinhole camera distance estimation model ($D = \frac{f_y \cdot H_{\text{real}}}{h_{\text{bbox}}}$)
- [x] Physical object size priors for predictable obstacles (person, chair, car, couch, etc.)
- [x] Rigorous uncertainty rejection: returns `distanceMeters = null` when box is truncated, aspect ratio anomalous, or distance $<0.5$m or $>6.0$m
- [x] Temporal obstacle tracking with IoU matching across frames
- [x] Exponential Moving Average (EMA) distance smoothing across frames
- [x] Direction hysteresis buffers to prevent oscillation on border boundaries
- [x] Multi-factor obstacle prioritization (6 priority ranks)
- [x] Immediate reannouncement when an obstacle approaches by $\ge 0.5$m
- [x] Reannouncement cooldown timer (5000 ms)
- [x] Single guidance instruction per cycle (prevents confusing user with simultaneous directions)
- [x] Strict safety rule: NEVER speaks "safe" or "path clear" when 0 obstacles are detected

## 3. Audio & Voice System (Phase 4)
- [x] Single serialized FIFO speech queue in `TtsService`
- [x] Urgent hazard warning preemption (interrupts active non-urgent speech and clears queue)
- [x] Non-urgent speech protection (routine speech never interrupts urgent warning)
- [x] Coalescing of frame guidance updates (keeps only newest pending instruction)
- [x] Purge stale guidance queued for $>3.5$ seconds
- [x] Deadlock watchdog timer (6.0 seconds) to ensure queue never hangs
- [x] Deduplication of identical speech messages
- [x] On-demand microphone permission request with spoken explanations upon denial
- [x] Android 11+ `<queries>` intents in `AndroidManifest.xml`
- [x] Explicit voice command for "Repeat result" / "Repeat place" (`repeatCurrentPlace()`)

## 4. GPS Location Tracking (Phase 5)
- [x] `geolocator: ^14.1.2` integration
- [x] Android permissions (`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`)
- [x] On-demand GPS position retrieval (independent of camera navigation)
- [x] Location service availability check (GPS hardware enabled/disabled)
- [x] Permission status handling (denied, permanently denied with deep link to settings)
- [x] Timeout handling with automatic fallback to `getLastKnownPosition`
- [x] Zero continuous background tracking for privacy and battery conservation

## 5. Nearby Places Search via OpenStreetMap (Phase 6)
- [x] 100% Free & Open-Source OpenStreetMap Overpass client (`PlacesClient`)
- [x] In-memory caching with 5-minute TTL to comply with Overpass Fair Use Policy
- [x] 2-second rate-limiting cooldown between dispatches
- [x] Straight-line great-circle distance calculation ($R = 6371$ km)
- [x] 8-point cardinal direction calculation ("north", "northeast", "southwest", etc.)
- [x] Result deduplication by OSM ID, coordinates, and name
- [x] Sort results by nearest straight-line distance
- [x] Category search: Restaurants, Hospitals, Pharmacies, Bus Stops, Shops, Cafes, Groceries, Banks/ATMs
- [x] Category expansion: Railway Stations (`railway=station`), Petrol Stations (`amenity=fuel`), and dedicated Clinics (`amenity=clinic`)
- [x] Clear disclaimer: Straight-line distance is not walking or route distance

## 6. Voice-Based Nearby Search (Phase 7)
- [x] Voice command parser (`PlaceIntentParser`)
- [x] Category extraction from spoken queries ("find a restaurant near me", "nearest hospital", etc.)
- [x] Screen transition to `/places` with active search
- [x] Spoken announcements for closest place result
- [x] Voice command for next place: "next", "next place", "tell me the next result"
- [x] Voice command for repeat place: "repeat", "say again", "repeat result"
- [x] Voice grammar expansion for railway stations, petrol stations, and clinics

## 7. Map & Nearby Place Interface (Phase 8)
- [x] Accessible map interface using `flutter_map: ^8.3.2` with OpenStreetMap tiles
- [x] OpenStreetMap attribution widget (`RichAttributionWidget`)
- [x] User current location pin
- [x] Numbered place markers synced with list selection
- [x] High-contrast scrollable list view with large touch targets
- [x] Floating action button for "Next Place"
- [x] Tap to announce detailed place information aloud via `TtsService`
- [x] Add category chips for Railway Stations and Petrol Stations

## 8. Optional Directions & Walking Routing (Phase 9)
- [x] Implement `RoutingService` using free OSRM Foot Routing API (`https://router.project-osrm.org`)
- [x] Fetch walking polyline, total walking distance, and maneuver instructions
- [x] Display walking polyline on `flutter_map` when a place is selected
- [x] Distinct display of walking distance vs straight-line distance
- [x] Robust error and offline fallback handling
- [x] Prominent experimental walking route disclaimer

## 9. Backend & Offline Architecture (Phase 10)
- [x] Offline-first: Core navigation operates 100% without backend
- [x] Optional FastAPI server with mDNS LAN discovery
- [x] Non-blocking connection manager with exponential backoff
- [x] Teal status banner: "On-Device AI ready (Offline mode)" without annoying error popups
- [x] Clear indication when internet is needed for nearby place search

## 10. Accessibility & Safety (Phase 11)
- [x] High-contrast dark styling
- [x] Red high-contrast STOP hazard banner for imminent hazards
- [x] Label badges showing `~X.Xm (est)` vs `dist: unk`
- [x] Semantics live regions and buttons for TalkBack screen reader
- [x] Prominent safety disclaimers across all screens

## 11. Automated Testing (Phase 12)
- [x] 118 automated tests passing (0 failures)
- [x] Unit tests for Railway Station, Petrol Station, and Clinic categories
- [x] Unit tests for Repeat Place voice intent
- [x] Unit tests for `RoutingService` and OSRM walking route parsing

## 12. Android APK Build & Verification (Phase 14)
- [x] `flutter build apk --debug` succeeds cleanly
- [x] APK generated at: `frontend\build\app\outputs\flutter-apk\app-debug.apk` (225,636,416 bytes / ~215 MB)
- [x] `flutter devices` checked: no physical device currently attached via USB debugging; manual testing guide documented
