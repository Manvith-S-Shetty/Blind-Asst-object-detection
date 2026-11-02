import 'package:permission_handler/permission_handler.dart';

/// Wraps [permission_handler] APIs to allow clean dependency injection,
/// custom mock testing, and centralized runtime permission management.
class PermissionService {
  const PermissionService();

  /// Checks the current status of the camera permission.
  Future<PermissionStatus> checkCameraPermission() async {
    return Permission.camera.status;
  }

  /// Requests runtime permission for the camera.
  Future<PermissionStatus> requestCameraPermission() async {
    return Permission.camera.request();
  }

  /// Checks the current status of the microphone permission.
  Future<PermissionStatus> checkMicrophonePermission() async {
    return Permission.microphone.status;
  }

  /// Requests runtime permission for the microphone.
  Future<PermissionStatus> requestMicrophonePermission() async {
    return Permission.microphone.request();
  }

  /// Opens the device settings screen for this application.
  Future<bool> openSettings() async {
    return openAppSettings();
  }
}
