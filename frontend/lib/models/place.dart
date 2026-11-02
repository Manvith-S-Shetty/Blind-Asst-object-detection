import 'dart:math';

/// Supported general categories for voice-based nearby place search.
enum PlaceCategory {
  restaurant,
  hospital,
  clinic,
  pharmacy,
  busStop,
  railwayStation,
  petrolStation,
  shop,
  cafe,
  grocery,
  bank,
  general;

  String get displayName {
    switch (this) {
      case PlaceCategory.restaurant:
        return 'Restaurant';
      case PlaceCategory.hospital:
        return 'Hospital';
      case PlaceCategory.clinic:
        return 'Clinic / Medical Center';
      case PlaceCategory.pharmacy:
        return 'Pharmacy';
      case PlaceCategory.busStop:
        return 'Bus Stop';
      case PlaceCategory.railwayStation:
        return 'Railway / Train Station';
      case PlaceCategory.petrolStation:
        return 'Petrol / Gas Station';
      case PlaceCategory.shop:
        return 'Shop / Store';
      case PlaceCategory.cafe:
        return 'Coffee Shop / Café';
      case PlaceCategory.grocery:
        return 'Grocery / Market';
      case PlaceCategory.bank:
        return 'Bank / ATM';
      case PlaceCategory.general:
        return 'Place';
    }
  }
}

/// Represents a single geographic place result obtained from the Places provider.
///
/// SAFETY INVARIANT:
/// [distanceMeters] is an outdoor GPS estimate (great-circle straight-line distance).
/// It MUST NEVER be presented as a route, an obstacle-free trajectory, or confused
/// with camera-based obstacle proximity.
class PlaceResult {
  final String id;
  final String name;
  final PlaceCategory category;
  final double latitude;
  final double longitude;
  final double distanceMeters;
  final double bearingDegrees;
  final String? address;

  const PlaceResult({
    required this.id,
    required this.name,
    required this.category,
    required this.latitude,
    required this.longitude,
    required this.distanceMeters,
    required this.bearingDegrees,
    this.address,
  });

  /// Computes the 8-point cardinal direction string ("north", "northeast", etc.)
  String get cardinalDirection {
    final b = (bearingDegrees % 360 + 360) % 360;
    if (b >= 337.5 || b < 22.5) return 'north';
    if (b >= 22.5 && b < 67.5) return 'northeast';
    if (b >= 67.5 && b < 112.5) return 'east';
    if (b >= 112.5 && b < 157.5) return 'southeast';
    if (b >= 157.5 && b < 202.5) return 'south';
    if (b >= 202.5 && b < 247.5) return 'southwest';
    if (b >= 247.5 && b < 292.5) return 'west';
    return 'northwest';
  }

  /// Compact distance for UI chips and list items.
  String get formattedDistance {
    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m';
    } else {
      return '${(distanceMeters / 1000.0).toStringAsFixed(1)} km';
    }
  }

  /// Concise natural voice phrase for screen reader / TTS output.
  String toSpokenDescription() {
    final distStr = distanceMeters < 1000
        ? '${distanceMeters.round()} meters'
        : '${(distanceMeters / 1000.0).toStringAsFixed(1)} kilometers';
    return '$name, approximately $distStr $cardinalDirection.';
  }

  /// Static helper to calculate great-circle distance between two GPS coordinates in meters.
  static double calculateDistanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusMeters = 6371000.0;
    final dLat = (lat2 - lat1) * (pi / 180.0);
    final dLon = (lon2 - lon1) * (pi / 180.0);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * (pi / 180.0)) *
            cos(lat2 * (pi / 180.0)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  /// Static helper to calculate initial bearing from coordinate 1 to coordinate 2 in degrees [0, 360).
  static double calculateBearingDegrees(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final phi1 = lat1 * (pi / 180.0);
    final phi2 = lat2 * (pi / 180.0);
    final deltaLambda = (lon2 - lon1) * (pi / 180.0);

    final y = sin(deltaLambda) * cos(phi2);
    final x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda);
    final theta = atan2(y, x);
    return (theta * (180.0 / pi) + 360.0) % 360.0;
  }
}
