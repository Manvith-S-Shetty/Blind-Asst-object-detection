# Blind Assistant AI — Flutter Frontend

Voice-first mobile/web app: camera → live object detection guidance
(spoken + visual), talking to the FastAPI backend over WebSocket.

## ⚠️ Important — one-time setup step required

This zip contains all the **Dart source code** (`lib/`), `pubspec.yaml`,
and the key native permission files (`AndroidManifest.xml`, `Info.plist`,
`web/index.html`). It does **not** contain the full native Android/iOS
build scaffolding (Gradle files, Xcode project, etc.) — that's thousands
of files Flutter generates locally, and it's tied to the exact Flutter
version installed on your machine, so shipping a pre-built one usually
causes more problems than it solves.

**You need to generate that scaffolding once, then drop this code in:**

```bash
# 1. Create a fresh Flutter project shell (this generates android/, ios/, etc.)
flutter create --org com.example --platforms=android,ios,web blind_assistant
cd blind_assistant

# 2. Replace the generated lib/ and pubspec.yaml with the ones from this zip
rm -rf lib
cp -r /path/to/this/zip/frontend/lib .
cp /path/to/this/zip/frontend/pubspec.yaml .

# 3. Merge in the permission files (camera/mic won't work without these)
cp /path/to/this/zip/frontend/android/app/src/main/AndroidManifest.xml android/app/src/main/AndroidManifest.xml
cp /path/to/this/zip/frontend/ios/Runner/Info.plist ios/Runner/Info.plist
cp /path/to/this/zip/frontend/web/index.html web/index.html
cp /path/to/this/zip/frontend/web/manifest.json web/manifest.json

# 4. Install packages
flutter pub get

# 5. Run it
flutter run   # pick your connected device/emulator/chrome when prompted
```

If you don't have Flutter installed yet: https://docs.flutter.dev/get-started/install
(needs Android Studio for Android, or Xcode for iOS — Xcode only runs on macOS).

## Connecting to the backend

The app defaults to `10.0.2.2:8000`, which is the special address the
**Android emulator** uses to reach your laptop's `localhost`. Go into
the app's Settings screen to change it:

| Running on...              | Backend host to enter                    |
|-----------------------------|-------------------------------------------|
| Android emulator             | `10.0.2.2` (default, already set)        |
| iOS simulator                 | `localhost` or `127.0.0.1`               |
| Real phone (Android/iOS)       | Your laptop's LAN IP, e.g. `192.168.1.5` |
| Flutter Web (Chrome)            | `localhost`                            |

For a **real phone**, your laptop and phone must be on the same Wi-Fi,
and you must start the backend with:
```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000
```
(`--host 0.0.0.0` is required — the default `127.0.0.1` only accepts
connections from the same machine.) Find your laptop's LAN IP with
`ipconfig` (Windows) or `ifconfig` / `ip addr` (Mac/Linux).

## What's implemented

- **Navigation screen** — live camera preview, Start/Stop button, sends
  frames to the backend every 400ms over WebSocket, displays + speaks
  guidance as it arrives (urgent guidance interrupts current speech).
- **Voice command button** — on-device speech recognition, routes
  "read", "find", "describe" commands (currently speaks a placeholder —
  wire this to `ApiService.readText/findObject/describeScene` once
  you're ready, the methods already exist in `lib/services/api_service.dart`).
- **Settings screen** — configurable backend host/port with a live
  connection test.
- High-contrast dark theme, large touch targets, `Semantics` labels for
  screen reader compatibility (TalkBack/VoiceOver).

## What's NOT implemented yet (good next steps)

- Wiring the voice command button's "find"/"read"/"describe" actions to
  the actual backend REST calls (the API methods exist, just not called yet)
- Offline mode / local caching
- The admin/web dashboard mentioned in the original tech stack (this is
  the mobile app only)
- Automated widget/integration tests

## Known limitation — I could not run/compile this Flutter app

This was written and reviewed for correctness against the Flutter/Dart
APIs and the backend's JSON contract, but **not actually compiled** —
this environment doesn't have the Flutter SDK or access to pub.dev.
Run `flutter analyze` after setup to catch anything I missed, most
likely minor version-mismatch issues in `pubspec.yaml` package versions.
