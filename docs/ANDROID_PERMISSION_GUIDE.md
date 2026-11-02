# Blind Assistant AI — Android Permission & Security Architecture

**Document Version:** 2.0  
**Target Platform:** Android 6.0+ to Android 14+ (API Levels 23–34)  
**Configuration File:** `frontend/android/app/src/main/AndroidManifest.xml`  

---

## 1. Permission Architecture & Philosophy

The Blind Assistant AI application adheres to the principle of **Least Privilege** and **Just-In-Time (On-Demand) Permission Requests**:

1. **No Startup Permission Walls:** The app does not demand all permissions simultaneously upon initial launch.
2. **Accessible Spoken Explanations:** When a permission is denied, the application speaks a natural, concise explanation over the Text-to-Speech (TTS) engine, explaining exactly why the hardware sensor is needed and how to grant it.
3. **Decoupled Sensors:**
   - **Camera:** Requested only when the user taps "Start Navigation".
   - **Microphone:** Requested only when the user activates the "Voice Command" button.
   - **Location (GPS):** Requested only when the user performs a nearby place search.
   - If one sensor is denied, the other independent features continue operating unimpeded.

---

## 2. Declared Manifest Permissions

| Permission | Android Name | Protection Level | Purpose & Justification | When Requested |
|---|---|:---:|---|---|
| **Camera** | `android.permission.CAMERA` | `dangerous` (Runtime) | Captures live Camera2 video frames for on-device YOLO obstacle perception. | On-demand when tapping "Start Navigation" |
| **Record Audio** | `android.permission.RECORD_AUDIO` | `dangerous` (Runtime) | Captures user speech commands ("read", "find", "nearby restaurant"). | On-demand when tapping Voice Command button |
| **Fine Location** | `android.permission.ACCESS_FINE_LOCATION` | `dangerous` (Runtime) | Obtains current GPS coordinates to find nearby places via OpenStreetMap. | On-demand when initiating nearby place search |
| **Coarse Location** | `android.permission.ACCESS_COARSE_LOCATION` | `dangerous` (Runtime) | Fallback location estimation for battery conservation and coarse searches. | Requested alongside Fine Location |
| **Internet** | `android.permission.INTERNET` | `normal` (Install-time) | Required for querying OpenStreetMap Overpass API and optional backend server. | Granted at install time |
| **Network State** | `android.permission.ACCESS_NETWORK_STATE` | `normal` (Install-time) | Monitors Wi-Fi and cellular connectivity state. | Granted at install time |
| **Wi-Fi State** | `android.permission.ACCESS_WIFI_STATE` | `normal` (Install-time) | Required by `nsd` package to detect local network state for mDNS discovery. | Granted at install time |
| **Change Network State** | `android.permission.CHANGE_NETWORK_STATE` | `normal` (Install-time) | Required by `nsd` package for mDNS network binding. | Granted at install time |
| **Multicast State** | `android.permission.CHANGE_WIFI_MULTICAST_STATE` | `normal` (Install-time) | Required on some Android OEM distributions to receive incoming mDNS packets. | Granted at install time |

---

## 3. Hardware Features & Queries

### 3.1 Hardware Features
```xml
<uses-feature android:name="android.hardware.camera" android:required="false" />
<uses-feature android:name="android.hardware.camera.any" android:required="true" />
<uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />
```
*Note:* Setting `android.hardware.camera` to `required="false"` and `camera.any` to `required="true"` allows the application to run on devices with only front-facing cameras or external USB webcams.

### 3.2 Android 11+ Package Visibility (`<queries>`)
Android 11 (API 30+) introduces package visibility filtering. To enable discovery of native text-to-speech engines and native speech recognition services, the manifest explicitly declares:

```xml
<queries>
    <intent>
        <action android:name="android.intent.action.TTS_SERVICE" />
    </intent>
    <intent>
        <action android:name="android.speech.RecognitionService" />
    </intent>
</queries>
```

---

## 4. Permission State Transitions & Recovery Paths

### 4.1 First Denial (Soft Denial)
- **User Action:** Taps "Deny" on the Android permission dialog.
- **App Behavior:**
  - Speaks via TTS: *"Camera permission is required to detect obstacles. Please grant camera permission."*
  - Shows accessible retry card on screen with large touch target.
  - Next tap re-triggers the native permission prompt.

### 4.2 Permanent Denial ("Don't ask again")
- **User Action:** Checks "Don't ask again" or denies twice on Android 11+.
- **App Behavior:**
  - System recognizes `PermissionStatus.permanentlyDenied` or `LocationPermission.deniedForever`.
  - Speaks via TTS: *"Camera permission is permanently denied. Please enable camera permission in device settings."*
  - An on-screen button labeled **"Open App Settings"** directly launches Android device app settings via `openAppSettings()`.
  - When the user enables the permission and returns to the app, the lifecycle observer cleanly detects the grant and initializes the sensor.

---

## 5. Security & Privacy Guarantees

1. **No Cloud Audio Recording:** Spoken voice commands are parsed using on-device speech recognition whenever available; raw audio streams are never transmitted to third-party ad networks or surveillance services.
2. **Zero Location Tracking:** The app never runs background location polling or geofencing. GPS is activated strictly during the single moment the user asks for nearby places.
3. **No Unencrypted Cleartext Traffic:** Production builds strictly use HTTPS and WSS with system certificate validation. Cleartext traffic is restricted by `network_security_config.xml` to local development subnets (`10.0.2.2`, `192.168.0.0/16`, `10.0.0.0/8`).

