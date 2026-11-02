# Blind Assistant AI — Real Physical Device Testing Protocol

**Document Version:** 2.0  
**Target Hardware:** Physical Android Phone (Android 11, 12, 13, or 14)  
**Verification Checklist:** 17 Core Device Verification Tests  

---

## 1. Safety Notice & Testing Environment Setup

> [!CAUTION]
> **CRITICAL MOBILITY DISCLAIMER:**  
> This application is an experimental assistive research tool. **It is NOT certified as safe for use as a sole mobility aid or primary navigation tool.** It must NEVER replace a primary mobility aid such as a white cane, guide dog, or attentive human companion. Obstacle detection is probabilistic and monocular; drop-offs, transparent glass, or fast-moving hazards may not be detected in time.

### Testing Setup:
1. Conduct initial tests in a **familiar, flat indoor room** (living room, office) with no open staircases, sharp drops, or moving vehicles.
2. Ensure phone battery is $\ge 30\%$.
3. Have a sighted assistant present to ensure safety.

---

## 2. Step-by-Step Device Verification Matrix

| Test ID | Test Name | Procedure | Expected Physical Device Behavior | Verification |
|:---:|---|---|---|:---:|
| **TC-01** | **Cold Launch & Offline State** | Put phone in Airplane Mode (Wi-Fi and Cellular off). Launch the app. | App opens directly to high-contrast dark UI. Teal status badge displays *"On-Device AI ready (Offline mode)"*. No crash, no backend error popups. | [ ] |
| **TC-02** | **Camera Permission Denial** | On a fresh install or after revoking camera access, tap **Start Navigation**. Tap **Deny** on system dialog. | TTS announces: *"Camera permission is required to detect obstacles. Please grant camera permission."* An accessible card appears with a large touch target to retry. | [ ] |
| **TC-03** | **Permanent Denial Deep Link** | Deny camera permission permanently ("Don't ask again"). | TTS explains settings requirement. Tap **"Open App Settings"**; device settings screen opens directly. Grant camera access and return to the app. | [ ] |
| **TC-04** | **Camera Preview & On-Device YOLO** | Tap **Start Navigation** with camera permission granted. | TTS announces: *"Navigation started. On-device detection active."* Camera preview starts smoothly at high framerate without UI lag. | [ ] |
| **TC-05** | **Calibrated Distance Estimation** | Point camera at an upright person or chair approximately 1.5 to 2.0 meters away. | Bounding box appears with label `[CONF%] [DIRECTION] ~1.5m (est)`. TTS speaks: *"Obstacle ahead, approximately 1.5 meters. Stop."* | [ ] |
| **TC-06** | **Distance Uncertainty Gating** | Point camera so the object touches the top or bottom frame edge (truncated). | Estimated label switches from `~X.Xm` to `[dist: unk]`. TTS does NOT invent a number; announces: *"Stop. [Object] directly ahead."* | [ ] |
| **TC-07** | **Directional Corridor Classification** | Slowly pan camera across an obstacle from left to right. | Bounding box label dynamically updates from `[left]` to `[center]` to `[right]`. Directional audio warns accordingly (*"Person on your left"*). | [ ] |
| **TC-08** | **Speech Non-Overlap & Coalescing** | Pan quickly across a room with multiple chairs and tables. | Utterances NEVER overlap or garble. Speech queue serializes cleanly; intermediate frame updates coalesce into the newest actionable instruction. | [ ] |
| **TC-09** | **Urgent Hazard Preemption** | While non-urgent speech is playing, bring a large chair into the direct forward path close up ($\le 1.2\text{m}$). | Routine speech is immediately cut off; high-contrast red STOP banner flashes on screen and TTS announces: *"Stop. Obstacle ahead."* | [ ] |
| **TC-10** | **Approaching Obstacle Trigger** | Walk toward an obstacle from 3.0 meters to 1.5 meters. | Distance reduction $\ge 0.5\text{m}$ immediately bypasses the 5-second cooldown and reannounces the approaching obstacle. | [ ] |
| **TC-11** | **Camera Lifecycle & Backgrounding** | Press the Home button or lock the screen for 10 seconds. Unlock and return to app. | Camera releases cleanly while in background (no battery drain/overheating). Reacquires preview smoothly on return without freezing or crashing. | [ ] |
| **TC-12** | **On-Demand Microphone Permission** | Tap the Voice Command button. Deny microphone on system prompt. | Navigation is NOT interrupted. TTS explains microphone permission is required for voice commands. | [ ] |
| **TC-13** | **Voice-Based Nearby Search** | Enable Wi-Fi/Cellular. Tap Voice button and say: *"Find a restaurant near me"*. | App transitions to Nearby Places screen, acquires GPS, queries OpenStreetMap, and announces: *"Found X places nearby. Nearest is [Name], approximately X meters [direction]. Say next to hear more."* | [ ] |
| **TC-14** | **Voice "Next" & "Repeat" Commands** | Tap Voice button and say *"next"*, then tap again and say *"repeat"*. | "Next" advances to place 2 and announces details aloud. "Repeat" repeats the active place details aloud without advancing. | [ ] |
| **TC-15** | **Interactive Map & OSRM Walking Route** | On the Places screen, tap a nearby place card. | Map centers on place pin. Walking route polyline renders on `flutter_map` in teal. Card displays walking distance, estimated duration, and step instructions with OSRM attribution. | [ ] |
| **TC-16** | **Network Offline Place Search Fallback** | Disable Wi-Fi and mobile data. Attempt nearby place search. | Friendly error banner explains internet is needed for OpenStreetMap search. TTS speaks clear explanation. Tap back to return to 100% offline navigation. | [ ] |
| **TC-17** | **Stop Navigation** | On the main navigation screen, tap **Stop Navigation**. | TTS confirms: *"Navigation stopped."* Camera hardware is released immediately. | [ ] |

