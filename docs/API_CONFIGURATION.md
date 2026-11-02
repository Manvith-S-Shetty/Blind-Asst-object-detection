# Blind Assistant AI — API Configuration & Open-Source Services Guide

**Target Audience:** Developers, Integrators & Researchers  
**Date:** November 2026  
**License:** Free & Open-Source Assistive Research  

---

## 1. 100% Free & Open-Source Service Stack

This project strictly avoids paid proprietary APIs (such as Google Places API, Mapbox, or Azure Cognitive Services), mandatory credit card billing, or subscription locks. All network services are free, open-source, and accessible to everyone.

| Service | Technology / Provider | Endpoint URL | Free Usage & Fair Use Terms | Key Required? |
|---|---|---|---|:---:|
| **Nearby Places Search** | OpenStreetMap (Overpass API) | `https://overpass-api.de/api/interpreter` | Public interpreter. Client-side caching (5m TTL), 2s minimum request interval, meaningful User-Agent. | **No** (0 keys) |
| **Map Rendering** | OpenStreetMap Standard Tiles | `https://tile.openstreetmap.org/{z}/{x}/{y}.png` | Free tile service. Max 2 zoom requests/sec, client caching, mandatory copyright attribution (`© OpenStreetMap contributors`). | **No** (0 keys) |
| **Pedestrian Routing** | Open Source Routing Machine (OSRM) | `https://router.project-osrm.org/route/v1/foot/...` | Public demo foot profile server. Strictly experimental, non-commercial research use. | **No** (0 keys) |
| **Local Obstacle AI** | TensorFlow Lite On-Device | Local asset (`assets/models/yolo11n_float16.tflite`) | 100% On-Device offline execution. Zero network, zero server cost. | **No** (0 keys) |
| **Text-to-Speech** | Android Native TTS (`flutter_tts`) | Local native Android TTS engine (Google TTS / Samsung TTS) | On-device synthesis. Works 100% offline. Zero network calls. | **No** (0 keys) |
| **Voice Recognition** | Android Native STT (`speech_to_text`) | Local Android SpeechRecognizer API | Native on-device engine. Zero API tokens. | **No** (0 keys) |
| **Optional Server** | FastAPI Self-Hosted Server | Local Wi-Fi (`http://<lan-ip>:8000`) | Self-hosted on developer's laptop. Zero cloud fees. | **No** (0 keys) |

---

## 2. OpenStreetMap Overpass API Configuration

### 2.1 Fair Use & Rate Limiting Compliance
The `PlacesClient` service (`frontend/lib/services/places_client.dart`) implements strict compliance safeguards:

1. **Custom User-Agent:**
   ```text
   BlindAssistantApp/0.1.0 (assistive-tech; contact: support@blindassistant.local)
   ```
2. **In-Memory Query Cache:**
   All search responses are cached in memory for **5 minutes** (`defaultCacheTtl = Duration(minutes: 5)`). Repeated queries for the same category within ~110 meters return instantly from memory.
3. **Dispatch Cooldown:**
   A minimum interval of **2 seconds** (`minRequestInterval = Duration(seconds: 2)`) is enforced between successive network dispatches.
4. **Bounded Search Radius:**
   Queries constrain bounding circles to 1000m (`around:1000,$userLat,$userLon`), keeping server query execution under 250 milliseconds.

### 2.2 Category to OSM Tag Mapping

| App Category | Primary OpenStreetMap Tags Queried |
|---|---|
| **Restaurants** | `node["amenity"~"restaurant\|fast_food\|food_court"]` |
| **Hospitals** | `node["amenity"="hospital"]` |
| **Clinics** | `node["amenity"~"clinic\|doctors"]`, `node["healthcare"="clinic"]` |
| **Pharmacies** | `node["amenity"="pharmacy"]` |
| **Bus Stops** | `node["highway"="bus_stop"]`, `node["amenity"="bus_station"]` |
| **Railway Stations** | `node["railway"="station"]`, `node["station"="subway"]`, `node["railway"="halt"]` |
| **Petrol Stations** | `node["amenity"="fuel"]` |
| **Shops / Retail** | `node["shop"]` |
| **Cafes** | `node["amenity"="cafe"]` |
| **Groceries** | `node["shop"~"supermarket\|convenience\|grocery"]` |
| **Banks & ATMs** | `node["amenity"~"bank\|atm"]` |

---

## 3. OSRM Foot Routing Configuration

### 3.1 Endpoint & Protocol
The `RoutingService` (`frontend/lib/services/routing_service.dart`) formats GET requests as:
```text
GET https://router.project-osrm.org/route/v1/foot/{lon1},{lat1};{lon2},{lat2}?overview=full&geometries=geojson&steps=true
```

### 3.2 Response Processing
- **Geometry:** GeoJSON coordinates `[ [lon, lat], ... ]` decoded into `List<LatLng>` for `PolylineLayer`.
- **Metrics:** True street walking distance in meters (differentiated from straight-line great-circle distance).
- **Maneuver Steps:** Formatted into natural English instructions ("Turn left onto Church St for 150 m").
- **Offline & Failure Handling:** If the public server times out (>8s) or is unreachable, the UI gracefully retains the straight-line distance without disrupting core obstacle guidance.

---

## 4. Optional Backend Configuration

When using the FastAPI backend, configuration is managed in `backend/app/config.py` and editable via the Flutter app's **Settings Screen**:

| Setting | Default Value | Description |
|---|---|---|
| **Backend Host** | `10.0.2.2` (Emulator) / `192.168.x.x` (Phone) | Host IP address of the laptop running FastAPI. |
| **Backend Port** | `8000` | HTTP and WebSocket port. |
| **mDNS Service Type** | `_blindassist._tcp.local.` | Auto-discovery service identifier. |
| **Speech Cooldown** | `5.0` seconds | Local guidance reannouncement interval. |
| **Confidence Threshold** | `0.35` | Minimum YOLO detection score required. |
| **Consecutive Frames** | `2` | Number of sequential frames required to confirm an obstacle track. |

