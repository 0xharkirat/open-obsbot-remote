// Widget tests for the v3 Live studio surface.
//
// The camera bus + TAKE encode the two facts a volunteer must never
// confuse: which camera THIS phone controls (staged) vs which one OBS
// shows (on air). These are separate, and TAKE only commits the cut.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/live_screen.dart';
import 'package:obsbot_control/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeviceState _device(String id, {String name = '', String runStatus = 'run'}) {
  return DeviceState.empty.copyWith(
    deviceId: id,
    sn: id,
    modelDisplay: 'Tiny 2 Lite',
    connected: true,
    runStatus: runStatus,
    friendlyName: name,
  );
}

BridgeState _bridge(List<DeviceState> devices, String active) => BridgeState(
  protocolVersion: '2.0',
  devices: devices,
  activeDeviceId: active,
);

Future<WsClient> _pump(WidgetTester tester, BridgeState bridge) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.binding.setSurfaceSize(const Size(390, 844));
  final client = WsClient()..debugSetBridge(bridge);
  await tester.pumpWidget(MaterialApp(home: LiveScreen(client: client)));
  await tester.pump();
  return client;
}

void main() {
  testWidgets('single camera: no camera bus, no TAKE', (tester) async {
    await _pump(
      tester,
      _bridge(<DeviceState>[_device('A', name: 'Vocal')], 'A'),
    );
    expect(find.text('TAKE'), findsNothing);
    // The bus still shows (its "+" chip is how a second camera gets
    // added), but with nothing to cut to there is no TAKE.
    expect(find.text('Add'), findsOneWidget);
    // Controls still present. The panel selector is icon-only: a
    // three-label segmented control plus TAKE overflows a 360px phone.
    expect(find.byIcon(Icons.control_camera), findsOneWidget);
  });

  testWidgets('two cameras: bus lists both, ON AIR marks the live one', (
    tester,
  ) async {
    await _pump(
      tester,
      _bridge(<DeviceState>[
        _device('A', name: 'Vocal'),
        _device('B', name: 'Stage'),
      ], 'A'),
    );
    expect(find.text('Vocal'), findsWidgets);
    expect(find.text('Stage'), findsWidgets);
    expect(find.text('ON AIR'), findsWidgets);
  });

  testWidgets('staged == on air shows ON AIR (disabled), never TAKE', (
    tester,
  ) async {
    // Default selection falls back to the live camera, so on first
    // render the staged camera IS on air.
    await _pump(
      tester,
      _bridge(<DeviceState>[_device('A'), _device('B')], 'A'),
    );
    expect(find.widgetWithText(FilledButton, 'ON AIR'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'TAKE'), findsNothing);
  });

  testWidgets('staging the off-air camera arms TAKE and leaves air unchanged', (
    tester,
  ) async {
    final client = await _pump(
      tester,
      _bridge(<DeviceState>[_device('A'), _device('B', name: 'Stage')], 'A'),
    );
    // Wider surface so both bus chips fit without horizontal scrolling -
    // this asserts the selection-vs-air logic, not phone layout (covered
    // by the 390px cases above).
    await tester.binding.setSurfaceSize(const Size(700, 844));
    await tester.pump();
    await tester.tap(find.text('Stage'));
    await tester.pump();

    expect(client.selectedDeviceId, 'B');
    expect(client.activeDeviceId, 'A'); // air unchanged - selection is local
    expect(find.widgetWithText(FilledButton, 'TAKE'), findsOneWidget);
  });

  testWidgets('manual TAKE exposes a cut/fade toggle that flips', (
    tester,
  ) async {
    await _pump(
      tester,
      _bridge(<DeviceState>[_device('A'), _device('B')], 'A'),
    );
    await tester.binding.setSurfaceSize(const Size(700, 844));
    await tester.pump();
    // Default is a hard cut (scissors icon); tapping flips to fade (gradient).
    expect(find.byIcon(Icons.content_cut), findsOneWidget);
    expect(find.byIcon(Icons.gradient), findsNothing);
    await tester.tap(find.byIcon(Icons.content_cut));
    await tester.pump();
    expect(find.byIcon(Icons.gradient), findsOneWidget);
  });

  testWidgets('empty preset tiles show the save hint (discoverability)', (
    tester,
  ) async {
    await _pump(tester, _bridge(<DeviceState>[_device('A')], 'A'));
    // Save-on-long-press is invisible without the hint; the v2 tiles
    // carried it and the operator could not find how to save without it.
    expect(find.text('hold to save here'), findsWidgets);
  });

  testWidgets('panel selector swaps presets for the manual controls', (
    tester,
  ) async {
    await _pump(tester, _bridge(<DeviceState>[_device('A')], 'A'));
    expect(find.text('P1'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.control_camera));
    await tester.pump();
    expect(find.text('P1'), findsNothing); // presets gave up the space
    expect(find.text('Fine'), findsOneWidget); // speed segmented now shown
  });

  testWidgets('panel selector reaches REC, and back', (tester) async {
    await _pump(tester, _bridge(<DeviceState>[_device('A')], 'A'));
    await tester.tap(find.byIcon(Icons.fiber_manual_record).first);
    await tester.pump();
    expect(find.text('Recorded on the bridge, not the camera.'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.grid_view));
    await tester.pump();
    expect(find.text('P1'), findsOneWidget);
  });

  group('desk layout (wide surface)', () {
    Future<WsClient> pumpDesk(WidgetTester tester, BridgeState bridge) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final client = WsClient()..debugSetBridge(bridge);
      await tester.pumpWidget(MaterialApp(home: LiveScreen(client: client)));
      await tester.pump();
      return client;
    }

    testWidgets('shows preview + program panes, no Frame toggle', (
      tester,
    ) async {
      final client = await pumpDesk(
        tester,
        _bridge(<DeviceState>[
          _device('A', name: 'Vocal'),
          _device('B', name: 'Stage'),
        ], 'B'),
      );
      expect(find.text('PREVIEW'), findsOneWidget);
      expect(find.text('PROGRAM'), findsOneWidget);
      // Presets and framing are both visible at once, so the phone-only
      // panel selector must not render.
      expect(find.byIcon(Icons.control_camera), findsNothing);
      expect(find.text('Glide'), findsOneWidget);
      // With no explicit selection the staged camera follows the active one,
      // so the big button reads ON AIR; staging the other camera arms TAKE.
      expect(find.text('ON AIR'), findsWidgets);
      client.selectDevice('A');
      await tester.pump();
      expect(find.text('TAKE'), findsOneWidget);
    });

    testWidgets('phone width keeps the single-column layout', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final client = WsClient()
        ..debugSetBridge(
          _bridge(<DeviceState>[_device('A', name: 'Vocal')], 'A'),
        );
      await tester.pumpWidget(MaterialApp(home: LiveScreen(client: client)));
      await tester.pump();
      expect(find.text('PREVIEW'), findsNothing);
      expect(find.byIcon(Icons.control_camera), findsOneWidget);
    });
  });
}
