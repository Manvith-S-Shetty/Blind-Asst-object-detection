import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Encapsulates the result of a walking route calculation between two GPS coordinates.
///
/// SAFETY & DISCLAIMER INVARIANTS:
/// 1. Walking route distance (along mapped paths/streets) is strictly distinct from straight-line distance.
/// 2. Experimental guidance only: public OpenStreetMap data does NOT guarantee wheelchair ramps,
///    tactile paving, staircase warnings, or temporary obstacles.
/// 3. MUST NEVER replace on-device obstacle detection or primary orientation aids (white cane, guide dog).
class WalkingRouteResult {
  final bool isSuccess;
  final List<LatLng> polylinePoints;
  final double? walkingDistanceMeters;
  final double? durationMinutes;
  final List<String> steps;
  final String provider;
  final String disclaimer;
  final String? errorMessage;

  const WalkingRouteResult({
    required this.isSuccess,
    this.polylinePoints = const [],
    this.walkingDistanceMeters,
    this.durationMinutes,
    this.steps = const [],
    this.provider = 'OSRM (Open Source Routing Machine - Public Foot Server)',
    this.disclaimer =
        'Experimental outdoor walking route estimate. Does not reflect stairs, drop-offs, construction, or real-time hazards. Never replace a white cane or guide dog.',
    this.errorMessage,
  });

  factory WalkingRouteResult.success({
    required List<LatLng> polylinePoints,
    required double walkingDistanceMeters,
    required double durationMinutes,
    required List<String> steps,
  }) =>
      WalkingRouteResult(
        isSuccess: true,
        polylinePoints: polylinePoints,
        walkingDistanceMeters: walkingDistanceMeters,
        durationMinutes: durationMinutes,
        steps: steps,
      );

  factory WalkingRouteResult.failure(String message) => WalkingRouteResult(
        isSuccess: false,
        errorMessage: message,
      );

  String get formattedWalkingDistance {
    if (walkingDistanceMeters == null) return 'Distance unknown';
    if (walkingDistanceMeters! < 1000) {
      return '${walkingDistanceMeters!.round()} m (walking)';
    } else {
      return '${(walkingDistanceMeters! / 1000.0).toStringAsFixed(1)} km (walking)';
    }
  }

  String get formattedDuration {
    if (durationMinutes == null) return '';
    final mins = durationMinutes!.round();
    if (mins <= 1) return '~1 min walk';
    return '~$mins min walk';
  }
}

/// Service providing optional outdoor pedestrian directions using the free public
/// Open Source Routing Machine (OSRM) Foot Routing API.
///
/// 100% FREE & OPEN SOURCE:
/// - Zero API keys, zero subscriptions, zero credit card accounts.
/// - Uses public OSRM demonstration server (`https://router.project-osrm.org`).
/// - Strictly optional: if offline or service is unavailable, app gracefully falls
///   back to straight-line distance without disrupting core obstacle navigation.
class RoutingService {
  static const String defaultOsrmFootUrl = 'https://router.project-osrm.org/route/v1/foot';
  static const Duration defaultTimeout = Duration(seconds: 8);

  final http.Client _httpClient;
  final String _baseUrl;

  RoutingService({
    http.Client? httpClient,
    String baseUrl = defaultOsrmFootUrl,
  })  : _httpClient = httpClient ?? http.Client(),
        _baseUrl = baseUrl;

  /// Calculates a walking route from [startLat, startLon] to [destLat, destLon].
  Future<WalkingRouteResult> getWalkingRoute({
    required double startLat,
    required double startLon,
    required double destLat,
    required double destLon,
  }) async {
    // Coordinates in OSRM format: {lon1},{lat1};{lon2},{lat2}
    final coordinates = '$startLon,$startLat;$destLon,$destLat';
    final uri = Uri.parse(
      '$_baseUrl/$coordinates?overview=full&geometries=geojson&steps=true',
    );

    try {
      final response = await _httpClient.get(
        uri,
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'BlindAssistantApp/0.1.0 (assistive-tech; routing)',
        },
      ).timeout(defaultTimeout);

      if (response.statusCode != 200) {
        return WalkingRouteResult.failure(
          'Routing service responded with code ${response.statusCode}. Please try again later.',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final code = data['code']?.toString();
      if (code != 'Ok') {
        return WalkingRouteResult.failure(
          'No walking route could be found between these coordinates.',
        );
      }

      final routes = data['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) {
        return WalkingRouteResult.failure('No pedestrian route available.');
      }

      final primaryRoute = routes.first as Map<String, dynamic>;
      final distance = (primaryRoute['distance'] as num?)?.toDouble() ?? 0.0;
      final durationSeconds = (primaryRoute['duration'] as num?)?.toDouble() ?? 0.0;
      final durationMinutes = durationSeconds / 60.0;

      // Parse geometry (GeoJSON format: [ [lon, lat], ... ])
      final geometry = primaryRoute['geometry'] as Map<String, dynamic>?;
      final coordinatesList = geometry?['coordinates'] as List<dynamic>?;
      final polylinePoints = <LatLng>[];

      if (coordinatesList != null) {
        for (final pt in coordinatesList) {
          if (pt is List && pt.length >= 2) {
            final lon = (pt[0] as num).toDouble();
            final lat = (pt[1] as num).toDouble();
            polylinePoints.add(LatLng(lat, lon));
          }
        }
      }

      // Parse turn-by-turn steps
      final steps = <String>[];
      final legs = primaryRoute['legs'] as List<dynamic>?;
      if (legs != null) {
        for (final leg in legs) {
          if (leg is Map<String, dynamic>) {
            final legSteps = leg['steps'] as List<dynamic>?;
            if (legSteps != null) {
              for (final s in legSteps) {
                if (s is Map<String, dynamic>) {
                  final name = s['name']?.toString() ?? '';
                  final maneuver = s['maneuver'] as Map<String, dynamic>?;
                  final type = maneuver?['type']?.toString() ?? '';
                  final modifier = maneuver?['modifier']?.toString() ?? '';
                  final stepDist = (s['distance'] as num?)?.toDouble() ?? 0.0;

                  String instruction = _formatStepInstruction(type, modifier, name, stepDist);
                  if (instruction.isNotEmpty) {
                    steps.add(instruction);
                  }
                }
              }
            }
          }
        }
      }

      return WalkingRouteResult.success(
        polylinePoints: polylinePoints,
        walkingDistanceMeters: distance,
        durationMinutes: durationMinutes,
        steps: steps,
      );
    } on TimeoutException {
      return WalkingRouteResult.failure('Walking route request timed out.');
    } catch (e) {
      debugPrint('[RoutingService] Error requesting walking route: $e');
      return WalkingRouteResult.failure('Unable to calculate walking route: $e');
    }
  }

  String _formatStepInstruction(
    String type,
    String modifier,
    String name,
    double distanceMeters,
  ) {
    final distStr = distanceMeters > 0 ? ' for ${distanceMeters.round()} m' : '';
    final streetPart = name.isNotEmpty ? ' onto $name' : '';

    switch (type) {
      case 'depart':
        return name.isNotEmpty ? 'Head out on $name$distStr' : 'Start walking$distStr';
      case 'arrive':
        return 'Arrive at destination';
      case 'turn':
        return 'Turn $modifier$streetPart$distStr';
      case 'continue':
        return 'Continue straight$streetPart$distStr';
      case 'end of road':
        return 'At the end of the road, turn $modifier$streetPart$distStr';
      case 'fork':
        return 'Keep $modifier at the fork$streetPart$distStr';
      case 'roundabout':
        return 'Enter roundabout and take exit$streetPart$distStr';
      default:
        return modifier.isNotEmpty ? 'Walk $modifier$streetPart$distStr' : 'Proceed$streetPart$distStr';
    }
  }
}

