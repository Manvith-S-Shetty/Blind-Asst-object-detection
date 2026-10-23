import 'package:flutter/material.dart';

/// High-contrast, large-text theme. This is a voice-first app used by
/// blind/low-vision users, so visual design still matters for low-vision
/// users, caregivers, and demo/defense purposes — favor big touch targets
/// and strong contrast over density.
class AppTheme {
  static const Color urgentColor = Color(0xFFFF3B30);
  static const Color warnColor = Color(0xFFFFCC00);
  static const Color infoColor = Color(0xFF4CD964);
  static const Color background = Color(0xFF000000);
  static const Color surface = Color(0xFF1C1C1E);

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: infoColor,
          surface: surface,
          error: urgentColor,
        ),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
          headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: Colors.white),
          bodyLarge: TextStyle(fontSize: 20, color: Colors.white),
          bodyMedium: TextStyle(fontSize: 18, color: Colors.white70),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(88, 88),
            shape: const CircleBorder(),
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      );
}
