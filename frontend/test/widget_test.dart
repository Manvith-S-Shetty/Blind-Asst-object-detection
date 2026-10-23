// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:blind_assistant/main.dart';

void main() {
  testWidgets('App builds without error', (WidgetTester tester) async {
    // Build the app.
    await tester.pumpWidget(const ProviderScope(child: BlindAssistantApp()));
    // Verify that the app widget is present.
    expect(find.byType(BlindAssistantApp), findsOneWidget);
  });
}

