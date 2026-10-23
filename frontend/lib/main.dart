import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:blind_assistant/core/router.dart';
import 'package:blind_assistant/core/theme.dart';

void main() {
  runApp(const ProviderScope(child: BlindAssistantApp()));
}

class BlindAssistantApp extends StatelessWidget {
  const BlindAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Blind Assistant',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: appRouter,
    );
  }
}
