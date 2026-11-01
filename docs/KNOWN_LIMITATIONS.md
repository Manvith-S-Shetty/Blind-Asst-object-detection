# Blind Assistant AI — Known Limitations & Future Roadmap

**Document Version:** 2.0  
**Status:** Assistive Research Prototype  
**Date:** November 2026  

---

## 1. Assistive Boundaries & Safety Caveats

> [!CAUTION]
> **PROTOTYPE MOBILITY AID NOTICE:**  
> This software is an assistive research application designed to improve environmental awareness. **It is NOT certified as a medical mobility aid or life-safety navigation system.** It must NEVER replace traditional orientation and mobility aids (such as a white cane, a trained guide dog, or a sighted companion).

---

## 2. Technical Limitations

### 2.1 Optical & Sensor Limitations
1. **Monocular Geometry vs. Hardware Depth:**
   - Standard phone cameras provide only 2D pixel streams. Distance estimation relies on a pinhole camera model combined with assumed average real-world heights.
   - If an object has non-standard dimensions (e.g., miniature child's chair, unusually tall adult), the estimated distance will vary from physical reality.
   - For objects with unknown heights or truncated borders, distance is gated to `null` (`[dist: unk]`).
2. **Unsupported Environmental Hazards:**
   - The current baseline model **CANNOT** detect:
     - Ascending or descending staircases (critical fall hazard).
     - Curbs, platform edges, and sudden elevation drop-offs.
     - Transparent glass doors, glass walls, or mirrors.
     - Wet, slippery, or reflective floor surfaces.
     - Potholes or low ground depressions.
   - The user must always use their white cane to detect changes in elevation and ground surfaces.
3. **Lighting & Motion Blur:**
   - Rapid head or camera motion creates optical blur, which can degrade YOLO detection confidence below the 0.35 threshold.
   - In low-light or pitch-black environments, camera preview feeds degrade significantly without an auxiliary light source.

### 2.2 OpenStreetMap & Routing Limitations
1. **Straight-Line Distance vs. Actual Walking Distance:**
   - Nearby place search results are initially ordered by straight-line (great-circle) distance. Straight-line distance does NOT account for walls, fences, pedestrian detours, or buildings in between.
2. **Pedestrian Routing Public Service Constraints:**
   - The OSRM public foot server is a free, shared community resource. It is subject to rate-limiting and temporary network latency.
   - Walking directions derived from OpenStreetMap road networks do not guarantee sidewalk smoothness, temporary construction blockages, or accessibility ramps.
3. **GPS Precision:**
   - Standard consumer smartphone GPS typically provides an accuracy radius of 5 to 15 meters in urban areas. GPS signals may drift or become unavailable indoors ("urban canyons").

---

## 3. Future Engineering Roadmap

1. **Custom Fine-Tuning for Assistive Indoor Hazards:**
   - Train custom YOLOv11 nano/small models explicitly annotated for indoor doorways, open vs closed doors, staircases (ascending and descending), and drop-off edges using the protocol in `docs/indoor_dataset_collection_guide.md`.
2. **LiDAR & ToF Sensor Integration:**
   - For devices equipped with hardware Time-of-Flight sensors (e.g. iPad Pro, high-end Android flagships), implement direct native C++ depth buffer capture via Android Camera2 NDK to complement monocular estimates.
3. **Offline Vector Map Tile Packs:**
   - Integrate offline MBTiles / vector tile caching so maps and nearby place names can be stored locally for specific cities or districts without internet access.
4. **Haptic & Directional Audio Spatialization:**
   - Provide binaural 3D spatialized audio pings (left/right ear panning and pitch modulation proportional to proximity) alongside speech announcements for faster non-verbal spatial cognition.

