// Device-runnable end-to-end smoke for the v3 Live studio.
//
// Unlike the widget tests under test/, this runs through
// IntegrationTestWidgetsFlutterBinding, so it executes on a real target
// (`flutter test integration_test` on a booted device / Chrome, or under
// an agent driver). It proves the studio surface renders and the core
// switcher invariant holds under the real engine: staging an off-air
// camera arms TAKE while the on-air feed is untouched.
//
// It builds the widget tree directly (a seeded, offline WsClient) rather
// than calling app main(), so it never installs MarionetteBinding - one
// WidgetsBinding per process.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:obsbot_control/live_screen.dart';
import 'package:obsbot_control/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeviceState _device(String id, {String name = ''}) =>
    DeviceState.empty.copyWith(
      deviceId: id,
      sn: id,
      modelDisplay: 'Tiny 2 Lite',
      connected: true,
      runStatus: 'run',
      friendlyName: name,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('two-camera studio: staging off-air arms TAKE, air unchanged', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.binding.setSurfaceSize(const Size(700, 844));
    final client = WsClient()
      ..debugSetBridge(
        BridgeState(
          protocolVersion: '2.0',
          devices: <DeviceState>[
            _device('A', name: 'Vocal'),
            _device('B', name: 'Stage'),
          ],
          activeDeviceId: 'A',
        ),
      );

    await tester.pumpWidget(MaterialApp(home: LiveScreen(client: client)));
    // pump() not pumpAndSettle(): the live preview never "settles" (it is a
    // continuously streaming feed), so pumpAndSettle would time out.
    await tester.pump();

    // Studio renders both cameras on the bus.
    expect(find.text('Vocal'), findsWidgets);
    expect(find.text('Stage'), findsWidgets);

    // Stage the off-air camera: selection is local, air must not move.
    await tester.tap(find.text('Stage'));
    await tester.pump();

    expect(client.selectedDeviceId, 'B');
    expect(client.activeDeviceId, 'A');
    expect(find.widgetWithText(FilledButton, 'TAKE'), findsOneWidget);
  });
}
