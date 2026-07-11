// Widget tests for the v2 multi-camera device picker.
//
// The picker's contract:
//   - invisible with 0-1 cameras (single-cam UX is pixel-identical v1)
//   - lists every camera; tap selects the camera THIS phone controls
//   - LIVE chip marks the OBS-routed camera; sleep shows a bedtime icon
//   - "Make ... live" is a separate, explicit verb

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/widgets/app_bar_actions.dart';
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
  final client = WsClient()..debugSetBridge(bridge);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: <Widget>[DevicePickerMenu(client: client)]),
      ),
    ),
  );
  return client;
}

void main() {
  testWidgets('hidden with a single camera', (tester) async {
    await _pump(tester, _bridge(<DeviceState>[_device('CAM_A')], 'CAM_A'));
    expect(find.byIcon(Icons.cameraswitch), findsNothing);
  });

  testWidgets('visible with two cameras, lists both with ON AIR chip', (
    tester,
  ) async {
    await _pump(
      tester,
      _bridge(<DeviceState>[
        _device('CAM_A', name: 'Vocal'),
        _device('CAM_B'),
      ], 'CAM_A'),
    );
    await tester.tap(find.byIcon(Icons.cameraswitch));
    await tester.pumpAndSettle();

    expect(find.text('Vocal'), findsOneWidget);
    expect(find.text('Tiny 2 Lite (AM_B)'), findsOneWidget); // last-4 of sn
    expect(find.text('ON AIR'), findsOneWidget);
  });

  testWidgets('tapping a camera selects it without changing live', (
    tester,
  ) async {
    final client = await _pump(
      tester,
      _bridge(<DeviceState>[
        _device('CAM_A', name: 'Vocal'),
        _device('CAM_B'),
      ], 'CAM_A'),
    );
    await tester.tap(find.byIcon(Icons.cameraswitch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tiny 2 Lite (AM_B)'));
    await tester.pumpAndSettle();

    expect(client.selectedDeviceId, 'CAM_B');
    expect(client.activeDeviceId, 'CAM_A'); // live unchanged
    expect(client.state.deviceId, 'CAM_B'); // controls now point at B
  });

  testWidgets('every row carries a status dot; on/off is visible '
      'independently of the ON AIR chip', (tester) async {
    await _pump(
      tester,
      _bridge(<DeviceState>[
        _device('CAM_A'),
        _device('CAM_B', runStatus: 'sleep'),
      ], 'CAM_A'),
    );
    await tester.tap(find.byIcon(Icons.cameraswitch));
    await tester.pumpAndSettle();
    // One dot per camera row: running and sleeping cameras both show
    // their state, so a camera without the ON AIR chip is not read as
    // "off" (the gurdwara field report behind this design).
    final dots = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => c.constraints?.maxWidth == 8 ||
            (c.decoration is BoxDecoration &&
                (c.decoration! as BoxDecoration).shape == BoxShape.circle))
        .length;
    expect(dots >= 2, isTrue);
  });

  testWidgets('put-on-air row is disabled when selected camera is on air', (
    tester,
  ) async {
    await _pump(
      tester,
      _bridge(<DeviceState>[_device('CAM_A'), _device('CAM_B')], 'CAM_A'),
    );
    // Default selection falls back to the live camera (CAM_A).
    await tester.tap(find.byIcon(Icons.cameraswitch));
    await tester.pumpAndSettle();
    expect(find.textContaining('is on air'), findsOneWidget);
  });
}
