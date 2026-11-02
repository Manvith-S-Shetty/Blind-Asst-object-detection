import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Status of the location subsystem.
enum LocationServiceStatus {
  ready,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  timeout,
  error,
}

/// Result returned when acquiring the user's current GPS position.
class LocationResult {
  final Position? position;
  final LocationServiceStatus status;
  final String? errorMessage;

  const LocationResult({
    this.position,
    required this.status,
    this.errorMessage,
  });

  bool get isSuccess => status == LocationServiceStatus.ready && position != null;

  factory LocationResult.success(Position position) => LocationResult(
        position: position,
        status: LocationServiceStatus.ready,
      );

  factory LocationResult.failure(LocationServiceStatus status, String message) =>
      LocationResult(
        position: null,
        status: status,
        errorMessage: message,
      );
}

/// Service wrapping [Geolocator] for acquiring current GPS coordinates.
///
/// SAFETY & PRIVACY GUARANTEES:
/// 1. Location access is strictly on-demand (only when the user requests a nearby search).
/// 2. If permissions are denied or GPS is turned off, clear spoken explanations are provided.
/// 3. Independent of offline camera obstacle perception.
class LocationService {
  final GeolocatorPlatform? _platformOverride;

  const LocationService({GeolocatorPlatform? platformOverride})
      : _platformOverride = platformOverride;

  GeolocatorPlatform get _platform => _platformOverride ?? GeolocatorPlatform.instance;

  /// Checks if device GPS location services are enabled.
  Future<bool> isLocationServiceEnabled() async {
    try {
      return await _platform.isLocationServiceEnabled();
    } catch (e) {
      debugPrint('[LocationService] isLocationServiceEnabled error: $e');
      return false;
    }
  }

  /// Checks the current location permission status without prompting the user.
  Future<LocationPermission> checkPermission() async {
    try {
      return await _platform.checkPermission();
    } catch (e) {
      debugPrint('[LocationService] checkPermission error: $e');
      return LocationPermission.denied;
    }
  }

  /// Requests location permission from the user.
  Future<LocationPermission> requestPermission() async {
    try {
      return await _platform.requestPermission();
    } catch (e) {
      debugPrint('[LocationService] requestPermission error: $e');
      return LocationPermission.denied;
    }
  }

  /// Opens the device location settings screen.
  Future<bool> openLocationSettings() async {
    try {
      return await _platform.openLocationSettings();
    } catch (e) {
      debugPrint('[LocationService] openLocationSettings error: $e');
      return false;
    }
  }

  /// Opens app settings (e.g. if permissions are permanently denied).
  Future<bool> openAppSettings() async {
    try {
      return await _platform.openAppSettings();
    } catch (e) {
      debugPrint('[LocationService] openAppSettings error: $e');
      return false;
    }
  }

  /// Retrieves the current GPS position with timeout and error handling.
  Future<LocationResult> getCurrentPosition({
    Duration timeout = const Duration(seconds: 10),
    LocationAccuracy desiredAccuracy = LocationAccuracy.high,
  }) async {
    // 1. Verify device location service is enabled
    final serviceEnabled = await isLocationServiceEnabled();
    debugPrint('[GPS] Location services enabled: $serviceEnabled');
    if (!serviceEnabled) {
      return LocationResult.failure(
        LocationServiceStatus.serviceDisabled,
        'Device location service (GPS) is turned off. Please turn on GPS.',
      );
    }

    // 2. Check & request permission
    var permission = await checkPermission();
    debugPrint('[GPS] Permission status: $permission');
    if (permission == LocationPermission.denied) {
      permission = await requestPermission();
      debugPrint('[GPS] Permission status after request: $permission');
    }

    if (permission == LocationPermission.deniedForever) {
      return LocationResult.failure(
        LocationServiceStatus.permissionDeniedForever,
        'Location permission is permanently denied. Please allow location in app settings.',
      );
    }

    if (permission == LocationPermission.denied) {
      return LocationResult.failure(
        LocationServiceStatus.permissionDenied,
        'Location permission was denied. Location is needed to find nearby places.',
      );
    }

    // 3. Obtain current position with timeout
    try {
      final position = await _platform.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: desiredAccuracy,
          timeLimit: timeout,
        ),
      );
      debugPrint(
        '[GPS] Latitude: ${position.latitude.toStringAsFixed(5)}, '
        'Longitude: ${position.longitude.toStringAsFixed(5)}, '
        'Accuracy: ${position.accuracy.toStringAsFixed(1)}m',
      );
      return LocationResult.success(position);
    } on TimeoutException {
      // Attempt last known position as fallback if available
      try {
        final lastKnown = await _platform.getLastKnownPosition();
        if (lastKnown != null) {
          debugPrint(
            '[GPS] Latitude: ${lastKnown.latitude.toStringAsFixed(5)}, '
            'Longitude: ${lastKnown.longitude.toStringAsFixed(5)}, '
            'Accuracy: ${lastKnown.accuracy.toStringAsFixed(1)}m (from last known)',
          );
          return LocationResult.success(lastKnown);
        }
      } catch (_) {}

      debugPrint('[GPS] Location acquisition timed out');
      return LocationResult.failure(
        LocationServiceStatus.timeout,
        'GPS location timed out. Please check if you have a clear view of the sky.',
      );
    } catch (e) {
      debugPrint('[GPS] Location error: $e');
      return LocationResult.failure(
        LocationServiceStatus.error,
        'Failed to obtain location: $e',
      );
    }
  }
}
