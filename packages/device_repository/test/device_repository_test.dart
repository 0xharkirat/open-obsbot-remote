import 'dart:async';

import 'package:bridge_repository/bridge_repository.dart';
import 'package:device_repository/device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:obsbot_api_client/obsbot_api_client.dart';
import 'package:obsbot_protocol/obsbot_protocol.dart';
import 'package:test/test.dart';

class _MockApi extends Mock implements ObsbotApiClient {}

/// Builds a state event carrying the given devices. Each device map is a
/// partial `image`/`zoom` override merged onto sane defaults.
Map<String, dynamic> _stateEvent(List<Map<String, dynamic>> devices) =>
    <String, dynamic>{
      'event': 'state',
      'version': '2.0',
      'active_device_id': devices.isEmpty ? '' : devices.first['device_id'],
      'devices': devices,
    };

Map<String, dynamic> _device(
  String id, {
  bool hdr = false,
  double zoom = 1.0,
  double zoomMax = 2.0,
}) =>
    <String, dynamic>{
      'device_id': id,
      'device': <String, dynamic>{
        'sn': id,
        'model_display': 'Tiny 2 Lite',
        'connected': true,
      },
      'zoom': <String, dynamic>{'value': zoom, 'min': 1.0, 'max': zoomMax},
      'image': <String, dynamic>{'hdr': hdr},
    };

void main() {
  late _MockApi api;
  late StreamController<Map<String, dynamic>> events;
  late BridgeRepository bridge;

  setUp(() {
    api = _MockApi();
    events = StreamController<Map<String, dynamic>>.broadcast();
    when(() => api.events).thenAnswer((_) => events.stream);
    // Default: every send acks instantly. Race tests override per-case.
    when(() => api.send(any())).thenAnswer((_) async => <String, dynamic>{});
    bridge = BridgeRepository(api: api);
  });

  tearDown(() async {
    await bridge.dispose();
    await events.close();
  });

  DeviceRepository build() => DeviceRepository(api: api, bridge: bridge);

  /// Drives a real state event through the bridge and lets it propagate.
  Future<void> pushState(List<Map<String, dynamic>> devices) async {
    events.add(_stateEvent(devices));
    await pumpEventQueue();
  }

  List<Map<String, dynamic>> sentFrames() =>
      verify(() => api.send(captureAny()))
          .captured
          .cast<Map<String, dynamic>>();

  group('device_id injection', () {
    test('every action injects device_id and the right action name', () async {
      final repo = build();
      const id = 'DEV';

      await repo.ptzVelocity(deviceId: id, yawSpeed: 10, pitchSpeed: -5);
      await repo.ptzStop(deviceId: id);
      await repo.recenter(deviceId: id);
      await repo.zoomSet(deviceId: id, value: 1.5);
      await repo.aiSetMode(deviceId: id, mode: 'human', subMode: 'upper_body');
      await repo.hdr(deviceId: id, enabled: true);
      await repo.fov(deviceId: id, fov: 78);
      await repo.faceAe(deviceId: id, enabled: true);
      await repo.faceFocus(deviceId: id, enabled: true);
      await repo.flipH(deviceId: id, enabled: true);
      await repo.colorSet(deviceId: id, brightness: 55, contrast: 40);
      await repo.setExposureMode(deviceId: id, mode: 'manual');
      await repo.setEvBias(deviceId: id, bias: -0.7);
      await repo.setAntiFlicker(deviceId: id, mode: '60');
      await repo.setWbAuto(deviceId: id, enabled: false);
      await repo.setWbTemp(deviceId: id, kelvin: 5500);
      await repo.imageRefresh(deviceId: id);
      await repo.presetSave(deviceId: id, presetId: 1, name: 'Wide');
      await repo.presetRecall(deviceId: id, presetId: 1);
      await repo.presetDelete(deviceId: id, presetId: 1);
      await repo.runStatus(deviceId: id, status: 'sleep');
      await repo.sequenceSet(
        deviceId: id,
        steps: [const SequenceStep(presetId: 1, seconds: 10)],
      );
      await repo.sequenceStart(deviceId: id);
      await repo.sequenceStop(deviceId: id);
      await repo.sequenceSaveAs(
        deviceId: id,
        name: 'Main',
        steps: [const SequenceStep(presetId: 1, seconds: 10)],
      );
      await repo.sequenceLoad(deviceId: id, name: 'Main');
      await repo.sequenceDelete(deviceId: id, name: 'Main');

      final frames = sentFrames();
      // Every frame targets the requested device.
      for (final f in frames) {
        expect(f['device_id'], id,
            reason: 'action ${f['action']} lost device_id');
      }
      final actions = frames.map((f) => f['action']).toSet();
      expect(actions, <String>{
        'ptz.velocity',
        'ptz.stop',
        'ptz.recenter',
        'zoom.set',
        'ai.set_mode',
        'image.set_hdr',
        'image.set_fov',
        'image.set_face_ae',
        'image.set_face_focus',
        'image.set_flip_h',
        'image.set_color',
        'image.set_exposure_mode',
        'image.set_ev_bias',
        'image.set_anti_flicker',
        'image.set_wb_auto',
        'image.set_wb_temp',
        'image.refresh',
        'preset.save',
        'preset.recall',
        'preset.delete',
        'system.run_status',
        'sequence.set',
        'sequence.start',
        'sequence.stop',
        'sequence.save_as',
        'sequence.load',
        'sequence.delete',
      });
    });

    test('frames never carry an id (the api client assigns it)', () async {
      final repo = build();
      await repo.hdr(deviceId: 'DEV', enabled: true);
      expect(sentFrames().single.containsKey('id'), isFalse);
    });

    test('colorSet sends only the sliders passed', () async {
      final repo = build();
      await repo.colorSet(deviceId: 'DEV', saturation: 60);
      final f = sentFrames().single;
      expect(f['saturation'], 60);
      expect(f.containsKey('brightness'), isFalse);
      expect(f.containsKey('contrast'), isFalse);
    });
  });

  group('zoomSet duration semantics', () {
    test(
        'mid-drag forces duration_ms 0 and omits final, even if a '
        'duration is passed', () async {
      final repo = build();
      await repo.zoomSet(
        deviceId: 'DEV',
        value: 1.6,
        duration: const Duration(seconds: 5),
      );
      final f = sentFrames().single;
      expect(f['duration_ms'], 0);
      expect(f.containsKey('final'), isFalse);
      expect(f['value'], 1.6);
    });

    test('release carries final:true and the chosen duration', () async {
      final repo = build();
      await repo.zoomSet(
        deviceId: 'DEV',
        value: 2.0,
        terminal: true,
        duration: const Duration(seconds: 5),
      );
      final f = sentFrames().single;
      expect(f['final'], true);
      expect(f['duration_ms'], 5000);
      expect(f['value'], 2.0);
    });
  });

  group('optimistic overlay', () {
    test('applies instantly, on the call-frame, before any ack', () async {
      final repo = build();
      await pushState([_device('A', hdr: false)]);

      // Fire-and-forget: the overlay must be visible synchronously, before
      // the returned future (and its ack) has any chance to complete.
      unawaited(repo.hdr(deviceId: 'A', enabled: true));
      expect(repo.current.deviceById('A')!.hdr, isTrue);
    });

    test('overlay on A never touches B', () async {
      final repo = build();
      await pushState([_device('A', hdr: false), _device('B', hdr: false)]);

      unawaited(repo.hdr(deviceId: 'A', enabled: true));

      expect(repo.current.deviceById('A')!.hdr, isTrue);
      expect(repo.current.deviceById('B')!.hdr, isFalse);
    });

    test('a real event supersedes the overlay once the write is acked',
        () async {
      final repo = build();
      await pushState([_device('A', hdr: false)]);

      await repo.hdr(deviceId: 'A', enabled: true); // acks instantly -> armed
      expect(repo.current.deviceById('A')!.hdr, isTrue);

      // The reflecting event arrives; overlay drops, real value shows.
      await pushState([_device('A', hdr: true)]);
      expect(repo.current.deviceById('A')!.hdr, isTrue);
    });

    test('clamped value wins: request zoom 4.0, camera reports 2.0', () async {
      final repo = build();
      await pushState([_device('A', zoom: 1.0, zoomMax: 2.0)]);

      await repo.zoomSet(deviceId: 'A', value: 4.0, terminal: true);
      expect(repo.current.deviceById('A')!.zoom, 4.0); // optimistic target

      // Camera clamps to its 2.0 max; the echo must settle the UI there.
      await pushState([_device('A', zoom: 2.0, zoomMax: 2.0)]);
      expect(repo.current.deviceById('A')!.zoom, 2.0);
    });
  });

  group('stale-event race', () {
    test('a pre-tap event still in flight does not resurrect the old value',
        () async {
      // Control ack timing: the send does not complete until we say so.
      final ackGate = Completer<Map<String, dynamic>>();
      when(() => api.send(any())).thenAnswer((_) => ackGate.future);

      final repo = build();
      await pushState([_device('A', hdr: false)]);

      // User taps HDR on. Overlay shows true; ack has NOT landed.
      final pending = repo.hdr(deviceId: 'A', enabled: true);
      expect(repo.current.deviceById('A')!.hdr, isTrue);

      // A periodic state event generated BEFORE the tap arrives now. It
      // still says hdr=false. It must NOT flip the UI back.
      await pushState([_device('A', hdr: false)]);
      expect(
        repo.current.deviceById('A')!.hdr,
        isTrue,
        reason: 'stale in-flight event resurrected the old value',
      );

      // Ack lands -> overlay arms.
      ackGate.complete(<String, dynamic>{});
      await pending;

      // The reflecting event (post-ack) carries the applied value and
      // supersedes the overlay.
      await pushState([_device('A', hdr: true)]);
      expect(repo.current.deviceById('A')!.hdr, isTrue);
    });

    test('rapid drag stays pinned to the latest value, no flicker to stale',
        () async {
      final gates = <Completer<Map<String, dynamic>>>[];
      when(() => api.send(any())).thenAnswer((_) {
        final c = Completer<Map<String, dynamic>>();
        gates.add(c);
        return c.future;
      });

      final repo = build();
      await pushState([_device('A', zoom: 1.0, zoomMax: 2.0)]);

      // Three quick mid-drag writes, none acked yet.
      final p1 = repo.zoomSet(deviceId: 'A', value: 1.2);
      final p2 = repo.zoomSet(deviceId: 'A', value: 1.5);
      final p3 = repo.zoomSet(deviceId: 'A', value: 1.8);
      expect(repo.current.deviceById('A')!.zoom, 1.8);

      // A stale poll event (still 1.0) arrives mid-drag. Overlay holds 1.8.
      await pushState([_device('A', zoom: 1.0, zoomMax: 2.0)]);
      expect(repo.current.deviceById('A')!.zoom, 1.8);

      // Acks land in order; overlay only arms after the LAST one.
      for (final g in gates) {
        g.complete(<String, dynamic>{});
      }
      await Future.wait([p1, p2, p3]);

      // Still 1.8 until a reflecting event settles it.
      expect(repo.current.deviceById('A')!.zoom, 1.8);
      await pushState([_device('A', zoom: 1.8, zoomMax: 2.0)]);
      expect(repo.current.deviceById('A')!.zoom, 1.8);
    });
  });

  group('state stream', () {
    test('replays the latest merged state to a late listener', () async {
      final repo = build();
      await pushState([_device('A', hdr: false)]);
      unawaited(repo.hdr(deviceId: 'A', enabled: true));

      final late = <BridgeState>[];
      repo.state.listen(late.add);
      await pumpEventQueue();

      expect(late.first.deviceById('A')!.hdr, isTrue);
    });
  });
}
