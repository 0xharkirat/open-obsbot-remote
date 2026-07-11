// Widget tests for the v3 mix (cross-camera) sequencer editor + run bar.
//
// The invariant under test is the feature's whole point: a mix is built from
// cues that name a program camera and a shot, it needs two cameras, and while
// running the ON AIR run bar surfaces the live cue.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/mix_sequencer_screen.dart';
import 'package:obsbot_control/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

PresetEntry _preset(int id, String name) =>
    PresetEntry(id: id, name: name, yaw: 0, pitch: 0, roll: 0, zoom: 1);

DeviceState _device(String id, {String name = ''}) =>
    DeviceState.empty.copyWith(
      deviceId: id,
      sn: id,
      modelDisplay: 'Tiny 2 Lite',
      connected: true,
      runStatus: 'run',
      friendlyName: name,
      presets: <PresetEntry>[_preset(0, 'Wide'), _preset(1, 'Close')],
    );

BridgeState _bridge(List<DeviceState> devices, {MixState? mix}) => BridgeState(
  protocolVersion: '2.0',
  devices: devices,
  activeDeviceId: devices.isEmpty ? '' : devices.first.deviceId,
  mix: mix ?? MixState.empty,
);

Future<WsClient> _pump(WidgetTester tester, BridgeState bridge) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.binding.setSurfaceSize(const Size(430, 900));
  final client = WsClient()..debugSetBridge(bridge);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: MixEditor(client: client)),
    ),
  );
  await tester.pump();
  return client;
}

void main() {
  testWidgets('one camera: shows the needs-two-cameras message', (
    tester,
  ) async {
    await _pump(tester, _bridge(<DeviceState>[_device('A', name: 'Vocal')]));
    expect(find.text('Mix needs two cameras'), findsOneWidget);
    expect(find.text('Add cue'), findsNothing);
  });

  testWidgets('two cameras, no cues: empty state + disabled Run', (
    tester,
  ) async {
    await _pump(
      tester,
      _bridge(<DeviceState>[
        _device('A', name: 'Vocal'),
        _device('B', name: 'Stage'),
      ]),
    );
    expect(find.text('Build a cross-camera show'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Add cue'), findsOneWidget);
    final run = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Run'),
    );
    expect(run.onPressed, isNull); // no cues -> Run disabled
  });

  testWidgets('a cue renders its program camera and shot', (tester) async {
    final mix = MixState.empty.copyWith(
      cues: <MixCue>[
        const MixCue(cameraSn: 'A', presetId: 0, moveMs: 800, holdS: 20),
      ],
    );
    await _pump(
      tester,
      _bridge(<DeviceState>[
        _device('A', name: 'Vocal'),
        _device('B', name: 'Stage'),
      ], mix: mix),
    );
    // The program camera dropdown shows the camera name; the shot dropdown the preset.
    expect(find.text('Vocal'), findsWidgets);
    expect(find.text('P1  Wide'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
  });

  testWidgets('running mix shows the ON AIR run bar with Stop', (tester) async {
    final mix = MixState.empty.copyWith(
      running: true,
      cueIndex: 0,
      cueCount: 2,
      phase: 'holding',
      elapsedS: 5,
      totalS: 20,
      cues: <MixCue>[
        const MixCue(cameraSn: 'A', presetId: 0, holdS: 20),
        const MixCue(cameraSn: 'B', presetId: 0, holdS: 15),
      ],
    );
    await _pump(
      tester,
      _bridge(<DeviceState>[
        _device('A', name: 'Vocal'),
        _device('B', name: 'Stage'),
      ], mix: mix),
    );
    expect(find.text('ON AIR'), findsOneWidget);
    expect(find.text('cue 1/2'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Stop'), findsWidgets);
  });
}
