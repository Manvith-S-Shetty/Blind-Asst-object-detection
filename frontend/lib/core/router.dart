import 'package:go_router/go_router.dart';
import 'package:blind_assistant/features/navigation/navigation_screen.dart';
import 'package:blind_assistant/features/places/places_screen.dart';
import 'package:blind_assistant/features/settings/settings_screen.dart';
import 'package:blind_assistant/models/place.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const NavigationScreen()),
    GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
    GoRoute(
      path: '/places',
      builder: (context, state) {
        final catStr = state.uri.queryParameters['category'];
        final query = state.uri.queryParameters['query'];
        final category = catStr != null
            ? PlaceCategory.values.firstWhere(
                (c) => c.name.toLowerCase() == catStr.toLowerCase(),
                orElse: () => PlaceCategory.restaurant,
              )
            : null;
        return PlacesScreen(
          initialCategory: category,
          initialQuery: query,
        );
      },
    ),
  ],
);
