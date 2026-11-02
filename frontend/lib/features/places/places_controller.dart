import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:blind_assistant/core/providers.dart';
import 'package:blind_assistant/models/place.dart';
import 'package:blind_assistant/services/location_service.dart';
import 'package:blind_assistant/services/places_client.dart';
import 'package:blind_assistant/services/routing_service.dart';
import 'package:blind_assistant/services/tts_service.dart';

class PlacesState {
  final bool isLoading;
  final List<PlaceResult> places;
  final Position? userPosition;
  final PlaceCategory? currentCategory;
  final String? queryTitle;
  final String? errorMessage;
  final PlacesErrorType errorType;
  final String? spokenSummary;
  final LocationServiceStatus? locationStatus;
  final int currentAnnounceIndex;
  final PlaceResult? selectedPlace;
  final WalkingRouteResult? walkingRoute;
  final bool isLoadingRoute;

  const PlacesState({
    this.isLoading = false,
    this.places = const [],
    this.userPosition,
    this.currentCategory,
    this.queryTitle,
    this.errorMessage,
    this.errorType = PlacesErrorType.none,
    this.spokenSummary,
    this.locationStatus,
    this.currentAnnounceIndex = 0,
    this.selectedPlace,
    this.walkingRoute,
    this.isLoadingRoute = false,
  });

  PlacesState copyWith({
    bool? isLoading,
    List<PlaceResult>? places,
    Position? userPosition,
    PlaceCategory? currentCategory,
    String? queryTitle,
    String? errorMessage,
    PlacesErrorType? errorType,
    String? spokenSummary,
    LocationServiceStatus? locationStatus,
    int? currentAnnounceIndex,
    PlaceResult? selectedPlace,
    WalkingRouteResult? walkingRoute,
    bool? isLoadingRoute,
    bool clearRoute = false,
    bool clearError = false,
  }) =>
      PlacesState(
        isLoading: isLoading ?? this.isLoading,
        places: places ?? this.places,
        userPosition: userPosition ?? this.userPosition,
        currentCategory: currentCategory ?? this.currentCategory,
        queryTitle: queryTitle ?? this.queryTitle,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        errorType: clearError ? PlacesErrorType.none : (errorType ?? this.errorType),
        spokenSummary: spokenSummary ?? this.spokenSummary,
        locationStatus: locationStatus ?? this.locationStatus,
        currentAnnounceIndex: currentAnnounceIndex ?? this.currentAnnounceIndex,
        selectedPlace: clearRoute ? null : (selectedPlace ?? this.selectedPlace),
        walkingRoute: clearRoute ? null : (walkingRoute ?? this.walkingRoute),
        isLoadingRoute: isLoadingRoute ?? this.isLoadingRoute,
      );
}

class PlacesController extends StateNotifier<PlacesState> {
  final LocationService _locationService;
  final PlacesClient _placesClient;
  final RoutingService _routingService;
  final TtsService _ttsService;

  PlacesController({
    required LocationService locationService,
    required PlacesClient placesClient,
    RoutingService? routingService,
    required TtsService ttsService,
  })  : _locationService = locationService,
        _placesClient = placesClient,
        _routingService = routingService ?? RoutingService(),
        _ttsService = ttsService,
        super(const PlacesState());

  /// Performs nearby place discovery and voice announcement.
  ///
  /// INVARIANTS:
  /// - Non-blocking: camera perception and YOLO navigation remain uninterrupted.
  /// - Explicit distinction: speaks geographic straight-line distance; never claims a safe path.
  Future<void> searchNearby({
    required PlaceCategory category,
    String? customQuery,
    bool speakResult = true,
    bool forceRefresh = false,
  }) async {
    final searchLabel = customQuery != null && customQuery.isNotEmpty
        ? customQuery
        : category.displayName;

    state = state.copyWith(
      isLoading: true,
      currentCategory: category,
      queryTitle: searchLabel,
      clearError: true,
      spokenSummary: null,
      currentAnnounceIndex: 0,
    );

    if (speakResult) {
      await _ttsService.speak(
        'Getting GPS position...',
        interrupt: false,
      );
    }

    // 1. Acquire current GPS position
    final locResult = await _locationService.getCurrentPosition();

    if (!locResult.isSuccess || locResult.position == null) {
      final PlacesErrorType gpsError = switch (locResult.status) {
        LocationServiceStatus.serviceDisabled => PlacesErrorType.gpsDisabled,
        LocationServiceStatus.permissionDenied => PlacesErrorType.locationPermissionDenied,
        LocationServiceStatus.permissionDeniedForever => PlacesErrorType.locationPermissionDeniedForever,
        LocationServiceStatus.timeout => PlacesErrorType.gpsTimeout,
        _ => PlacesErrorType.gpsUnavailable,
      };

      final msg = locResult.errorMessage ?? 'Unable to acquire GPS location.';
      state = state.copyWith(
        isLoading: false,
        errorMessage: msg,
        errorType: gpsError,
        locationStatus: locResult.status,
      );

      if (speakResult) {
        final spokenNotice = switch (locResult.status) {
          LocationServiceStatus.serviceDisabled =>
            'Location is turned off. Please enable GPS in device settings.',
          LocationServiceStatus.permissionDenied =>
            'Location permission is required to find nearby places.',
          LocationServiceStatus.permissionDeniedForever =>
            'Location permission is permanently denied. Please allow location in settings.',
          LocationServiceStatus.timeout =>
            'GPS location timed out. Please try again outdoors.',
          _ => 'Unable to determine your GPS location.',
        };
        await _ttsService.speak(spokenNotice, interrupt: false);
      }
      return;
    }

    final pos = locResult.position!;
    state = state.copyWith(
      userPosition: pos,
      locationStatus: LocationServiceStatus.ready,
      clearError: true,
    );

    if (speakResult) {
      await _ttsService.speak(
        'Searching for $searchLabel nearby...',
        interrupt: false,
      );
    }

    // 2. Query places provider (OpenStreetMap Overpass with multi-endpoint failover and caching)
    final placesResult = await _placesClient.searchNearby(
      userLat: pos.latitude,
      userLon: pos.longitude,
      category: category,
      customQuery: customQuery,
      forceRefresh: forceRefresh,
    );

    if (!placesResult.isSuccess) {
      final msg = placesResult.errorMessage ??
          'Nearby search service is temporarily unavailable. Please try again later.';
      state = state.copyWith(
        isLoading: false,
        errorMessage: msg,
        errorType: placesResult.errorType,
      );
      if (speakResult) {
        await _ttsService.speak(msg, interrupt: false);
      }
      return;
    }

    final places = placesResult.places;

    if (places.isEmpty) {
      final summary = 'No ${searchLabel.toLowerCase()}s found within 1 kilometer.';
      state = state.copyWith(
        isLoading: false,
        places: const [],
        spokenSummary: summary,
        clearError: true,
      );
      if (speakResult) {
        await _ttsService.speak(summary, interrupt: false);
      }
      return;
    }

    // 3. Formulate concise spoken summary of nearest place
    final nearest = places.first;
    final count = places.length;
    final summary = count == 1
        ? 'Found 1 place nearby: ${nearest.toSpokenDescription()}'
        : 'Found $count places nearby. Nearest is ${nearest.toSpokenDescription()} Say "next" to hear more.';

    state = state.copyWith(
      isLoading: false,
      places: places,
      spokenSummary: summary,
      clearError: true,
      currentAnnounceIndex: 0,
    );

    if (speakResult) {
      await _ttsService.speak(summary, interrupt: false);
    }
  }

  /// Requests location permission and immediately retries the current search if granted.
  Future<void> requestLocationPermission() async {
    final permission = await _locationService.requestPermission();
    if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
      final cat = state.currentCategory ?? PlaceCategory.restaurant;
      await searchNearby(
        category: cat,
        customQuery: state.queryTitle != cat.displayName ? state.queryTitle : null,
        speakResult: true,
        forceRefresh: true,
      );
    }
  }

  /// Speaks aloud the detailed summary of a specific place result.
  Future<void> announcePlace(PlaceResult place) async {
    final idx = state.places.indexOf(place);
    if (idx >= 0) {
      state = state.copyWith(currentAnnounceIndex: idx);
    }
    final addressPart = place.address != null ? 'at ${place.address}.' : '';
    final text = '${place.name}, approximately ${place.formattedDistance} to your ${place.cardinalDirection}. $addressPart Geographic estimate only. Please be mindful of obstacles.';
    await _ttsService.speak(text, interrupt: true);
  }

  /// Speaks aloud the next place result in sequence (fulfills requirement 8).
  Future<void> announceNextPlace() async {
    if (state.places.isEmpty) {
      await _ttsService.speak(
        'No nearby places found. Try saying find restaurants, hospitals, pharmacies, bus stops, or shops.',
        interrupt: true,
      );
      return;
    }

    final nextIndex = (state.currentAnnounceIndex + 1) % state.places.length;
    state = state.copyWith(currentAnnounceIndex: nextIndex);

    final place = state.places[nextIndex];
    final prefix = nextIndex == 0
        ? 'Starting from the beginning. Place 1 of ${state.places.length}: '
        : 'Place ${nextIndex + 1} of ${state.places.length}: ';
    final text = '$prefix${place.toSpokenDescription()}';
    await _ttsService.speak(text, interrupt: true);
  }

  /// Repeats aloud the currently selected place result (fulfills Phase 7 req 8).
  Future<void> repeatCurrentPlace() async {
    if (state.places.isEmpty) {
      await _ttsService.speak(
        'No nearby places to repeat. Try asking for nearby restaurants, hospitals, pharmacies, or stations.',
        interrupt: true,
      );
      return;
    }

    final index = state.currentAnnounceIndex.clamp(0, state.places.length - 1);
    final place = state.places[index];
    final text = 'Repeating place ${index + 1} of ${state.places.length}: ${place.toSpokenDescription()}';
    await _ttsService.speak(text, interrupt: true);
  }

  /// Selects a place and optionally fetches walking route via OSRM.
  Future<void> selectPlaceAndRoute(PlaceResult place, {bool speakRoute = true}) async {
    final idx = state.places.indexOf(place);
    if (idx >= 0) {
      state = state.copyWith(
        currentAnnounceIndex: idx,
        selectedPlace: place,
      );
    }
    await announcePlace(place);

    final pos = state.userPosition;
    if (pos != null) {
      state = state.copyWith(isLoadingRoute: true);
      final route = await _routingService.getWalkingRoute(
        startLat: pos.latitude,
        startLon: pos.longitude,
        destLat: place.latitude,
        destLon: place.longitude,
      );

      state = state.copyWith(
        isLoadingRoute: false,
        walkingRoute: route,
      );

      if (speakRoute && route.isSuccess && route.walkingDistanceMeters != null) {
        final dist = route.formattedWalkingDistance;
        final dur = route.formattedDuration;
        final count = route.steps.length;
        final first = route.steps.isNotEmpty ? route.steps.first : '';
        await _ttsService.speak(
          'Walking route found: $dist, $dur. $count maneuvers. First step: $first. Experimental walking estimate only. Always observe real-world surroundings.',
          interrupt: false,
        );
      }
    }
  }

  /// Clears the currently active walking route from map and state.
  void clearRoute() {
    state = state.copyWith(clearRoute: true);
  }

  /// Opens the device settings for permissions.
  Future<void> openAppSettings() => _locationService.openAppSettings();

  /// Opens device location settings (GPS toggle).
  Future<void> openLocationSettings() => _locationService.openLocationSettings();
}

final locationServiceProvider = Provider<LocationService>((ref) {
  return const LocationService();
});

final placesClientProvider = Provider<PlacesClient>((ref) {
  return PlacesClient();
});

final routingServiceProvider = Provider<RoutingService>((ref) {
  return RoutingService();
});

final placesControllerProvider =
    StateNotifierProvider<PlacesController, PlacesState>((ref) {
  final locService = ref.read(locationServiceProvider);
  final placesClient = ref.read(placesClientProvider);
  final routingService = ref.read(routingServiceProvider);
  final tts = ref.read(ttsServiceProvider);

  return PlacesController(
    locationService: locService,
    placesClient: placesClient,
    routingService: routingService,
    ttsService: tts,
  );
});
