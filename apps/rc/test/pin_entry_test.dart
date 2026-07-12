// Widget tests for PinEntryScreen (pure Material as of v3).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/pin_entry_screen.dart';
import 'package:obsbot_control/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _initPrefs() {
  SharedPreferences.setMockInitialValues(<String, Object>{});
}

class _StubWsClient extends WsClient {
  _StubWsClient() : super();
}

void main() {
  setUp(_initPrefs);

  testWidgets(
    'pair screen renders a Material Scaffold, title, and Pair button',
    (tester) async {
      _initPrefs();
      await tester.binding.setSurfaceSize(const Size(400, 800));
      final client = _StubWsClient();
      await tester.pumpWidget(
        MaterialApp(home: PinEntryScreen(client: client)),
      );
      await tester.pump();

      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.text('Pair with bridge'), findsOneWidget);
      expect(find.text('Pair'), findsOneWidget);
      // A six-digit field is present.
      expect(find.byType(TextField), findsOneWidget);
    },
  );
}
