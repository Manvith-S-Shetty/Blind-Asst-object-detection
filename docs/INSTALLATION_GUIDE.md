# Blind Assistant AI — Complete Installation & Deployment Guide

**Target Environment:** Windows 10/11, macOS, or Linux  
**Target Device:** Android 11+ Phone (minSdk 21, targetSdk 34)  
**Tools Required:** Flutter SDK 3.47+, Android Studio or Android SDK Command-line Tools, Java 11 JDK  

---

## 1. Prerequisites & Environment Setup

### 1.1 Flutter SDK
1. Download and extract Flutter SDK (Channel Stable): [Flutter Install Guide](https://docs.flutter.dev/get-started/install).
2. Add Flutter's `bin` folder to your system `PATH`.
3. Verify Flutter installation:
   ```bash
   flutter doctor
   ```
   Ensure the Android toolchain displays `[√]`.

### 1.2 Android SDK & Platform Tools
1. In Android Studio, open **SDK Manager** and ensure:
   - Android SDK Platform 34 (or newer) is installed.
   - Android SDK Build-Tools 34.0.0 is installed.
   - Android SDK Platform-Tools (includes `adb`) is installed.
2. Add `platform-tools` to your system `PATH`:
   - Windows: `%LOCALAPPDATA%\Android\Sdk\platform-tools`
   - macOS/Linux: `$HOME/Library/Android/sdk/platform-tools` or `$ANDROID_HOME/platform-tools`

---

## 2. Building the Application

Navigate to the Flutter frontend directory:
```powershell
cd C:\Blind-Asst-object-detection\frontend
```

### 2.1 Install Dependencies
```powershell
flutter pub get
```

### 2.2 Verify Code Quality & Static Analysis
```powershell
flutter analyze
# Or run Dart analyzer directly:
dart analyze
```
*Expected output: `No issues found!`*

### 2.3 Run Full Automated Test Suite
```powershell
flutter test
```
*Expected output: `All 118 tests passed!`*

### 2.4 Build the Debug APK
```powershell
flutter build apk --debug
```
*Generated APK Output Location:*  
`C:\Blind-Asst-object-detection\frontend\build\app\outputs\flutter-apk\app-debug.apk`

---

## 3. Installing to a Physical Android Phone

### 3.1 Enable USB Debugging on Your Phone
1. Open **Settings** $\to$ **About Phone**.
2. Tap **Build Number** 7 times until you see the toast: *"You are now a developer!"*.
3. Go back to **Settings** $\to$ **System** $\to$ **Developer Options**.
4. Enable **USB Debugging**.

### 3.2 Connect and Authorize
1. Connect your Android phone to your PC via a USB data cable.
2. If prompted on your phone screen with *"Allow USB debugging?"*, check *"Always allow from this computer"* and tap **Allow**.
3. Verify connection in PowerShell:
   ```powershell
   adb devices
   ```
   *Expected output: `<device-serial>  device`*

### 3.3 Deploy the APK
Run the adb install command:
```powershell
adb install -r "C:\Blind-Asst-object-detection\frontend\build\app\outputs\flutter-apk\app-debug.apk"
```
Or run directly from source with live hot-reload:
```powershell
flutter run -d <your-device-id>
```

---

## 4. Optional: Starting the FastAPI Developer Backend

The core application operates completely offline on your device without the backend. If you wish to enable optional cloud multimodal features (BLIP scene captioning, RapidOCR text reading, YOLO-World open-vocabulary search, LAN telemetry):

1. Open a new terminal in the backend directory:
   ```powershell
   cd C:\Blind-Asst-object-detection\backend
   ```
2. Activate your Python virtual environment:
   ```powershell
   # Windows:
   venv\Scripts\activate
   # macOS/Linux:
   source venv/bin/activate
   ```
3. Install dependencies:
   ```powershell
   pip install -r requirements.txt
   ```
4. Start the server bound to all local interfaces:
   ```powershell
   uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```
5. Ensure your phone and PC are connected to the same Wi-Fi network. The app will auto-discover the server via mDNS (`_blindassist._tcp.local.`).

