// Widget tests for PinEntryScreen post-forui migration (v1.2 PR I).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
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

  testWidgets('pair screen uses forui FScaffold + FHeader + FButton',
      (tester) async {
    _initPrefs();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    final client = _StubWsClient();
    await tester.pumpWidget(
      MaterialApp(home: PinEntryScreen(client: client)),
    );
    await tester.pump();
    // forui shell is rendered.
    expect(find.byType(FScaffold), findsOneWidget);
    expect(find.byType(FButton), findsOneWidget);
    // FHeader.nested renders our title.
    expect(find.text('Pair with bridge'), findsOneWidget);
    // The Pair button shows "Pair" until pin entered + busy.
    expect(find.text('Pair'), findsOneWidget);
  });
}
