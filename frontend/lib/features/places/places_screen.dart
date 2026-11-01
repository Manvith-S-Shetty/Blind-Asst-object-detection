import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:blind_assistant/core/theme.dart';
import 'package:blind_assistant/features/places/places_controller.dart';
import 'package:blind_assistant/models/place.dart';
import 'package:blind_assistant/services/places_client.dart';
import 'package:blind_assistant/services/routing_service.dart';

class PlacesScreen extends ConsumerStatefulWidget {
  final PlaceCategory? initialCategory;
  final String? initialQuery;

  const PlacesScreen({
    super.key,
    this.initialCategory,
    this.initialQuery,
  });

  @override
  ConsumerState<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends ConsumerState<PlacesScreen> {
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      final ctrl = ref.read(placesControllerProvider.notifier);
      final cat = widget.initialCategory ?? PlaceCategory.restaurant;
      ctrl.searchNearby(
        category: cat,
        customQuery: widget.initialQuery,
        speakResult: true,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(placesControllerProvider);
    final controller = ref.read(placesControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Places'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh nearby places',
            onPressed: state.isLoading
                ? null
                : () {
                    final cat = state.currentCategory ?? PlaceCategory.restaurant;
                    controller.searchNearby(
                      category: cat,
                      customQuery: state.queryTitle != cat.displayName ? state.queryTitle : null,
                      speakResult: true,
                      forceRefresh: true,
                    );
                  },
          ),
        ],
      ),
      floatingActionButton: state.places.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => controller.announceNextPlace(),
              backgroundColor: Colors.tealAccent,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.skip_next),
              label: const Text(
                'Next Place',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            )
          : null,
      body: SafeArea(
        child: Column(
          children: [
            // Category selector chips (Restaurants, Hospitals, Pharmacies, Bus Stops, Shops, etc.)
            _CategorySelector(
              selectedCategory: state.currentCategory ?? PlaceCategory.restaurant,
              isLoading: state.isLoading,
              onSelectCategory: (cat) {
                controller.searchNearby(category: cat, speakResult: true);
              },
            ),

            // Safety notice banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: Colors.amber.shade900.withValues(alpha: 0.18),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.amber, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Outdoor GPS estimates only. Does not replace camera obstacle perception.',
                      style: TextStyle(
                        color: Colors.amber,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Main body area
            Expanded(
              child: state.isLoading
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.tealAccent),
                          SizedBox(height: 16),
                          Text(
                            'Acquiring GPS and querying OpenStreetMap...',
                            style: TextStyle(color: Colors.white70, fontSize: 16),
                          ),
                        ],
                      ),
                    )
                  : state.errorMessage != null
                      ? _ErrorView(
                          message: state.errorMessage!,
                          errorType: state.errorType,
                          onRetry: () {
                            final cat = state.currentCategory ?? PlaceCategory.restaurant;
                            controller.searchNearby(
                              category: cat,
                              customQuery: state.queryTitle != cat.displayName ? state.queryTitle : null,
                              speakResult: true,
                              forceRefresh: true,
                            );
                          },
                          onGrantPermission: controller.requestLocationPermission,
                          onOpenSettings: controller.openAppSettings,
                          onOpenLocationSettings: controller.openLocationSettings,
                        )
                      : _ResultsView(
                          places: state.places,
                          userLat: state.userPosition?.latitude,
                          userLon: state.userPosition?.longitude,
                          spokenSummary: state.spokenSummary,
                          selectedPlaceIndex: state.currentAnnounceIndex,
                          selectedPlace: state.selectedPlace,
                          walkingRoute: state.walkingRoute,
                          isLoadingRoute: state.isLoadingRoute,
                          mapController: _mapController,
                          onTapPlace: (place) {
                            controller.selectPlaceAndRoute(place, speakRoute: true);
                          },
                          onClearRoute: controller.clearRoute,
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WalkingRouteCard extends StatelessWidget {
  final PlaceResult place;
  final WalkingRouteResult route;
  final VoidCallback onDismiss;

  const _WalkingRouteCard({
    required this.place,
    required this.route,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.tealAccent, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.directions_walk, color: Colors.tealAccent, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Walking Route: ${place.name}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20, color: Colors.white70),
                tooltip: 'Clear route',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: onDismiss,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.teal.shade900,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  route.formattedWalkingDistance,
                  style: const TextStyle(
                    color: Colors.tealAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (route.formattedDuration.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.shade800,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    route.formattedDuration,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
          if (route.steps.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Next step: ${route.steps.first}',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            route.disclaimer,
            style: TextStyle(color: Colors.amber.shade300, fontSize: 10, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

class _CategorySelector extends StatelessWidget {
  final PlaceCategory selectedCategory;
  final bool isLoading;
  final ValueChanged<PlaceCategory> onSelectCategory;

  const _CategorySelector({
    required this.selectedCategory,
    required this.isLoading,
    required this.onSelectCategory,
  });

  @override
  Widget build(BuildContext context) {
    const categories = [
      (PlaceCategory.restaurant, 'Restaurants', Icons.restaurant),
      (PlaceCategory.hospital, 'Hospitals', Icons.local_hospital),
      (PlaceCategory.clinic, 'Clinics', Icons.medical_services),
      (PlaceCategory.pharmacy, 'Pharmacies', Icons.local_pharmacy),
      (PlaceCategory.busStop, 'Bus Stops', Icons.directions_bus),
      (PlaceCategory.railwayStation, 'Train/Metro', Icons.train),
      (PlaceCategory.petrolStation, 'Petrol/Gas', Icons.local_gas_station),
      (PlaceCategory.shop, 'Shops', Icons.storefront),
      (PlaceCategory.cafe, 'Cafés', Icons.local_cafe),
      (PlaceCategory.grocery, 'Groceries', Icons.shopping_basket),
      (PlaceCategory.bank, 'Banks/ATMs', Icons.account_balance),
    ];

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (cat, label, icon) = categories[index];
          final isSelected = cat == selectedCategory;

          return ChoiceChip(
            selected: isSelected,
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: isSelected ? Colors.black : Colors.white70),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? Colors.black : Colors.white,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
            selectedColor: Colors.tealAccent,
            backgroundColor: Colors.grey.shade800,
            onSelected: isLoading ? null : (_) => onSelectCategory(cat),
          );
        },
      ),
    );
  }
}

class _ResultsView extends StatelessWidget {
  final List<PlaceResult> places;
  final double? userLat;
  final double? userLon;
  final String? spokenSummary;
  final int selectedPlaceIndex;
  final PlaceResult? selectedPlace;
  final WalkingRouteResult? walkingRoute;
  final bool isLoadingRoute;
  final MapController mapController;
  final ValueChanged<PlaceResult> onTapPlace;
  final VoidCallback onClearRoute;

  const _ResultsView({
    required this.places,
    this.userLat,
    this.userLon,
    this.spokenSummary,
    required this.selectedPlaceIndex,
    this.selectedPlace,
    this.walkingRoute,
    this.isLoadingRoute = false,
    required this.mapController,
    required this.onTapPlace,
    required this.onClearRoute,
  });

  @override
  Widget build(BuildContext context) {
    if (places.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_off, size: 56, color: Colors.white38),
              const SizedBox(height: 12),
              Text(
                spokenSummary ?? 'No places found nearby in this category.',
                style: const TextStyle(color: Colors.white70, fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // Default center to user position, or first place
    final centerLat = userLat ?? places.first.latitude;
    final centerLon = userLon ?? places.first.longitude;
    final initialCenter = LatLng(centerLat, centerLon);

    return Column(
      children: [
        // Interactive flutter_map widget with OpenStreetMap tiles & attribution
        SizedBox(
          height: 220,
          child: Stack(
            children: [
              FlutterMap(
                mapController: mapController,
                options: MapOptions(
                  initialCenter: initialCenter,
                  initialZoom: 15.0,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.blindassistant.app',
                  ),
                  if (walkingRoute != null && walkingRoute!.polylinePoints.isNotEmpty)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: walkingRoute!.polylinePoints,
                          strokeWidth: 4.5,
                          color: Colors.tealAccent,
                        ),
                      ],
                    ),
                  MarkerLayer(
                    markers: [
                      // User Current Location Pin
                      if (userLat != null && userLon != null)
                        Marker(
                          point: LatLng(userLat!, userLon!),
                          width: 44,
                          height: 44,
                          child: Semantics(
                            label: 'Your current GPS location',
                            child: const _UserLocationPin(),
                          ),
                        ),
                      // Place Markers
                      for (int i = 0; i < places.length; i++)
                        Marker(
                          point: LatLng(places[i].latitude, places[i].longitude),
                          width: 36,
                          height: 36,
                          child: GestureDetector(
                            onTap: () => onTapPlace(places[i]),
                            child: _PlaceMarkerPin(
                              index: i + 1,
                              isSelected: i == selectedPlaceIndex,
                              place: places[i],
                            ),
                          ),
                        ),
                    ],
                  ),
                  const RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution(
                        '© OpenStreetMap contributors',
                      ),
                    ],
                  ),
                ],
              ),
              // Map overlay badge showing nearest distance
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.tealAccent, width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.map, size: 14, color: Colors.tealAccent),
                      const SizedBox(width: 6),
                      Text(
                        'OpenStreetMap (${places.length} places)',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // Route Loading or Route Summary Card
        if (isLoadingRoute)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.teal.shade900.withValues(alpha: 0.4),
            child: const Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.tealAccent),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Calculating pedestrian walking route via OSRM...',
                    style: TextStyle(color: Colors.tealAccent, fontSize: 13),
                  ),
                ),
              ],
            ),
          )
        else if (walkingRoute != null && walkingRoute!.isSuccess && selectedPlace != null)
          _WalkingRouteCard(
            place: selectedPlace!,
            route: walkingRoute!,
            onDismiss: onClearRoute,
          ),

        // Spoken Summary Bar
        if (spokenSummary != null && walkingRoute == null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.grey.shade900,
            child: Row(
              children: [
                const Icon(Icons.volume_up, color: Colors.tealAccent, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    spokenSummary!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
              ],
            ),
          ),

        // Places List sorted by nearest first
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: places.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final place = places[index];
              return _PlaceCard(
                place: place,
                isNearest: index == 0,
                isSelected: index == selectedPlaceIndex,
                onTap: () {
                  onTapPlace(place);
                  mapController.move(LatLng(place.latitude, place.longitude), 16.0);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _UserLocationPin extends StatelessWidget {
  const _UserLocationPin();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.blueAccent.withValues(alpha: 0.3),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: Colors.blueAccent,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaceMarkerPin extends StatelessWidget {
  final int index;
  final bool isSelected;
  final PlaceResult place;

  const _PlaceMarkerPin({
    required this.index,
    required this.isSelected,
    required this.place,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: isSelected ? Colors.amberAccent : Colors.tealAccent,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.black,
          width: isSelected ? 2.5 : 1.5,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: Text(
          '$index',
          style: const TextStyle(
            color: Colors.black,
            fontSize: 13,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _PlaceCard extends StatelessWidget {
  final PlaceResult place;
  final bool isNearest;
  final bool isSelected;
  final VoidCallback onTap;

  const _PlaceCard({
    required this.place,
    required this.isNearest,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${place.name}, ${place.formattedDistance} ${place.cardinalDirection}. Tap to hear details.',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.amber.shade900.withValues(alpha: 0.3)
                : (isNearest
                    ? Colors.teal.shade900.withValues(alpha: 0.35)
                    : Colors.grey.shade900),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? Colors.amberAccent
                  : (isNearest ? Colors.tealAccent : Colors.white12),
              width: (isSelected || isNearest) ? 1.8 : 1.0,
            ),
          ),
          child: Row(
            children: [
              // Direction & Proximity Indicator
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.amberAccent
                      : (isNearest ? Colors.tealAccent : Colors.white10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _iconForBearing(place.bearingDegrees),
                      size: 24,
                      color: (isSelected || isNearest) ? Colors.black : Colors.tealAccent,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      place.formattedDistance,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: (isSelected || isNearest) ? Colors.black : Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),

              // Details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isNearest)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          color: Colors.tealAccent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'NEAREST',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    Text(
                      place.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${place.cardinalDirection.toUpperCase()} · ${place.category.displayName}',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    if (place.address != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        place.address!,
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.volume_up, color: Colors.tealAccent),
                tooltip: 'Speak place details',
                onPressed: onTap,
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconForBearing(double bearing) {
    final b = (bearing % 360 + 360) % 360;
    if (b >= 337.5 || b < 22.5) return Icons.arrow_upward;
    if (b >= 22.5 && b < 67.5) return Icons.north_east;
    if (b >= 67.5 && b < 112.5) return Icons.arrow_forward;
    if (b >= 112.5 && b < 157.5) return Icons.south_east;
    if (b >= 157.5 && b < 202.5) return Icons.arrow_downward;
    if (b >= 202.5 && b < 247.5) return Icons.south_west;
    if (b >= 247.5 && b < 292.5) return Icons.arrow_back;
    return Icons.north_west;
  }
}

typedef _ErrorView = PlacesErrorView;

class PlacesErrorView extends StatelessWidget {
  final String message;
  final PlacesErrorType errorType;
  final VoidCallback onRetry;
  final VoidCallback onGrantPermission;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenLocationSettings;

  const PlacesErrorView({
    super.key,
    required this.message,
    required this.errorType,
    required this.onRetry,
    required this.onGrantPermission,
    required this.onOpenSettings,
    required this.onOpenLocationSettings,
  });

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color iconColor;
    final Widget? actionButton;

    switch (errorType) {
      case PlacesErrorType.gpsDisabled:
        icon = Icons.location_disabled;
        iconColor = AppTheme.urgentColor;
        actionButton = ElevatedButton.icon(
          onPressed: onOpenLocationSettings,
          icon: const Icon(Icons.location_on),
          label: const Text('Enable GPS'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade700),
        );
        break;

      case PlacesErrorType.locationPermissionDenied:
        icon = Icons.security;
        iconColor = Colors.amberAccent;
        actionButton = ElevatedButton.icon(
          onPressed: onGrantPermission,
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('Grant Permission'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.amber.shade800),
        );
        break;

      case PlacesErrorType.locationPermissionDeniedForever:
        icon = Icons.settings;
        iconColor = AppTheme.urgentColor;
        actionButton = ElevatedButton.icon(
          onPressed: onOpenSettings,
          icon: const Icon(Icons.settings),
          label: const Text('App Settings'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.amber.shade800),
        );
        break;

      case PlacesErrorType.overpassUnavailable:
        icon = Icons.cloud_off;
        iconColor = Colors.orangeAccent;
        actionButton = null;
        break;

      case PlacesErrorType.overpassRateLimited:
        icon = Icons.hourglass_empty;
        iconColor = Colors.amberAccent;
        actionButton = null;
        break;

      case PlacesErrorType.noInternet:
        icon = Icons.wifi_off;
        iconColor = Colors.orangeAccent;
        actionButton = null;
        break;

      case PlacesErrorType.gpsTimeout:
      case PlacesErrorType.gpsUnavailable:
        icon = Icons.location_searching;
        iconColor = Colors.amberAccent;
        actionButton = null;
        break;

      case PlacesErrorType.none:
      case PlacesErrorType.unknown:
        icon = Icons.error_outline;
        iconColor = AppTheme.urgentColor;
        actionButton = null;
        break;
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 52,
              color: iconColor,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (actionButton != null) ...[
                  actionButton,
                  const SizedBox(width: 12),
                ],
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
