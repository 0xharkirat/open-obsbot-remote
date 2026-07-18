// Widget tests for generic (non-OBSBOT) video sources: the add-camera
// picker sheet and the control-less Live-screen treatment.
//
// A video source is session-less on the bridge - every control command
// would come back not_found - so the UI contract is: preview + TAKE
// only, with add via the bus "+" chip and remove via chip long-press.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/live_screen.dart';
import 'package:obsbot_control/source_picker_sheet.dart';
import 'package:obsbot_control/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeviceState _obsbot(String id, {String name = ''}) {
  return DeviceState.empty.copyWith(
    deviceId: id,
    sn: id,
    modelDisplay: 'Tiny 2 Lite',
    connected: true,
    runStatus: 'run',
    friendlyName: name,
  );
}

DeviceState _video(String uid, String label) {
  return DeviceState.empty.copyWith(
    deviceId: 'av:$uid',
    kind: 'video',
    sn: 'av:$uid',
    connected: true,
    runStatus: 'run',
    friendlyName: label,
  );
}

BridgeState _bridge(List<DeviceState> devices, String active) => BridgeState(
  protocolVersion: '2.0',
  devices: devices,
  activeDeviceId: active,
);

Future<WsClient> _pumpLive(WidgetTester tester, BridgeState bridge) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.binding.setSurfaceSize(const Size(390, 844));
  final client = WsClient()..debugSetBridge(bridge);
  await tester.pumpWidget(MaterialApp(home: LiveScreen(client: client)));
  await tester.pump();
  return client;
}

/// Pumps a host page with a button that opens [SourcePickerSheet] with
/// the given stubs, then opens it.
Future<void> _openSheet(
  WidgetTester tester, {
  required Future<List<AvailableSource>?> Function() load,
  Future<bool> Function(AvailableSource)? add,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext ctx) => Center(
            child: FilledButton(
              onPressed: () => showModalBottomSheet<void>(
                context: ctx,
                builder: (_) => SourcePickerSheet(
                  load: load,
                  add: add ?? (_) async => true,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('SourcePickerSheet', () {
    const sources = <AvailableSource>[
      AvailableSource(
        uniqueId: 'tiny',
        name: 'OBSBOT Tiny 2 Lite Camera',
        obsbot: true,
        inUse: true,
      ),
      AvailableSource(
        uniqueId: 'used',
        name: 'FaceTime HD Camera',
        obsbot: false,
        inUse: true,
      ),
      AvailableSource(
        uniqueId: 'camo',
        name: 'Camo Studio Virtual Camera',
        obsbot: false,
        inUse: false,
      ),
    ];

    testWidgets('lists rows; OBSBOT + in-use rows disabled with a reason', (
      tester,
    ) async {
      await _openSheet(tester, load: () async => sources);

      expect(find.text('OBSBOT Tiny 2 Lite Camera'), findsOneWidget);
      expect(find.text('FaceTime HD Camera'), findsOneWidget);
      expect(find.text('Camo Studio Virtual Camera'), findsOneWidget);
      // Reason labels on the disabled rows.
      expect(find.text('OBSBOT camera - connects on its own'), findsOneWidget);
      expect(find.text('Already added'), findsOneWidget);

      bool enabledOf(String title) => tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text(title),
              matching: find.byType(ListTile),
            ),
          )
          .enabled;
      expect(enabledOf('OBSBOT Tiny 2 Lite Camera'), isFalse);
      expect(enabledOf('FaceTime HD Camera'), isFalse);
      expect(enabledOf('Camo Studio Virtual Camera'), isTrue);
    });

    testWidgets('tapping an addable row calls add and closes the sheet', (
      tester,
    ) async {
      final added = <String>[];
      await _openSheet(
        tester,
        load: () async => sources,
        add: (s) async {
          added.add(s.uniqueId);
          return true;
        },
      );
      await tester.tap(find.text('Camo Studio Virtual Camera'));
      await tester.pumpAndSettle();

      expect(added, <String>['camo']);
      expect(find.text('Camo Studio Virtual Camera'), findsNothing); // closed
    });

    testWidgets('tapping a disabled row does nothing', (tester) async {
      var calls = 0;
      await _openSheet(
        tester,
        load: () async => sources,
        add: (_) async {
          calls++;
          return true;
        },
      );
      await tester.tap(
        find.text('OBSBOT Tiny 2 Lite Camera'),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.text('Add camera'), findsOneWidget); // still open
    });

    testWidgets('a refused add closes the sheet and surfaces a snackbar', (
      tester,
    ) async {
      await _openSheet(
        tester,
        load: () async => sources,
        add: (_) async => false,
      );
      await tester.tap(find.text('Camo Studio Virtual Camera'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not add "Camo Studio Virtual Camera"'),
        findsOneWidget,
      );
    });

    testWidgets('empty list shows the no-cameras message', (tester) async {
      await _openSheet(tester, load: () async => const <AvailableSource>[]);
      expect(find.text('No cameras found on the bridge Mac.'), findsOneWidget);
    });

    testWidgets('null result (error ack / not connected) shows retry copy', (
      tester,
    ) async {
      await _openSheet(tester, load: () async => null);
      expect(find.textContaining('Could not load cameras'), findsOneWidget);
    });
  });

  group('Live screen with a generic video source', () {
    testWidgets('staged video source: preview + TAKE only, controls gone', (
      tester,
    ) async {
      final client = await _pumpLive(
        tester,
        _bridge(<DeviceState>[
          _obsbot('A', name: 'Vocal'),
          _video('u1', 'Camo'),
        ], 'A'),
      );
      client.selectDevice('av:u1');
      await tester.pump();

      // Control affordances must not render at all.
      expect(find.text('Frame'), findsNothing);
      expect(find.text('P1'), findsNothing);
      expect(find.text('hold to save here'), findsNothing);
      // The note explains why, and TAKE still arms (staged != on air).
      expect(find.textContaining('preview and TAKE only'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'TAKE'), findsOneWidget);
    });

    testWidgets('OBSBOT staged keeps controls even with a source attached', (
      tester,
    ) async {
      await _pumpLive(
        tester,
        _bridge(<DeviceState>[
          _obsbot('A', name: 'Vocal'),
          _video('u1', 'Camo'),
        ], 'A'),
      );
      // Default selection is the live OBSBOT camera.
      expect(find.text('Frame'), findsOneWidget);
      expect(find.text('P1'), findsOneWidget);
      expect(find.textContaining('preview and TAKE only'), findsNothing);
    });

    testWidgets('bus shows the Add chip even with a single camera', (
      tester,
    ) async {
      await _pumpLive(tester, _bridge(<DeviceState>[_obsbot('A')], 'A'));
      expect(find.text('Add'), findsOneWidget);
    });

    testWidgets('tapping Add opens the picker sheet', (tester) async {
      await _pumpLive(tester, _bridge(<DeviceState>[_obsbot('A')], 'A'));
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Add camera'), findsOneWidget);
      // Not connected in tests -> listSources() is null -> retry copy.
      expect(find.textContaining('Could not load cameras'), findsOneWidget);
    });

    testWidgets('long-press on a video source chip asks to remove it', (
      tester,
    ) async {
      await _pumpLive(
        tester,
        _bridge(<DeviceState>[
          _obsbot('A', name: 'Vocal'),
          _video('u1', 'Camo'),
        ], 'A'),
      );
      // Staged is A ("Vocal"), so "Camo" appears only on its bus chip.
      await tester.longPress(find.text('Camo'));
      await tester.pumpAndSettle();
      expect(find.text('Remove camera'), findsOneWidget);
      expect(
        find.textContaining('The camera itself is not affected'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Remove camera'), findsNothing);
    });

    testWidgets('long-press on an OBSBOT chip does not offer remove', (
      tester,
    ) async {
      await _pumpLive(
        tester,
        _bridge(<DeviceState>[
          _obsbot('A', name: 'Vocal'),
          _video('u1', 'Camo'),
        ], 'A'),
      );
      // "Vocal" appears in the top strip and on its chip; .last is the chip.
      await tester.longPress(find.text('Vocal').last, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Remove camera'), findsNothing);
    });
  });
}
