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

  group('CameraState', () {
    test('empty has sane defaults', () {
      const s = CameraState.empty;
      expect(s.connected, isFalse);
      expect(s.zoom, 1);
      expect(s.fov, 86);
      expect(s.exposureMode, 'auto');
      expect(s.antiFlicker, 'off');
      expect(s.wbAuto, isTrue);
      expect(s.wbKelvin, 4700);
    });

    test('fromEvent parses a full v1.2 state snapshot', () {
      final s = CameraState.fromEvent(<String, dynamic>{
        'device': <String, dynamic>{
          'sn': 'ABC123',
          'model_display': 'Tiny 2 Lite',
          'firmware': '6.2.8.1',
          'connected': true,
          'run_status': 'run',
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
      });
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

    test('fromEvent tolerates an empty payload', () {
      final s = CameraState.fromEvent(const <String, dynamic>{});
      expect(s.connected, isFalse);
      expect(s.presets, isEmpty);
      expect(s.sequence.steps, isEmpty);
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
