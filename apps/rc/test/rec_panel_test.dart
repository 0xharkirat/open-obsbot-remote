// Widget tests for the REC panel.
//
// The states worth pinning are the ones an operator meets under pressure:
// a take running, a take that died, and a camera with no microphone. Each
// renders from an injected BridgeState, so none of this needs a bridge.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/live_screen.dart';
import 'package:obsbot_control/rec_panel.dart';
import 'package:obsbot_control/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gb = 1024 * 1024 * 1024;

DeviceState _device() {
  return DeviceState.empty.copyWith(
    deviceId: 'A',
    sn: 'A',
    modelDisplay: 'Tiny 2 Lite',
    connected: true,
    runStatus: 'run',
    friendlyName: 'Stage',
  );
}

// Audio lives on the bridge-global recording block, not per device: the
// recorder is bridge-global and this microphone cannot be muted through the
// SDK, so a per-camera flag would describe a setting that does not exist.
BridgeState _bridge({
  RecordingState recording = RecordingState.empty,
  bool micAvailable = false,
  bool audioEnabled = false,
}) {
  return BridgeState(
    protocolVersion: '2.0',
    devices: <DeviceState>[_device()],
    activeDeviceId: 'A',
    recording: recording.copyWith(
      audioAvailable: micAvailable,
      audioEnabled: audioEnabled,
    ),
  );
}

Future<WsClient> _pump(WidgetTester tester, BridgeState bridge) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final client = WsClient()..debugSetBridge(bridge);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: RecPanel(client: client)),
      ),
    ),
  );
  await tester.pump();
  return client;
}

void main() {
  group('idle', () {
    testWidgets('offers the target camera and free space', (tester) async {
      await _pump(
        tester,
        _bridge(recording: const RecordingState(diskFreeBytes: 900 * _gb)),
      );
      expect(find.text('Stage'), findsOneWidget);
      expect(find.textContaining('GB free'), findsOneWidget);
      expect(find.text('Hold to stop'), findsNothing);
    });

    testWidgets('says it will be silent when there is no microphone', (
      tester,
    ) async {
      await _pump(tester, _bridge());
      expect(find.textContaining('no microphone'), findsOneWidget);
    });

    testWidgets('says it will have sound when the mic is on', (tester) async {
      await _pump(
        tester,
        _bridge(micAvailable: true, audioEnabled: true),
      );
      expect(find.text('Will record with sound'), findsOneWidget);
    });

    // A microphone that exists but is switched off is its own state: the
    // operator can fix it, unlike a camera that has none.
    testWidgets('distinguishes a muted mic from a missing one', (tester) async {
      await _pump(
        tester,
        _bridge(micAvailable: true),
      );
      expect(find.textContaining('audio is off'), findsOneWidget);
    });

    // Below the bridge's floor the start would be refused, so the button
    // says so instead of failing after the tap.
    testWidgets('refuses to arm below the free-space floor', (tester) async {
      await _pump(
        tester,
        _bridge(recording: const RecordingState(diskFreeBytes: 2 * _gb)),
      );
      expect(find.text('Not enough free space to start'), findsOneWidget);
      expect(find.textContaining('too low to record'), findsOneWidget);
    });
  });

  group('recording', () {
    RecordingState running({int elapsed = 125, bool audio = true}) =>
        RecordingState(
          active: true,
          deviceId: 'A',
          elapsedS: elapsed,
          bytes: 41234567,
          path: '/srv/data/recordings/2026-08-15/1423-A.mp4',
          audio: audio,
          diskFreeBytes: 900 * _gb,
        );

    testWidgets('shows the elapsed clock the bridge reports', (tester) async {
      await _pump(tester, _bridge(recording: running()));
      expect(find.text('RECORDING'), findsOneWidget);
      expect(find.text('02:05'), findsOneWidget);
      expect(find.text('39 MB'), findsOneWidget);
    });

    // The clock comes from the bridge, never from a local ticker, so a
    // phone that joins an hour into a take shows the hour.
    testWidgets('renders an hour-long take from state alone', (tester) async {
      await _pump(tester, _bridge(recording: running(elapsed: 3725)));
      expect(find.text('1:02:05'), findsOneWidget);
    });

    testWidgets('flags a silent take', (tester) async {
      await _pump(tester, _bridge(recording: running(audio: false)));
      expect(find.text('Silent'), findsOneWidget);
    });

    // Stop is deliberate: a tap must not end a take. The control is a hold,
    // so tapping it changes nothing.
    testWidgets('a tap does not stop the recording', (tester) async {
      await _pump(tester, _bridge(recording: running()));
      expect(find.text('Hold to stop'), findsOneWidget);
      await tester.tap(find.text('Hold to stop'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('RECORDING'), findsOneWidget);
    });
  });

  group('failure', () {
    testWidgets('a take that died says so and stays saying it', (tester) async {
      await _pump(
        tester,
        _bridge(
          recording: const RecordingState(
            error: 'encoder exited: no space left on device',
            diskFreeBytes: 900 * _gb,
          ),
        ),
      );
      expect(
        find.text('The last recording stopped unexpectedly'),
        findsOneWidget,
      );
      expect(find.textContaining('no space left on device'), findsOneWidget);
      // Still offers a new take: the banner reports, it does not block.
      expect(find.text('Stage'), findsOneWidget);
    });

    testWidgets('no banner while a take is running', (tester) async {
      await _pump(
        tester,
        _bridge(
          recording: const RecordingState(
            active: true,
            deviceId: 'A',
            error: 'stale',
          ),
        ),
      );
      expect(
        find.text('The last recording stopped unexpectedly'),
        findsNothing,
      );
    });
  });

  // The framing row gained a third control, and the repo's own notes record
  // this row overflowing at narrow widths before. Pin the narrowest phone.
  group('audio toggle', () {
    testWidgets('framing row survives a 320px phone', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.binding.setSurfaceSize(const Size(320, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final client = WsClient()
        ..debugSetBridge(
          _bridge(micAvailable: true, audioEnabled: true),
        );
      await tester.pumpWidget(MaterialApp(home: LiveScreen(client: client)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.control_camera));
      await tester.pump();
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a camera with no mic disables the control', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final client = WsClient()..debugSetBridge(_bridge());
      await tester.pumpWidget(MaterialApp(home: LiveScreen(client: client)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.control_camera));
      await tester.pump();
      // Present but inert, rather than hidden: a control that vanishes
      // leaves the operator wondering whether they missed it.
      expect(find.byIcon(Icons.mic_off), findsOneWidget);
      final button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.byIcon(Icons.mic_off),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('protocol types', () {
    test('elapsed formats below and above an hour', () {
      expect(const RecordingState(elapsedS: 5).elapsedLabel, '00:05');
      expect(const RecordingState(elapsedS: 125).elapsedLabel, '02:05');
      expect(const RecordingState(elapsedS: 3725).elapsedLabel, '1:02:05');
      // Never negative, whatever the bridge sends.
      expect(const RecordingState(elapsedS: -1).elapsedLabel, '00:00');
    });

    test('failed means stopped with an error, not merely an error', () {
      expect(const RecordingState(error: 'boom').failed, isTrue);
      expect(
        const RecordingState(active: true, error: 'boom').failed,
        isFalse,
      );
      expect(const RecordingState().failed, isFalse);
    });

    // audio is what THIS take is doing; audioEnabled is what the next one
    // will try to do. They diverge after a downgrade: asking for sound with
    // no microphone starts a silent recording rather than refusing the take,
    // and an operator who thinks they are capturing sound must be able to
    // see that they are not.
    test('a downgraded take reports silent while the preference stays on', () {
      const s = RecordingState(
        active: true,
        audio: false,
        audioEnabled: true,
        audioAvailable: false,
      );
      expect(s.audio, isFalse);
      expect(s.audioEnabled, isTrue);
    });

    test('a bridge with no recording block parses as idle', () {
      final s = BridgeState.fromEvent(<String, dynamic>{
        'version': '2.0',
        'devices': <dynamic>[],
        'active_device_id': '',
      });
      expect(s.recording, RecordingState.empty);
      expect(s.recording.active, isFalse);
    });

    test('the recording block round-trips', () {
      final s = BridgeState.fromEvent(<String, dynamic>{
        'version': '2.0',
        'devices': <dynamic>[],
        'active_device_id': '',
        'recording': <String, dynamic>{
          'active': true,
          'device_id': 'A',
          'elapsed_s': 61,
          'bytes': 1024,
          'audio': true,
          'disk_free_bytes': 900,
        },
      });
      expect(s.recording.active, isTrue);
      expect(s.recording.elapsedLabel, '01:01');
      expect(s.recording.deviceId, 'A');
    });
  });
}
