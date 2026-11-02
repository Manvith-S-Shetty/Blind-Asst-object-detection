import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:blind_assistant/models/detection.dart';
import 'package:blind_assistant/models/place.dart';
import 'package:blind_assistant/features/places/places_controller.dart';
import 'package:blind_assistant/features/places/places_screen.dart';
import 'package:blind_assistant/services/location_service.dart';
import 'package:blind_assistant/services/places_client.dart';
import 'package:blind_assistant/services/place_intent_parser.dart';
import 'package:blind_assistant/services/routing_service.dart';
import 'package:blind_assistant/services/tts_service.dart';

/// Test mock implementation for [GeolocatorPlatform].
class TestGeolocatorPlatform extends GeolocatorPlatform {
  bool serviceEnabled = true;
  LocationPermission permissionStatus = LocationPermission.always;
  LocationPermission requestResult = LocationPermission.always;
  Position? currentPosition;
  Position? lastKnownPosition;
  bool shouldTimeout = false;
  bool shouldThrow = false;

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permissionStatus;

  @override
  Future<LocationPermission> requestPermission() async => requestResult;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) async {
    if (shouldThrow) {
      throw Exception('GPS Hardware fault');
    }
    if (shouldTimeout) {
      throw TimeoutException('GPS timed out');
    }
    if (currentPosition != null) {
      return currentPosition!;
    }
    return Position(
      longitude: 77.5946,
      latitude: 12.9716,
      timestamp: DateTime.now(),
      accuracy: 5.0,
      altitude: 920.0,
      altitudeAccuracy: 1.0,
      heading: 0.0,
      headingAccuracy: 1.0,
      speed: 0.0,
      speedAccuracy: 0.0,
    );
  }

  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) async {
    return lastKnownPosition;
  }
}

class FakeTtsService extends Fake implements TtsService {
  final List<String> spokenMessages = [];

  @override
  Future<bool> speak(
    String text, {
    bool interrupt = false,
    Urgency urgency = Urgency.info,
  }) async {
    spokenMessages.add(text);
    return true;
  }

  @override
  Future<void> stop() async {
    spokenMessages.add('STOP');
  }
}

void main() {
  group('PlaceIntentParser Tests', () {
    test('Correctly identifies restaurant intents', () {
      final inputs = [
        'find a restaurant near me',
        'where is a diner nearby',
        'find food around here',
        'nearest pizza close by',
        'find a burger place near me',
      ];
      for (final text in inputs) {
        final intent = PlaceIntentParser.parse(text);
        expect(intent, isNotNull, reason: 'Failed for: $text');
        expect(intent!.category, equals(PlaceCategory.restaurant));
      }
    });

    test('Correctly identifies hospital intents', () {
      final inputs = [
        'find the nearest hospital',
        'find urgent care nearby',
        'where is the emergency room near me',
      ];
      for (final text in inputs) {
        final intent = PlaceIntentParser.parse(text);
        expect(intent, isNotNull, reason: 'Failed for: $text');
        expect(intent!.category, equals(PlaceCategory.hospital));
      }
    });

    test('Correctly identifies clinic intents', () {
      final inputs = [
        'where is a clinic near me',
        'nearest doctor around here',
        'where is medical center nearby',
        'find health clinic nearby',
      ];
      for (final text in inputs) {
        final intent = PlaceIntentParser.parse(text);
        expect(intent, isNotNull, reason: 'Failed for: $text');
        expect(intent!.category, equals(PlaceCategory.clinic));
      }
    });

    test('Correctly identifies railway station intents', () {
      final inputs = [
        'find the nearest railway station',
        'where is a train station near me',
        'nearest metro station close by',
        'find subway nearby',
      ];
      for (final text in inputs) {
        final intent = PlaceIntentParser.parse(text);
        expect(intent, isNotNull, reason: 'Failed for: $text');
        expect(intent!.category, equals(PlaceCategory.railwayStation));
      }
    });

    test('Correctly identifies petrol and gas station intents', () {
      final inputs = [
        'find a petrol station near me',
        'nearest gas station around here',
        'where is fuel station nearby',
        'find gas pump close by',
      ];
      for (final text in inputs) {
        final intent = PlaceIntentParser.parse(text);
        expect(intent, isNotNull, reason: 'Failed for: $text');
        expect(intent!.category, equals(PlaceCategory.petrolStation));
      }
    });

    test('Correctly identifies pharmacy intents', () {
      final inputs = [
        'find the nearest pharmacy',
        'where is a chemist near me',
        'find a drugstore nearby',
        'nearest medicine shop around here',
        'where is the medical store near me',
      ];
      for (final text in inputs) {
        final intent = PlaceIntentParser.parse(text);
        expect(intent, isNotNull, reason: 'Failed for: $text');
        expect(intent!.category, equals(PlaceCategory.pharmacy));
      }
    });

    test('Correctly identifies bus stop / transit intents', () {
      final inputs = [
        'find the nearest bus stop',
        'where is a bus stop nearby',
        'find bus stops near me',
        'nearest bus station close by',
        'where is transit stop around here',
      ];
      for (final text in inputs) {
        final intent = PlaceIntentParser.parse(text);
        expect(intent, isNotNull, reason: 'Failed for: $text');
        expect(intent!.category, equals(PlaceCategory.busStop));
      }
    });

    test('Correctly identifies shop / store intents', () {
      final inputs = [
        'find a shop near me',
        'nearest store nearby',
        'find clothing store around here',
        'nearest bookstore close by',
        'find retail shop near me',
      ];
      for (final text in inputs) {
        final intent = PlaceIntentParser.parse(text);
        expect(intent, isNotNull, reason: 'Failed for: $text');
        expect(intent!.category, equals(PlaceCategory.shop));
      }
    });

    test('Correctly identifies Next Place commands', () {
      final nextInputs = [
        'next',
        'next place',
        'next result',
        'next one',
        'tell me next',
        'tell me the next',
        'read next',
        "what's next",
        'next please',
      ];
      for (final text in nextInputs) {
        expect(PlaceIntentParser.isNextIntent(text), isTrue, reason: 'Failed for: $text');
      }

      final nonNextInputs = [
        'find restaurant',
        'where is chair',
        'stop navigation',
        'hello',
      ];
      for (final text in nonNextInputs) {
        expect(PlaceIntentParser.isNextIntent(text), isFalse, reason: 'Erroneously matched: $text');
      }
    });

    test('Parses custom search term with location markers', () {
      final intent = PlaceIntentParser.parse('find a library near me');
      expect(intent, isNotNull);
      expect(intent!.category, equals(PlaceCategory.general));
      expect(intent.customSearchTerm, equals('library'));
    });

    test('Disambiguation: Camera and local object queries return null', () {
      final cameraQueries = [
        'where is my chair',
        'find my backpack',
        'locate a water bottle',
        'where is the cup',
        'read this text',
        'read the sign ahead',
        'describe the scene',
        'what is in front of me',
        'search for keys',
      ];
      for (final query in cameraQueries) {
        final intent = PlaceIntentParser.parse(query);
        expect(intent, isNull, reason: 'Camera query erroneously parsed as place search: $query');
      }
    });

    test('Empty or unrelated queries return null', () {
      expect(PlaceIntentParser.parse(''), isNull);
      expect(PlaceIntentParser.parse('   '), isNull);
      expect(PlaceIntentParser.parse('hello there'), isNull);
      expect(PlaceIntentParser.parse('stop navigation'), isNull);
    });

    test('Correctly identifies "next" place intent', () {
      final inputs = [
        'next',
        'next place',
        'next result',
        'tell me the next result',
        'read next',
        "what's next",
      ];
      for (final text in inputs) {
        expect(PlaceIntentParser.isNextIntent(text), isTrue, reason: 'Failed for: $text');
      }
      expect(PlaceIntentParser.isNextIntent('stop'), isFalse);
      expect(PlaceIntentParser.isNextIntent('where is chair'), isFalse);
    });

    test('Correctly identifies "repeat" place intent', () {
      final inputs = [
        'repeat',
        'repeat place',
        'repeat result',
        'repeat that',
        'say again',
        'say that again',
        'tell me again',
        'what did you say',
      ];
      for (final text in inputs) {
        expect(PlaceIntentParser.isRepeatIntent(text), isTrue, reason: 'Failed for: $text');
      }
      expect(PlaceIntentParser.isRepeatIntent('next'), isFalse);
      expect(PlaceIntentParser.isRepeatIntent('find hospital'), isFalse);
    });
  });

  group('PlaceResult Domain Model Tests', () {
    test('Calculates Haversine distance accurately', () {
      // Bangalore Majestic (12.9778, 77.5726) to Cubbon Park (12.9763, 77.5929) is ~2.2 km
      final distance = PlaceResult.calculateDistanceMeters(
        12.9778,
        77.5726,
        12.9763,
        77.5929,
      );
      expect(distance, greaterThan(2000));
      expect(distance, lessThan(2500));
    });

    test('Calculates bearing and cardinal direction', () {
      // Point directly North
      final northBearing = PlaceResult.calculateBearingDegrees(12.0, 77.0, 13.0, 77.0);
      expect(northBearing, closeTo(0.0, 1.0));

      final placeNorth = PlaceResult(
        id: '1',
        name: 'North Cafe',
        category: PlaceCategory.cafe,
        latitude: 13.0,
        longitude: 77.0,
        distanceMeters: 450,
        bearingDegrees: northBearing,
      );
      expect(placeNorth.cardinalDirection, equals('north'));
      expect(placeNorth.formattedDistance, equals('450 m'));

      // Farther place in km
      const placeFar = PlaceResult(
        id: '2',
        name: 'Far Hospital',
        category: PlaceCategory.hospital,
        latitude: 13.0,
        longitude: 77.0,
        distanceMeters: 1400,
        bearingDegrees: 90.0,
      );
      expect(placeFar.cardinalDirection, equals('east'));
      expect(placeFar.formattedDistance, equals('1.4 km'));
    });

    test('toSpokenDescription provides concise accessibility info without safety claims', () {
      const place = PlaceResult(
        id: '3',
        name: 'City Pharmacy',
        category: PlaceCategory.pharmacy,
        latitude: 12.97,
        longitude: 77.59,
        distanceMeters: 180,
        bearingDegrees: 45.0,
        address: '12 Main Road',
      );
      final spoken = place.toSpokenDescription();
      expect(spoken, contains('City Pharmacy'));
      expect(spoken, contains('180 meters northeast'));
      // Verify no safety or obstacle-free claims
      expect(spoken.toLowerCase(), isNot(contains('safe')));
      expect(spoken.toLowerCase(), isNot(contains('clear')));
      expect(spoken.toLowerCase(), isNot(contains('obstacle-free')));
    });
  });

  group('PlacesClient Tests', () {
    test('Parses Overpass API response correctly and sorts by distance', () async {
      final fakeOverpassJson = jsonEncode({
        'elements': [
          {
            'type': 'node',
            'id': 101,
            'lat': 12.9730,
            'lon': 77.5960,
            'tags': {
              'name': 'Far Bus Stop',
              'highway': 'bus_stop',
            },
          },
          {
            'type': 'node',
            'id': 102,
            'lat': 12.9718,
            'lon': 77.5948,
            'tags': {
              'name': 'Close Bus Stop',
              'highway': 'bus_stop',
              'addr:street': 'Main Street',
            },
          },
        ],
      });

      int httpCallCount = 0;
      final mockClient = MockClient((request) async {
        httpCallCount++;
        expect(request.url.toString(), contains('interpreter'));
        expect(request.method, equals('POST'));
        return http.Response(fakeOverpassJson, 200, headers: {'content-type': 'application/json'});
      });

      final client = PlacesClient(
        httpClient: mockClient,
        overpassUrl: 'https://overpass-api.de/api/interpreter',
      );

      final response1 = await client.searchNearby(
        userLat: 12.9716,
        userLon: 77.5946,
        category: PlaceCategory.busStop,
      );

      expect(response1.isSuccess, isTrue);
      expect(response1.places.length, equals(2));
      // First result must be the closest one
      expect(response1.places.first.name, equals('Close Bus Stop'));
      expect(response1.isFromCache, isFalse);
      expect(httpCallCount, equals(1));

      // Second identical query within TTL must hit cache without triggering HTTP
      final response2 = await client.searchNearby(
        userLat: 12.9716,
        userLon: 77.5946,
        category: PlaceCategory.busStop,
      );
      expect(response2.isSuccess, isTrue);
      expect(response2.isFromCache, isTrue);
      expect(httpCallCount, equals(1)); // Zero extra HTTP calls!
    });

    test('Handles HTTP server error gracefully', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Gateway timeout', 504);
      });

      final client = PlacesClient(httpClient: mockClient);
      final response = await client.searchNearby(
        userLat: 12.97,
        userLon: 77.59,
        category: PlaceCategory.restaurant,
      );

      expect(response.isSuccess, isFalse);
      expect(response.places, isEmpty);
      expect(response.errorMessage, contains('504'));
    });

    test('Handles client exception / network drop gracefully', () async {
      final mockClient = MockClient((request) async {
        throw http.ClientException('Network unreachable');
      });

      final client = PlacesClient(httpClient: mockClient);
      final response = await client.searchNearby(
        userLat: 12.97,
        userLon: 77.59,
        category: PlaceCategory.pharmacy,
      );

      expect(response.isSuccess, isFalse);
      expect(response.errorMessage, contains('internet connectivity'));
    });
  });

  group('PlacesController & Next Place Announcement Tests', () {
    test('announceNextPlace cycles through places sequentially and wraps', () async {
      final fakeTts = FakeTtsService();
      final mockPlatform = TestGeolocatorPlatform();
      final locService = LocationService(platformOverride: mockPlatform);

      final fakeOverpassJson = jsonEncode({
        'elements': [
          {
            'type': 'node',
            'id': 1,
            'lat': 12.972,
            'lon': 77.595,
            'tags': {'name': 'First Pharmacy', 'amenity': 'pharmacy'},
          },
          {
            'type': 'node',
            'id': 2,
            'lat': 12.973,
            'lon': 77.596,
            'tags': {'name': 'Second Hospital', 'amenity': 'hospital'},
          },
        ]
      });

      final mockClient = MockClient((request) async {
        return http.Response(fakeOverpassJson, 200, headers: {'content-type': 'application/json'});
      });

      final placesClient = PlacesClient(httpClient: mockClient);

      final controller = PlacesController(
        locationService: locService,
        placesClient: placesClient,
        ttsService: fakeTts,
      );

      // Search
      await controller.searchNearby(category: PlaceCategory.pharmacy, speakResult: false);
      expect(controller.state.places.length, equals(2));
      expect(controller.state.currentAnnounceIndex, equals(0));

      // User says "next" -> Place 2
      await controller.announceNextPlace();
      expect(controller.state.currentAnnounceIndex, equals(1));
      expect(fakeTts.spokenMessages.last, contains('Place 2 of 2'));
      expect(fakeTts.spokenMessages.last, contains('Second Hospital'));

      // User says "next" again -> Wraps to Place 1
      await controller.announceNextPlace();
      expect(controller.state.currentAnnounceIndex, equals(0));
      expect(fakeTts.spokenMessages.last, contains('Place 1 of 2'));
      expect(fakeTts.spokenMessages.last, contains('First Pharmacy'));
    });

    test('repeatCurrentPlace repeats the active place result with index details', () async {
      final fakeTts = FakeTtsService();
      final mockPlatform = TestGeolocatorPlatform();
      final locService = LocationService(platformOverride: mockPlatform);

      final fakeOverpassJson = jsonEncode({
        'elements': [
          {
            'type': 'node',
            'id': 101,
            'lat': 12.972,
            'lon': 77.595,
            'tags': {'name': 'Central Station', 'railway': 'station'},
          },
        ]
      });

      final mockClient = MockClient((request) async {
        return http.Response(fakeOverpassJson, 200, headers: {'content-type': 'application/json'});
      });

      final controller = PlacesController(
        locationService: locService,
        placesClient: PlacesClient(httpClient: mockClient),
        ttsService: fakeTts,
      );

      await controller.searchNearby(category: PlaceCategory.railwayStation, speakResult: false);
      expect(controller.state.places.length, equals(1));

      // User says "repeat"
      await controller.repeatCurrentPlace();
      expect(fakeTts.spokenMessages.last, contains('Repeating place 1 of 1'));
      expect(fakeTts.spokenMessages.last, contains('Central Station'));
    });

    test('repeatCurrentPlace announces helpful guidance when no places are found', () async {
      final fakeTts = FakeTtsService();
      final mockPlatform = TestGeolocatorPlatform();
      final locService = LocationService(platformOverride: mockPlatform);

      final controller = PlacesController(
        locationService: locService,
        placesClient: PlacesClient(httpClient: MockClient((_) async => http.Response('{"elements":[]}', 200))),
        ttsService: fakeTts,
      );

      await controller.repeatCurrentPlace();
      expect(fakeTts.spokenMessages.last, contains('No nearby places to repeat'));
    });

    test('selectPlaceAndRoute fetches walking route and clearRoute resets it', () async {
      final fakeTts = FakeTtsService();
      final mockPlatform = TestGeolocatorPlatform();
      final locService = LocationService(platformOverride: mockPlatform);

      final sampleOsrmJson = jsonEncode({
        'code': 'Ok',
        'routes': [
          {
            'distance': 450.0,
            'duration': 360.0,
            'geometry': {
              'coordinates': [
                [77.5946, 12.9716],
                [77.5948, 12.9718],
                [77.5950, 12.9720],
              ]
            },
            'legs': [
              {
                'steps': [
                  {
                    'name': 'Brigade Road',
                    'distance': 250.0,
                    'maneuver': {'type': 'depart', 'modifier': ''}
                  },
                  {
                    'name': 'Church Street',
                    'distance': 200.0,
                    'maneuver': {'type': 'turn', 'modifier': 'right'}
                  }
                ]
              }
            ]
          }
        ]
      });

      final mockHttpClient = MockClient((request) async {
        if (request.url.toString().contains('router.project-osrm.org')) {
          return http.Response(sampleOsrmJson, 200, headers: {'content-type': 'application/json'});
        }
        return http.Response('{"elements":[]}', 200);
      });

      final routingService = RoutingService(httpClient: mockHttpClient);
      final controller = PlacesController(
        locationService: locService,
        placesClient: PlacesClient(httpClient: mockHttpClient),
        routingService: routingService,
        ttsService: fakeTts,
      );

      const targetPlace = PlaceResult(
        id: '99',
        name: 'City Cafe',
        category: PlaceCategory.cafe,
        latitude: 12.9720,
        longitude: 77.5950,
        distanceMeters: 400.0,
        bearingDegrees: 45.0,
      );

      // Set user position
      controller.state = controller.state.copyWith(
        userPosition: Position(
          longitude: 77.5946,
          latitude: 12.9716,
          timestamp: DateTime.now(),
          accuracy: 5.0,
          altitude: 900.0,
          altitudeAccuracy: 1.0,
          heading: 0.0,
          headingAccuracy: 1.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        ),
        places: [targetPlace],
      );

      await controller.selectPlaceAndRoute(targetPlace, speakRoute: true);
      expect(controller.state.walkingRoute, isNotNull);
      expect(controller.state.walkingRoute!.isSuccess, isTrue);
      expect(controller.state.walkingRoute!.walkingDistanceMeters, equals(450.0));
      expect(controller.state.walkingRoute!.polylinePoints.length, equals(3));
      expect(controller.state.walkingRoute!.steps.length, equals(2));
      expect(fakeTts.spokenMessages.last, contains('Walking route found'));

      // Test clearRoute
      controller.clearRoute();
      expect(controller.state.walkingRoute, isNull);
      expect(controller.state.selectedPlace, isNull);
    });
  });

  group('RoutingService Unit Tests', () {
    test('Parses successful OSRM walking route geometry and steps', () async {
      final sampleOsrmJson = jsonEncode({
        'code': 'Ok',
        'routes': [
          {
            'distance': 620.5,
            'duration': 480.0,
            'geometry': {
              'coordinates': [
                [77.5946, 12.9716],
                [77.5950, 12.9720],
              ]
            },
            'legs': [
              {
                'steps': [
                  {
                    'name': 'Main Street',
                    'distance': 300.0,
                    'maneuver': {'type': 'depart'}
                  },
                  {
                    'name': 'Cross Street',
                    'distance': 320.5,
                    'maneuver': {'type': 'turn', 'modifier': 'left'}
                  }
                ]
              }
            ]
          }
        ]
      });

      final mockClient = MockClient((_) async => http.Response(sampleOsrmJson, 200));
      final service = RoutingService(httpClient: mockClient);

      final result = await service.getWalkingRoute(
        startLat: 12.9716,
        startLon: 77.5946,
        destLat: 12.9720,
        destLon: 77.5950,
      );

      expect(result.isSuccess, isTrue);
      expect(result.walkingDistanceMeters, closeTo(620.5, 0.1));
      expect(result.durationMinutes, closeTo(8.0, 0.1));
      expect(result.polylinePoints.length, equals(2));
      expect(result.steps.length, equals(2));
      expect(result.formattedWalkingDistance, contains('621 m (walking)'));
      expect(result.formattedDuration, contains('~8 min walk'));
      expect(result.disclaimer, contains('Experimental outdoor walking route'));
    });

    test('Handles OSRM HTTP error code gracefully', () async {
      final mockClient = MockClient((_) async => http.Response('Server Error', 500));
      final service = RoutingService(httpClient: mockClient);

      final result = await service.getWalkingRoute(
        startLat: 12.0,
        startLon: 77.0,
        destLat: 12.1,
        destLon: 77.1,
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('500'));
    });

    test('Handles timeout gracefully', () async {
      final mockClient = MockClient((_) async {
        await Future.delayed(const Duration(milliseconds: 100));
        throw TimeoutException('Timed out');
      });
      final service = RoutingService(httpClient: mockClient);

      final result = await service.getWalkingRoute(
        startLat: 12.0,
        startLon: 77.0,
        destLat: 12.1,
        destLon: 77.1,
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('timed out'));
    });
  });

  group('LocationService Tests', () {
    test('Reports failure when device location service is disabled', () async {
      final mockPlatform = TestGeolocatorPlatform()..serviceEnabled = false;
      final service = LocationService(platformOverride: mockPlatform);

      final result = await service.getCurrentPosition();
      expect(result.isSuccess, isFalse);
      expect(result.status, equals(LocationServiceStatus.serviceDisabled));
      expect(result.errorMessage, contains('turned off'));
    });

    test('Reports failure when user denies permission', () async {
      final mockPlatform = TestGeolocatorPlatform()
        ..serviceEnabled = true
        ..permissionStatus = LocationPermission.denied
        ..requestResult = LocationPermission.denied;
      final service = LocationService(platformOverride: mockPlatform);

      final result = await service.getCurrentPosition();
      expect(result.isSuccess, isFalse);
      expect(result.status, equals(LocationServiceStatus.permissionDenied));
      expect(result.errorMessage, contains('denied'));
    });

    test('Reports failure when permission is denied forever', () async {
      final mockPlatform = TestGeolocatorPlatform()
        ..serviceEnabled = true
        ..permissionStatus = LocationPermission.deniedForever;
      final service = LocationService(platformOverride: mockPlatform);

      final result = await service.getCurrentPosition();
      expect(result.isSuccess, isFalse);
      expect(result.status, equals(LocationServiceStatus.permissionDeniedForever));
      expect(result.errorMessage, contains('settings'));
    });

    test('Returns location successfully when permission is granted', () async {
      final mockPlatform = TestGeolocatorPlatform()
        ..serviceEnabled = true
        ..permissionStatus = LocationPermission.always
        ..currentPosition = Position(
          longitude: 77.5946,
          latitude: 12.9716,
          timestamp: DateTime.now(),
          accuracy: 10.0,
          altitude: 900.0,
          altitudeAccuracy: 1.0,
          heading: 0.0,
          headingAccuracy: 1.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        );
      final service = LocationService(platformOverride: mockPlatform);

      final result = await service.getCurrentPosition();
      expect(result.isSuccess, isTrue);
      expect(result.position, isNotNull);
      expect(result.position!.latitude, equals(12.9716));
      expect(result.position!.longitude, equals(77.5946));
    });

    test('Falls back to lastKnownPosition when getCurrentPosition times out', () async {
      final fallbackPosition = Position(
        longitude: 77.5900,
        latitude: 12.9700,
        timestamp: DateTime.now(),
        accuracy: 25.0,
        altitude: 900.0,
        altitudeAccuracy: 1.0,
        heading: 0.0,
        headingAccuracy: 1.0,
        speed: 0.0,
        speedAccuracy: 0.0,
      );

      final mockPlatform = TestGeolocatorPlatform()
        ..serviceEnabled = true
        ..permissionStatus = LocationPermission.whileInUse
        ..shouldTimeout = true
        ..lastKnownPosition = fallbackPosition;

      final service = LocationService(platformOverride: mockPlatform);

      final result = await service.getCurrentPosition();
      expect(result.isSuccess, isTrue);
      expect(result.position, equals(fallbackPosition));
    });
  });

  group('GPS and Overpass Failover & Distinct UI State Tests', () {
    test('GPS permission allowed returns valid coordinates', () async {
      final mockPlatform = TestGeolocatorPlatform()
        ..serviceEnabled = true
        ..permissionStatus = LocationPermission.whileInUse
        ..currentPosition = Position(
          longitude: 77.5946,
          latitude: 12.9716,
          timestamp: DateTime.now(),
          accuracy: 4.2,
          altitude: 900.0,
          altitudeAccuracy: 1.0,
          heading: 0.0,
          headingAccuracy: 1.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        );

      final service = LocationService(platformOverride: mockPlatform);
      final result = await service.getCurrentPosition();

      expect(result.isSuccess, isTrue);
      expect(result.status, equals(LocationServiceStatus.ready));
      expect(result.position!.latitude, equals(12.9716));
      expect(result.position!.longitude, equals(77.5946));
      expect(result.position!.accuracy, equals(4.2));
    });

    test('GPS disabled returns serviceDisabled status and guidance', () async {
      final mockPlatform = TestGeolocatorPlatform()..serviceEnabled = false;
      final service = LocationService(platformOverride: mockPlatform);

      final result = await service.getCurrentPosition();
      expect(result.isSuccess, isFalse);
      expect(result.status, equals(LocationServiceStatus.serviceDisabled));
      expect(result.errorMessage, contains('turned off'));
    });

    test('GPS timeout returns timeout status and guidance', () async {
      final mockPlatform = TestGeolocatorPlatform()
        ..serviceEnabled = true
        ..permissionStatus = LocationPermission.always
        ..shouldTimeout = true
        ..lastKnownPosition = null;

      final service = LocationService(platformOverride: mockPlatform);
      final result = await service.getCurrentPosition();

      expect(result.isSuccess, isFalse);
      expect(result.status, equals(LocationServiceStatus.timeout));
      expect(result.errorMessage, contains('timed out'));
    });

    test('HTTP 502 response returns overpassUnavailable error type', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Bad Gateway', 502);
      });

      final client = PlacesClient(httpClient: mockClient, overpassUrl: 'https://overpass-api.de/api/interpreter');
      final response = await client.searchNearby(
        userLat: 12.97,
        userLon: 77.59,
        category: PlaceCategory.restaurant,
      );

      expect(response.isSuccess, isFalse);
      expect(response.errorType, equals(PlacesErrorType.overpassUnavailable));
      expect(response.httpStatusCode, equals(502));
      expect(response.errorMessage, contains('temporarily unavailable'));
      expect(response.errorMessage, contains('502'));
    });

    test('HTTP 503 response returns overpassUnavailable error type', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Service Unavailable', 503);
      });

      final client = PlacesClient(httpClient: mockClient, overpassUrl: 'https://overpass-api.de/api/interpreter');
      final response = await client.searchNearby(
        userLat: 12.97,
        userLon: 77.59,
        category: PlaceCategory.hospital,
      );

      expect(response.isSuccess, isFalse);
      expect(response.errorType, equals(PlacesErrorType.overpassUnavailable));
      expect(response.httpStatusCode, equals(503));
      expect(response.errorMessage, contains('temporarily unavailable'));
      expect(response.errorMessage, contains('503'));
    });

    test('Alternative endpoint success: fails over from 502 to mirror and succeeds', () async {
      final requestedUrls = <String>[];
      final fakeOverpassJson = jsonEncode({
        'elements': [
          {
            'type': 'node',
            'id': 1001,
            'lat': 12.9720,
            'lon': 77.5950,
            'tags': {'name': 'Backup Cafe', 'amenity': 'cafe'},
          },
        ]
      });

      final mockClient = MockClient((request) async {
        requestedUrls.add(request.url.toString());
        if (request.url.toString().contains('endpoint-one')) {
          // Primary fails with 502
          return http.Response('Bad Gateway', 502);
        } else {
          // Secondary mirror succeeds with 200
          return http.Response(fakeOverpassJson, 200, headers: {'content-type': 'application/json'});
        }
      });

      final client = PlacesClient(
        httpClient: mockClient,
        endpoints: [
          'https://endpoint-one.test/api/interpreter',
          'https://endpoint-two.test/api/interpreter',
        ],
      );

      final response = await client.searchNearby(
        userLat: 12.97,
        userLon: 77.59,
        category: PlaceCategory.cafe,
      );

      expect(response.isSuccess, isTrue);
      expect(response.places.length, equals(1));
      expect(response.places.first.name, equals('Backup Cafe'));
      expect(requestedUrls.length, equals(2));
      expect(requestedUrls[0], contains('endpoint-one'));
      expect(requestedUrls[1], contains('endpoint-two'));
    });

    test('Both endpoints unavailable returns overpassUnavailable without crash', () async {
      final requestedUrls = <String>[];
      final mockClient = MockClient((request) async {
        requestedUrls.add(request.url.toString());
        if (request.url.toString().contains('primary')) {
          return http.Response('Bad Gateway', 502);
        } else {
          return http.Response('Service Unavailable', 503);
        }
      });

      final client = PlacesClient(
        httpClient: mockClient,
        endpoints: [
          'https://primary.test/api/interpreter',
          'https://secondary.test/api/interpreter',
        ],
      );

      final response = await client.searchNearby(
        userLat: 12.97,
        userLon: 77.59,
        category: PlaceCategory.restaurant,
      );

      expect(response.isSuccess, isFalse);
      expect(response.errorType, equals(PlacesErrorType.overpassUnavailable));
      expect(requestedUrls.length, equals(2));
    });

    test('Successful nearby search parses and sorts results by proximity', () async {
      final fakeOverpassJson = jsonEncode({
        'elements': [
          {
            'type': 'node',
            'id': 201,
            'lat': 12.9800,
            'lon': 77.6000,
            'tags': {'name': 'Distant Pharmacy', 'amenity': 'pharmacy'},
          },
          {
            'type': 'node',
            'id': 202,
            'lat': 12.9720,
            'lon': 77.5950,
            'tags': {'name': 'Near Pharmacy', 'amenity': 'pharmacy'},
          },
        ]
      });

      final client = PlacesClient(
        httpClient: MockClient((_) async => http.Response(fakeOverpassJson, 200)),
        overpassUrl: 'https://test.local/api/interpreter',
      );

      final response = await client.searchNearby(
        userLat: 12.9716,
        userLon: 77.5946,
        category: PlaceCategory.pharmacy,
      );

      expect(response.isSuccess, isTrue);
      expect(response.places.length, equals(2));
      expect(response.places.first.name, equals('Near Pharmacy'));
      expect(response.places.last.name, equals('Distant Pharmacy'));
      expect(response.places.first.distanceMeters, lessThan(response.places.last.distanceMeters));
    });

    test('Retry behavior: forceRefresh forces genuine new HTTP request bypassing cache', () async {
      int requestCount = 0;
      final fakeOverpassJson = jsonEncode({
        'elements': [
          {
            'type': 'node',
            'id': 301,
            'lat': 12.9720,
            'lon': 77.5950,
            'tags': {'name': 'Refresh Test Shop', 'shop': 'convenience'},
          },
        ]
      });

      final client = PlacesClient(
        httpClient: MockClient((_) async {
          requestCount++;
          return http.Response(fakeOverpassJson, 200);
        }),
        overpassUrl: 'https://test.local/api/interpreter',
      );

      // Call 1: initial fetch
      final res1 = await client.searchNearby(
        userLat: 12.97,
        userLon: 77.59,
        category: PlaceCategory.shop,
      );
      expect(res1.isSuccess, isTrue);
      expect(res1.isFromCache, isFalse);
      expect(requestCount, equals(1));

      // Call 2: without forceRefresh -> cached
      final res2 = await client.searchNearby(
        userLat: 12.97,
        userLon: 77.59,
        category: PlaceCategory.shop,
      );
      expect(res2.isSuccess, isTrue);
      expect(res2.isFromCache, isTrue);
      expect(requestCount, equals(1));

      // Call 3: with forceRefresh: true -> cache bypassed, genuine network request
      final res3 = await client.searchNearby(
        userLat: 12.97,
        userLon: 77.59,
        category: PlaceCategory.shop,
        forceRefresh: true,
      );
      expect(res3.isSuccess, isTrue);
      expect(res3.isFromCache, isFalse);
      expect(requestCount, equals(2));
    });

    test('PlacesController decouples GPS from Overpass error: HTTP 502 does not alter locationStatus', () async {
      final fakeTts = FakeTtsService();
      final mockPlatform = TestGeolocatorPlatform()
        ..serviceEnabled = true
        ..permissionStatus = LocationPermission.always
        ..currentPosition = Position(
          longitude: 77.5946,
          latitude: 12.9716,
          timestamp: DateTime.now(),
          accuracy: 5.0,
          altitude: 900.0,
          altitudeAccuracy: 1.0,
          heading: 0.0,
          headingAccuracy: 1.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        );

      final locService = LocationService(platformOverride: mockPlatform);
      final placesClient = PlacesClient(
        httpClient: MockClient((_) async => http.Response('Bad Gateway', 502)),
        overpassUrl: 'https://test.local/api/interpreter',
      );

      final controller = PlacesController(
        locationService: locService,
        placesClient: placesClient,
        ttsService: fakeTts,
      );

      await controller.searchNearby(category: PlaceCategory.restaurant, speakResult: false);

      // GPS must be marked ready
      expect(controller.state.userPosition, isNotNull);
      expect(controller.state.locationStatus, equals(LocationServiceStatus.ready));

      // Overpass error must be recorded without overwriting locationStatus
      expect(controller.state.errorMessage, contains('temporarily unavailable'));
      expect(controller.state.errorType, equals(PlacesErrorType.overpassUnavailable));
    });

    testWidgets('UI View on Overpass 502 displays Retry but NOT Enable GPS or App Settings', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlacesErrorView(
              message: 'Nearby search service is temporarily unavailable (code 502). Please try again later.',
              errorType: PlacesErrorType.overpassUnavailable,
              onRetry: () {},
              onGrantPermission: () {},
              onOpenSettings: () {},
              onOpenLocationSettings: () {},
            ),
          ),
        ),
      );

      // Verifies message is displayed
      expect(find.textContaining('temporarily unavailable'), findsOneWidget);

      // Verifies Retry button is present
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);

      // Verifies "Enable GPS" is ABSOLUTELY NOT present
      expect(find.text('Enable GPS'), findsNothing);

      // Verifies "App Settings" is ABSOLUTELY NOT present
      expect(find.text('App Settings'), findsNothing);

      // Verifies Cloud Off icon is present
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    });

    testWidgets('UI View on GPS disabled displays Enable GPS and Retry', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlacesErrorView(
              message: 'Device location service (GPS) is turned off. Please turn on GPS.',
              errorType: PlacesErrorType.gpsDisabled,
              onRetry: () {},
              onGrantPermission: () {},
              onOpenSettings: () {},
              onOpenLocationSettings: () {},
            ),
          ),
        ),
      );

      expect(find.widgetWithText(ElevatedButton, 'Enable GPS'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
      expect(find.byIcon(Icons.location_disabled), findsOneWidget);
    });

    testWidgets('UI View on permission denied displays Grant Permission and Retry', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlacesErrorView(
              message: 'Location permission was denied. Location is needed to find nearby places.',
              errorType: PlacesErrorType.locationPermissionDenied,
              onRetry: () {},
              onGrantPermission: () {},
              onOpenSettings: () {},
              onOpenLocationSettings: () {},
            ),
          ),
        ),
      );

      expect(find.widgetWithText(ElevatedButton, 'Grant Permission'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
      expect(find.byIcon(Icons.security), findsOneWidget);
    });

    testWidgets('UI View on permission denied forever displays App Settings and Retry', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlacesErrorView(
              message: 'Location permission is permanently denied. Please allow location in app settings.',
              errorType: PlacesErrorType.locationPermissionDeniedForever,
              onRetry: () {},
              onGrantPermission: () {},
              onOpenSettings: () {},
              onOpenLocationSettings: () {},
            ),
          ),
        ),
      );

      expect(find.widgetWithText(ElevatedButton, 'App Settings'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsNWidgets(2));
    });

    testWidgets('UI View on No Internet displays Retry but NOT Enable GPS', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlacesErrorView(
              message: 'Unable to connect to search service. Please check your internet connection.',
              errorType: PlacesErrorType.noInternet,
              onRetry: () {},
              onGrantPermission: () {},
              onOpenSettings: () {},
              onOpenLocationSettings: () {},
            ),
          ),
        ),
      );

      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
      expect(find.text('Enable GPS'), findsNothing);
      expect(find.byIcon(Icons.wifi_off), findsOneWidget);
    });
  });
}
