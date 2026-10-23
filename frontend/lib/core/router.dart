import 'package:go_router/go_router.dart';
import 'package:blind_assistant/features/navigation/navigation_screen.dart';
import 'package:blind_assistant/features/settings/settings_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const NavigationScreen()),
    GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
  ],
);
