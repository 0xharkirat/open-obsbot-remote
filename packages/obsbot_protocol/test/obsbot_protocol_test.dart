import 'package:obsbot_protocol/obsbot_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('PresetEntry', () {
    test('fromJson reads every field', () {
      final p = PresetEntry.fromJson(<String, dynamic>{
        'id': 2,
        'name': 'Wide hall',
        'yaw': 12.5,
        'pitch': -3.0,
        'roll': 0.0,
        'zoom': 1.7,
      });
      expect(p.id, 2);
      expect(p.name, 'Wide hall');
      expect(p.yaw, 12.5);
      expect(p.pitch, -3.0);
      expect(p.roll, 0.0);
      expect(p.zoom, 1.7);
    });

    test('missing fields fall back to safe defaults', () {
      final p = PresetEntry.fromJson(const <String, dynamic>{});
      expect(p.id, 0);
      expect(p.name, '');
      expect(p.zoom, 1);
    });

    test('round-trip via toJson preserves equality', () {
      const a = PresetEntry(
        id: 4,
        name: 'Closeup',
        yaw: -22.4,
        pitch: 5.5,
        roll: 0,
        zoom: 1.95,
      );
      final b = PresetEntry.fromJson(a.toJson());
      expect(a, equals(b));
    });
  });

  group('SequenceStep', () {
    test('fromJson reads preset_id + seconds + transition_ms', () {
      final s = SequenceStep.fromJson(<String, dynamic>{
        'preset_id': 3,
        'seconds': 45,
        'transition_ms': 12000,
      });
      expect(s.presetId, 3);
      expect(s.seconds, 45);
      expect(s.transition, const Duration(milliseconds: 12000));
    });

    test('toJson emits wire-format keys', () {
      const s = SequenceStep(
        presetId: 1,
        seconds: 60,
        transition: Duration(seconds: 5),
      );
      expect(s.toJson(), <String, dynamic>{
        'preset_id': 1,
        'seconds': 60,
        'transition_ms': 5000,
      });
    });

    test('copyWith only overrides given fields', () {
      const original = SequenceStep(
        presetId: 1,
        seconds: 30,
        transition: Duration(seconds: 2),
      );
      final swapped = original.copyWith(seconds: 90);
      expect(swapped.presetId, 1);
      expect(swapped.seconds, 90);
      expect(swapped.transition, const Duration(seconds: 2));
    });
  });

  group('LoopMode', () {
    test('toWire round-trips', () {
      for (final m in LoopMode.values) {
        expect(loopModeFromWire(loopModeToWire(m)), m);
      }
    });

    test('unknown wire string defaults to forward', () {
      expect(loopModeFromWire('garbage'), LoopMode.forward);
    });
  });

  group('MoveDurationPreset', () {
    test('kMoveDurationPresets has 8 entries from Instant to 5 min', () {
      expect(kMoveDurationPresets.length, 8);
      expect(kMoveDurationPresets.first.duration, Duration.zero);
      expect(kMoveDurationPresets.last.duration,
          const Duration(minutes: 5));
    });

    test('formatMoveDuration spans the chip range', () {
      expect(formatMoveDuration(Duration.zero), 'Instant');
      expect(formatMoveDuration(const Duration(milliseconds: 1000)),
          '1 sec');
      expect(formatMoveDuration(const Duration(milliseconds: 5500)),
          '5.5 sec');
      expect(formatMoveDuration(const Duration(minutes: 1)), '1 min');
      expect(
          formatMoveDuration(const Duration(minutes: 2, seconds: 30)),
          '2m 30s');
    });
  });

  // Reusable fixture: one fully-populated device entry. v2 wraps these
  // in a `devices` array (see BridgeState tests).
  Map<String, dynamic> fixtureDeviceJson({
    String deviceId = 'RMOW1234',
    String friendlyName = '',
  }) =>
      <String, dynamic>{
        'device_id': deviceId,
        'device': <String, dynamic>{
          'sn': deviceId,
          'model_display': 'Tiny 2 Lite',
          'firmware': '6.2.8.1',
          'connected': true,
          'run_status': 'run',
          'friendly_name': friendlyName,
        },
        'ptz': <String, dynamic>{'yaw': 12.5, 'pitch': -3.0, 'roll': 0.0},
        'zoom': <String, dynamic>{'value': 1.4, 'min': 1.0, 'max': 2.0},
        'ai': <String, dynamic>{
          'mode': 'human',
          'sub_mode': 'upper_body',
          'enabled': true,
        },
        'image': <String, dynamic>{
          'hdr': false,
          'fov': 78,
          'brightness': 60,
          'contrast': 55,
          'saturation': 50,
          'sharpness': 50,
          'face_ae': false,
          'face_focus': true,
          'auto_focus': true,
          'manual_focus': 50,
          'flip_h': false,
          'exposure_mode': 'auto',
          'ev_bias': -0.7,
          'anti_flicker': '60',
          'wb_auto': false,
          'wb_kelvin': 5500,
        },
        'presets': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 0,
            'name': 'Wide',
            'yaw': 0,
            'pitch': 0,
            'roll': 0,
            'zoom': 1.0,
          },
        ],
        'active_preset_id': 0,
        'sequence': <String, dynamic>{
          'running': false,
          'step_index': -1,
          'elapsed_s': 0,
          'total_s': 0,
          'mode': 'forward',
          'available': <String>['Main'],
          'loaded': 'Main',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'preset_id': 0,
              'seconds': 30,
              'transition_ms': 5000,
            },
          ],
        },
      };

  group('DeviceState', () {
    test('empty has sane defaults', () {
      const s = DeviceState.empty;
      expect(s.deviceId, '');
      expect(s.connected, isFalse);
      expect(s.zoom, 1);
      expect(s.fov, 86);
      expect(s.exposureMode, 'auto');
      expect(s.antiFlicker, 'off');
      expect(s.wbAuto, isTrue);
      expect(s.wbKelvin, 4700);
      expect(s.friendlyName, isEmpty);
    });

    test('fromEvent parses a full v2 device payload', () {
      final s = DeviceState.fromEvent(fixtureDeviceJson());
      expect(s.deviceId, 'RMOW1234');
      expect(s.sn, 'RMOW1234');
      expect(s.connected, isTrue);
      expect(s.modelDisplay, 'Tiny 2 Lite');
      expect(s.yaw, 12.5);
      expect(s.zoom, 1.4);
      expect(s.fov, 78);
      expect(s.exposureMode, 'auto');
      expect(s.evBias, -0.7);
      expect(s.antiFlicker, '60');
      expect(s.wbAuto, isFalse);
      expect(s.wbKelvin, 5500);
      expect(s.presets.single.name, 'Wide');
      expect(s.activePresetId, 0);
      expect(s.sequence.loaded, 'Main');
      expect(s.sequence.steps.single.transition,
          const Duration(seconds: 5));
    });

    test('fromEvent falls back to dev.sn when top-level device_id missing',
        () {
      // Transitional: bridges that haven't been bumped to v2 may omit
      // the top-level device_id field.
      final fixture = fixtureDeviceJson();
      fixture.remove('device_id');
      final s = DeviceState.fromEvent(fixture);
      expect(s.deviceId, 'RMOW1234'); // pulled from device.sn
    });

    test('fromEvent tolerates an empty payload', () {
      final s = DeviceState.fromEvent(const <String, dynamic>{});
      expect(s.deviceId, '');
      expect(s.connected, isFalse);
      expect(s.presets, isEmpty);
      expect(s.sequence.steps, isEmpty);
    });

    test('displayName uses friendlyName when set', () {
      final s = DeviceState.fromEvent(
          fixtureDeviceJson(friendlyName: 'Vocal'));
      expect(s.displayName, 'Vocal');
    });

    test('displayName falls back to model + last-4 of SN', () {
      final s = DeviceState.fromEvent(fixtureDeviceJson());
      expect(s.displayName, 'Tiny 2 Lite (1234)');
    });

    test('copyWith only overrides given fields', () {
      final original = DeviceState.fromEvent(fixtureDeviceJson());
      final swapped = original.copyWith(hdr: true, fov: 65);
      expect(swapped.hdr, isTrue);
      expect(swapped.fov, 65);
      // Untouched fields preserved.
      expect(swapped.deviceId, 'RMOW1234');
      expect(swapped.wbKelvin, 5500);
    });
  });

  group('BridgeState', () {
    test('empty has zero devices + no active', () {
      const s = BridgeState.empty;
      expect(s.devices, isEmpty);
      expect(s.activeDeviceId, isEmpty);
      expect(s.activeDevice, isNull);
    });

    test('fromEvent parses v2 multi-device payload', () {
      final bs = BridgeState.fromEvent(<String, dynamic>{
        'type': 'state',
        'version': '2.0',
        'active_device_id': 'RMOW1234',
        'devices': <Map<String, dynamic>>[
          fixtureDeviceJson(deviceId: 'RMOW1234', friendlyName: 'Vocal'),
          fixtureDeviceJson(deviceId: 'RMOW5678', friendlyName: 'Audience'),
        ],
      });
      expect(bs.protocolVersion, '2.0');
      expect(bs.devices.length, 2);
      expect(bs.activeDeviceId, 'RMOW1234');
      expect(bs.activeDevice?.friendlyName, 'Vocal');
      expect(bs.deviceById('RMOW5678')?.friendlyName, 'Audience');
      expect(bs.deviceById('NOPE'), isNull);
    });

    test('fromEvent tolerates v1 single-device payload (no devices key)',
        () {
      // v1 bridges that haven't been upgraded send the device snapshot
      // at the top level instead of inside a `devices` array. We wrap
      // it into a one-element list so clients can still connect during
      // the rollout window.
      final bs = BridgeState.fromEvent(fixtureDeviceJson());
      expect(bs.devices.length, 1);
      expect(bs.devices.single.deviceId, 'RMOW1234');
      expect(bs.activeDeviceId, 'RMOW1234');
    });

    test('withDevice replaces one entry without touching the others', () {
      final bs = BridgeState.fromEvent(<String, dynamic>{
        'version': '2.0',
        'active_device_id': 'RMOW1234',
        'devices': <Map<String, dynamic>>[
          fixtureDeviceJson(deviceId: 'RMOW1234'),
          fixtureDeviceJson(deviceId: 'RMOW5678'),
        ],
      });
      final updated = bs.withDevice(
        'RMOW5678',
        bs.deviceById('RMOW5678')!.copyWith(hdr: true),
      );
      expect(updated.deviceById('RMOW1234')?.hdr, isFalse);
      expect(updated.deviceById('RMOW5678')?.hdr, isTrue);
      // Original is immutable.
      expect(bs.deviceById('RMOW5678')?.hdr, isFalse);
    });

    test('withDevice throws StateError for unknown device id', () {
      const bs = BridgeState.empty;
      expect(
        () => bs.withDevice('RMOW9999', DeviceState.empty),
        throwsStateError,
      );
    });
  });

  group('SequenceState.phase', () {
    test('defaults to holding when phase key missing', () {
      final s = SequenceState.fromJson(const <String, dynamic>{
        'running': false,
        'step_index': -1,
        'elapsed_s': 0,
        'total_s': 0,
        'mode': 'forward',
        'available': <String>[],
        'loaded': '',
        'steps': <Map<String, dynamic>>[],
      });
      expect(s.phase, 'holding');
    });

    test('fromJson reads phase=moving when present', () {
      final s = SequenceState.fromJson(const <String, dynamic>{
        'running': true,
        'step_index': 0,
        'elapsed_s': 0,
        'total_s': 30,
        'mode': 'forward',
        'phase': 'moving',
        'available': <String>[],
        'loaded': '',
        'steps': <Map<String, dynamic>>[],
      });
      expect(s.phase, 'moving');
    });

    test('SequenceState.empty defaults phase to holding', () {
      expect(SequenceState.empty.phase, 'holding');
    });
  });
}
