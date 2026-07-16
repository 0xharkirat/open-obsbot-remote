// Widget tests for the v2.1 mix (cross-camera) sequencer editor + run bar.
//
// The invariant under test is the feature's whole point: you author SHOTS, the
// bridge derives the camera (and the meanwhile), the editor shows that derived
// camera read-only, a disabled cue drops out, and a forced on-air pan is
// surfaced rather than shown silently.

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

  testWidgets('a cue shows the DERIVED camera (read-only) and its shot', (
    tester,
  ) async {
    // The authored cue names NO camera. The plan does: the solver picked A.
    final mix = MixState.empty.copyWith(
      cues: <MixCue>[const MixCue(presetId: 0, holdS: 20)],
      plan: <PlannedCue>[
        const PlannedCue(cueIndex: 0, cameraSn: 'A', presetId: 0),
      ],
    );
    await _pump(
      tester,
      _bridge(<DeviceState>[
        _device('A', name: 'Vocal'),
        _device('B', name: 'Stage'),
      ], mix: mix),
    );
    // Derived camera chip shows the name and marks itself auto; shot dropdown
    // shows the preset. There is NO camera dropdown to change.
    expect(find.text('Vocal'), findsWidgets);
    expect(find.text('auto'), findsOneWidget);
    expect(find.text('P1  Wide'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
  });

  testWidgets('a disabled cue reads Skipped', (tester) async {
    // Disabled -> dropped from the plan entirely (the colouring re-solves).
    final mix = MixState.empty.copyWith(
      cues: <MixCue>[const MixCue(presetId: 0, holdS: 20, enabled: false)],
      plan: const <PlannedCue>[],
    );
    await _pump(
      tester,
      _bridge(<DeviceState>[_device('A'), _device('B')], mix: mix),
    );
    expect(find.text('Skipped'), findsOneWidget);
  });

  testWidgets('a forced on-air pan surfaces the odd-loop banner', (
    tester,
  ) async {
    final mix = MixState.empty.copyWith(
      cues: <MixCue>[const MixCue(presetId: 0, holdS: 20)],
      plan: <PlannedCue>[
        const PlannedCue(
          cueIndex: 0,
          cameraSn: 'A',
          presetId: 0,
          onAirMove: true,
          moveMs: 3000,
        ),
      ],
      forcedMoveAt: 0,
      forcedReason: 'odd loop with 2 cameras',
    );
    await _pump(
      tester,
      _bridge(<DeviceState>[_device('A'), _device('B')], mix: mix),
    );
    // The engine says it out loud instead of quietly moving on air.
    expect(find.textContaining('pans on air'), findsOneWidget);
  });

  testWidgets('running mix shows the ON AIR run bar with Stop', (tester) async {
    final mix = MixState.empty.copyWith(
      running: true,
      cueIndex: 0, // authored index of the live cue
      cueCount: 2,
      phase: 'holding',
      elapsedS: 5,
      totalS: 20,
      cues: <MixCue>[
        const MixCue(presetId: 0, holdS: 20),
        const MixCue(presetId: 1, holdS: 15),
      ],
      plan: <PlannedCue>[
        const PlannedCue(cueIndex: 0, cameraSn: 'A', presetId: 0),
        const PlannedCue(cueIndex: 1, cameraSn: 'B', presetId: 1),
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
