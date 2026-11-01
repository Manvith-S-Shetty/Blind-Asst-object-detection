import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:blind_assistant/models/place.dart';

/// Error categories for nearby places and location acquisition.
enum PlacesErrorType {
  none,
  gpsDisabled,
  locationPermissionDenied,
  locationPermissionDeniedForever,
  gpsTimeout,
  gpsUnavailable,
  noInternet,
  overpassUnavailable,
  overpassRateLimited,
  unknown,
}

/// Encapsulates the response from a nearby place query.
class PlacesResponse {
  final List<PlaceResult> places;
  final bool isSuccess;
  final String? errorMessage;
  final PlacesErrorType errorType;
  final int? httpStatusCode;
  final bool isFromCache;

  const PlacesResponse({
    required this.places,
    required this.isSuccess,
    this.errorMessage,
    this.errorType = PlacesErrorType.none,
    this.httpStatusCode,
    this.isFromCache = false,
  });

  factory PlacesResponse.success(List<PlaceResult> places, {bool isFromCache = false}) =>
      PlacesResponse(
        places: places,
        isSuccess: true,
        errorType: PlacesErrorType.none,
        isFromCache: isFromCache,
      );

  factory PlacesResponse.failure(
    String message, {
    PlacesErrorType errorType = PlacesErrorType.unknown,
    int? httpStatusCode,
  }) =>
      PlacesResponse(
        places: const [],
        isSuccess: false,
        errorMessage: message,
        errorType: errorType,
        httpStatusCode: httpStatusCode,
      );
}

class _CacheEntry {
  final List<PlaceResult> places;
  final DateTime timestamp;

  _CacheEntry({required this.places, required this.timestamp});

  bool isExpired(Duration ttl) =>
      DateTime.now().difference(timestamp) > ttl;
}

/// Client for discovering nearby geographic places using OpenStreetMap's Overpass API.
///
/// 100% FREE AND OPEN SOURCE:
/// - Uses OpenStreetMap Overpass API with multi-endpoint failover mirrors.
/// - Zero API keys, zero credentials, zero subscriptions, zero credit card requirements.
/// - Adheres strictly to Overpass Acceptable Use Policy:
///   1. Meaningful User-Agent string identify the application.
///   2. Client-side in-memory caching with 5-minute TTL to avoid redundant requests.
///   3. Cooldown rate-limiting between successive network dispatches.
///   4. Multi-endpoint failover across reputable community mirrors on HTTP 5xx errors.
///   5. Bounded search radius and server-side timeouts.
class PlacesClient {
  static const List<String> defaultEndpoints = [
    'https://overpass.openstreetmap.fr/api/interpreter',
    'https://overpass.osm.ch/api/interpreter',
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];
  static const String defaultOverpassUrl = 'https://overpass.openstreetmap.fr/api/interpreter';
  static const Duration defaultCacheTtl = Duration(minutes: 5);
  static const Duration minRequestInterval = Duration(seconds: 2);

  final http.Client _httpClient;
  final List<String> _endpoints;
  final Duration _cacheTtl;

  // In-memory cache to respect Overpass usage policies and conserve user data
  final Map<String, _CacheEntry> _cache = {};

  // Rate-limiting timestamp
  DateTime? _lastRequestTime;

  PlacesClient({
    http.Client? httpClient,
    String? overpassUrl,
    List<String>? endpoints,
    Duration cacheTtl = defaultCacheTtl,
  })  : _httpClient = httpClient ?? http.Client(),
        _cacheTtl = cacheTtl,
        _endpoints = endpoints ??
            (overpassUrl != null
                ? [overpassUrl]
                : defaultEndpoints);

  List<String> get endpoints => List.unmodifiable(_endpoints);

  /// Clears in-memory cache (primarily for unit testing and manual refresh).
  void clearCache() {
    _cache.clear();
  }

  /// Builds a deterministic cache key based on category, grid coordinate (~100m), and query.
  String _buildCacheKey(
    double lat,
    double lon,
    PlaceCategory category,
    String? customQuery,
  ) {
    // Round to 3 decimal places (~110 meters grid resolution)
    final latGrid = (lat * 1000).round() / 1000;
    final lonGrid = (lon * 1000).round() / 1000;
    final cleanQuery = (customQuery ?? '').trim().toLowerCase();
    return '${category.name}_${latGrid}_${lonGrid}_$cleanQuery';
  }

  /// Searches for places matching [category] within [radiusMeters] of [userLat, userLon].
  Future<PlacesResponse> searchNearby({
    required double userLat,
    required double userLon,
    required PlaceCategory category,
    String? customQuery,
    double radiusMeters = 1000.0,
    int maxResults = 15,
    bool forceRefresh = false,
  }) async {
    final cacheKey = _buildCacheKey(userLat, userLon, category, customQuery);

    // 1. Check in-memory cache unless forceRefresh requested
    if (forceRefresh) {
      debugPrint('[PLACES] Retry or fallback status: Cache invalidated for force refresh ($cacheKey)');
      _cache.remove(cacheKey);
    } else {
      final cached = _cache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        debugPrint('[PLACES] Returning cached results for $cacheKey (${cached.places.length} places)');
        return PlacesResponse.success(cached.places, isFromCache: true);
      }
    }

    // 2. Cooldown check to prevent aggressive flooding of Overpass API
    if (_lastRequestTime != null) {
      final elapsed = DateTime.now().difference(_lastRequestTime!);
      if (elapsed < minRequestInterval) {
        final waitNeeded = minRequestInterval - elapsed;
        await Future.delayed(waitNeeded);
      }
    }

    // 3. Query OpenStreetMap Overpass with multi-endpoint failover
    return _searchOverpass(
      cacheKey: cacheKey,
      userLat: userLat,
      userLon: userLon,
      category: category,
      customQuery: customQuery,
      radiusMeters: radiusMeters,
      maxResults: maxResults,
    );
  }

  Future<PlacesResponse> _searchOverpass({
    required String cacheKey,
    required double userLat,
    required double userLon,
    required PlaceCategory category,
    String? customQuery,
    required double radiusMeters,
    required int maxResults,
  }) async {
    final radius = radiusMeters.round();
    final queryTags = _buildOverpassTagFilter(
      category,
      customQuery,
      userLat,
      userLon,
      radius,
    );

    // Overpass QL query: searches both nodes and ways with center geometry
    final qlQuery = '''
[out:json][timeout:15];
(
$queryTags
);
out center $maxResults;
''';

    bool sawRateLimit = false;
    bool sawServerError = false;
    int lastStatusCode = 0;

    for (int i = 0; i < _endpoints.length; i++) {
      final endpoint = _endpoints[i];
      final isLast = i == _endpoints.length - 1;
      final stopwatch = Stopwatch()..start();

      debugPrint('[PLACES] Selected endpoint: $endpoint');

      try {
        _lastRequestTime = DateTime.now();
        final uri = Uri.parse(endpoint);
        final response = await _httpClient
            .post(
              uri,
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
                'User-Agent': 'BlindAssistantApp/0.1.0 (assistive-tech; contact: support@blindassistant.local)',
              },
              body: {'data': qlQuery},
            )
            .timeout(const Duration(seconds: 15));

        stopwatch.stop();
        debugPrint('[PLACES] HTTP status: ${response.statusCode}');
        debugPrint('[PLACES] Request duration: ${stopwatch.elapsedMilliseconds}ms');

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final elements = (data['elements'] as List<dynamic>?) ?? [];
          final places = _parseElements(elements, category, userLat, userLon);

          debugPrint('[PLACES] Number of results: ${places.length}');

          // Cache the successful result
          _cache[cacheKey] = _CacheEntry(places: places, timestamp: DateTime.now());

          return PlacesResponse.success(places);
        } else if (response.statusCode == 429) {
          sawRateLimit = true;
          lastStatusCode = 429;
          if (!isLast) {
            debugPrint('[PLACES] Retry or fallback status: Fallback from $endpoint (HTTP 429 rate limit) to next endpoint');
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
        } else if (response.statusCode >= 500 && response.statusCode < 600) {
          sawServerError = true;
          lastStatusCode = response.statusCode;
          if (!isLast) {
            debugPrint('[PLACES] Retry or fallback status: Fallback from $endpoint (HTTP ${response.statusCode}) to next endpoint');
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
        } else {
          return PlacesResponse.failure(
            'Place search request failed (HTTP ${response.statusCode}).',
            errorType: PlacesErrorType.unknown,
            httpStatusCode: response.statusCode,
          );
        }
      } on TimeoutException catch (e) {
        stopwatch.stop();
        debugPrint('[PLACES] Request duration: ${stopwatch.elapsedMilliseconds}ms (timeout on $endpoint: $e)');
        if (!isLast) {
          debugPrint('[PLACES] Retry or fallback status: Fallback from $endpoint (timeout) to next endpoint');
          continue;
        }
      } catch (e) {
        stopwatch.stop();
        debugPrint('[PLACES] Request duration: ${stopwatch.elapsedMilliseconds}ms (network error on $endpoint: $e)');
        if (!isLast) {
          debugPrint('[PLACES] Retry or fallback status: Fallback from $endpoint (network error) to next endpoint');
          continue;
        }
      }
    }

    if (sawServerError) {
      return PlacesResponse.failure(
        'Nearby search service is temporarily unavailable (code $lastStatusCode). Please try again later.',
        errorType: PlacesErrorType.overpassUnavailable,
        httpStatusCode: lastStatusCode,
      );
    }

    if (sawRateLimit) {
      return PlacesResponse.failure(
        'Search service is currently busy. Please wait a moment before trying again.',
        errorType: PlacesErrorType.overpassRateLimited,
        httpStatusCode: 429,
      );
    }

    return PlacesResponse.failure(
      'Unable to search places. Please verify internet connectivity.',
      errorType: PlacesErrorType.noInternet,
    );
  }

  List<PlaceResult> _parseElements(
    List<dynamic> elements,
    PlaceCategory category,
    double userLat,
    double userLon,
  ) {
    final places = <PlaceResult>[];

    for (final el in elements) {
      if (el is! Map<String, dynamic>) continue;
      final tags = (el['tags'] as Map<String, dynamic>?) ?? {};
      final rawName = tags['name']?.toString() ??
          tags['brand']?.toString() ??
          tags['operator']?.toString();

      final name = (rawName != null && rawName.trim().isNotEmpty)
          ? rawName.trim()
          : 'Unnamed ${category.displayName}';

      double? lat;
      double? lon;

      if (el['lat'] != null && el['lon'] != null) {
        lat = (el['lat'] as num).toDouble();
        lon = (el['lon'] as num).toDouble();
      } else if (el['center'] is Map) {
        final center = el['center'] as Map<String, dynamic>;
        lat = (center['lat'] as num?)?.toDouble();
        lon = (center['lon'] as num?)?.toDouble();
      }

      if (lat == null || lon == null) continue;

      final dist = PlaceResult.calculateDistanceMeters(userLat, userLon, lat, lon);
      final bearing = PlaceResult.calculateBearingDegrees(userLat, userLon, lat, lon);

      // Address formatting
      final street = tags['addr:street']?.toString();
      final houseNumber = tags['addr:housenumber']?.toString();
      final address = street != null
          ? (houseNumber != null ? '$houseNumber $street' : street)
          : tags['addr:city']?.toString();

      places.add(PlaceResult(
        id: el['id'].toString(),
        name: name,
        category: category,
        latitude: lat,
        longitude: lon,
        distanceMeters: dist,
        bearingDegrees: bearing,
        address: address,
      ));
    }

    // Sort results by proximity ascending (nearest first)
    places.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return places;
  }

  String _buildOverpassTagFilter(
    PlaceCategory category,
    String? customQuery,
    double userLat,
    double userLon,
    int radius,
  ) {
    if (customQuery != null && customQuery.trim().isNotEmpty) {
      final sanitized = customQuery.replaceAll(RegExp(r'["\\]'), '').trim();
      return '''
  node["name"~"$sanitized",i](around:$radius,$userLat,$userLon);
  way["name"~"$sanitized",i](around:$radius,$userLat,$userLon);
''';
    }

    switch (category) {
      case PlaceCategory.restaurant:
        return '''
  node["amenity"~"restaurant|fast_food|food_court"](around:$radius,$userLat,$userLon);
  way["amenity"~"restaurant|fast_food|food_court"](around:$radius,$userLat,$userLon);
''';
      case PlaceCategory.hospital:
        return '''
  node["amenity"="hospital"](around:$radius,$userLat,$userLon);
  way["amenity"="hospital"](around:$radius,$userLat,$userLon);
''';
      case PlaceCategory.clinic:
        return '''
  node["amenity"~"clinic|doctors"](around:$radius,$userLat,$userLon);
  way["amenity"~"clinic|doctors"](around:$radius,$userLat,$userLon);
  node["healthcare"="clinic"](around:$radius,$userLat,$userLon);
''';
      case PlaceCategory.pharmacy:
        return '''
  node["amenity"="pharmacy"](around:$radius,$userLat,$userLon);
  way["amenity"="pharmacy"](around:$radius,$userLat,$userLon);
''';
      case PlaceCategory.busStop:
        return '''
  node["highway"="bus_stop"](around:$radius,$userLat,$userLon);
  way["highway"="bus_stop"](around:$radius,$userLat,$userLon);
  node["public_transport"="platform"](around:$radius,$userLat,$userLon);
  node["amenity"="bus_station"](around:$radius,$userLat,$userLon);
''';
      case PlaceCategory.railwayStation:
        return '''
  node["railway"="station"](around:$radius,$userLat,$userLon);
  way["railway"="station"](around:$radius,$userLat,$userLon);
  node["station"="subway"](around:$radius,$userLat,$userLon);
  node["railway"="halt"](around:$radius,$userLat,$userLon);
''';
      case PlaceCategory.petrolStation:
        return '''
  node["amenity"="fuel"](around:$radius,$userLat,$userLon);
  way["amenity"="fuel"](around:$radius,$userLat,$userLon);
''';
      case PlaceCategory.shop:
        return '''
  node["shop"](around:$radius,$userLat,$userLon);
  way["shop"](around:$radius,$userLat,$userLon);
''';
      case PlaceCategory.cafe:
        return '''
  node["amenity"="cafe"](around:$radius,$userLat,$userLon);
  way["amenity"="cafe"](around:$radius,$userLat,$userLon);
''';
      case PlaceCategory.grocery:
        return '''
  node["shop"~"supermarket|convenience|grocery"](around:$radius,$userLat,$userLon);
  way["shop"~"supermarket|convenience|grocery"](around:$radius,$userLat,$userLon);
''';
      case PlaceCategory.bank:
        return '''
  node["amenity"~"bank|atm"](around:$radius,$userLat,$userLon);
  way["amenity"~"bank|atm"](around:$radius,$userLat,$userLon);
''';
      case PlaceCategory.general:
        return '''
  node["amenity"~"restaurant|cafe|pharmacy|bank|hospital|convenience|bus_station"](around:$radius,$userLat,$userLon);
  way["amenity"~"restaurant|cafe|pharmacy|bank|hospital|convenience|bus_station"](around:$radius,$userLat,$userLon);
''';
    }
  }
}
