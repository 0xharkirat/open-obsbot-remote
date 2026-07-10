import 'dart:async';

import 'package:bridge_repository/bridge_repository.dart';
import 'package:obsbot_api_client/obsbot_api_client.dart';
import 'package:obsbot_protocol/obsbot_protocol.dart';

/// The per-device fields that carry an optimistic overlay. One key per
/// independently-toggled control so a slow-settling zoom never resurrects
/// or masks an unrelated toggle on the same camera. Latest write per key
/// wins; each key settles on its own.
enum _Field {
  zoom,
  ai,
  hdr,
  fov,
  faceAe,
  faceFocus,
  flipH,
  color,
  exposureMode,
  evBias,
  antiFlicker,
  wbAuto,
  wbKelvin,
}

typedef _Apply = DeviceState Function(DeviceState);

/// One pending optimistic mutation for a (deviceId, field) pair.
///
/// [apply] is the copyWith closure holding the user's chosen value.
/// [openSends] counts writes for this field whose acks have not landed
/// yet; while it is > 0 a newer value may still be in flight, so the
/// overlay must not settle. [armed] flips true once the last in-flight
/// write is acked - the next real state event then supersedes it.
class _Overlay {
  _Overlay(this.apply);

  _Apply apply;
  int openSends = 0;
  bool armed = false;
  Timer? settleTimer;

  void cancelTimer() {
    settleTimer?.cancel();
    settleTimer = null;
  }
}

/// Per-camera commands and optimistic state.
///
/// ## Optimistic overlay
///
/// A tap on HDR must flip the button on the same frame, not 200-500 ms
/// later when the bridge echoes. So each mutating method writes a local
/// overlay for the field it touches and emits the merged state
/// immediately, then sends the wire command.
///
/// [state] is the bridge's real [BridgeState] with every live overlay
/// applied on top, per device. Overlays are per-field and per-device:
/// an HDR overlay on camera A never touches camera B (via
/// [BridgeState.withDevice]), and a slow zoom overlay on A never masks a
/// concurrent AI-mode overlay on the same camera.
///
/// ### Settling (the stale-event race)
///
/// The naive rule "drop the overlay on the next state event" is wrong.
/// State events poll about every 500 ms, so when the user taps, an
/// event generated *before* the tap is often already in flight. It does
/// not carry the user's value. Dropping the overlay on that event
/// resurrects the stale value for one frame before the next event
/// finally shows the new one - a visible flicker.
///
/// The fix keys off the ack, which is a synchronization point in the
/// single ordered WebSocket stream. Frames arrive in send order over
/// TCP, and the bridge stamps its snapshot and then acks, so on the wire
/// the order is: `[stale event] ... [our ack] ... [reflecting event]`.
/// The overlay is therefore held until its write is acked (`armed`), and
/// only the first real state event *after* that ack drops it. The stale
/// in-flight event arrives before the ack and is ignored; the reflecting
/// event - which carries the applied OR camera-clamped value - arrives
/// after and wins.
///
/// Rapid slider drags send many writes for one field before any acks
/// return. [_Overlay.openSends] counts them; the overlay stays pinned to
/// the latest value and only arms when the last write is acked, so the
/// UI never flickers back to a stale real value mid-drag.
///
/// A per-overlay safety timer ([_settleGrace]) drops an armed overlay if
/// no state event ever arrives to settle it - insurance against a bridge
/// that fails to broadcast after a command, so a rejected or dropped
/// command can never strand a wrong value on screen forever.
class DeviceRepository {
  DeviceRepository({
    required ObsbotApiClient api,
    required BridgeRepository bridge,
  }) : _api = api,
       _bridge = bridge {
    _lastReal = _bridge.current;
    _merged = _lastReal;
    _sub = _bridge.state.listen(_onReal);
  }

  final ObsbotApiClient _api;
  final BridgeRepository _bridge;
  late final StreamSubscription<BridgeState> _sub;

  final _updates = StreamController<BridgeState>.broadcast();
  final Map<String, Map<_Field, _Overlay>> _overlays =
      <String, Map<_Field, _Overlay>>{};

  late BridgeState _lastReal;
  late BridgeState _merged;

  /// How long an armed overlay lingers with no settling state event
  /// before it is force-dropped. The normal path settles in well under a
  /// second (the bridge broadcasts right after each command); this only
  /// fires if that broadcast never comes.
  static const _settleGrace = Duration(seconds: 5);

  /// The last emitted merged state (real overlaid with live overlays).
  BridgeState get current => _merged;

  /// Real bridge state merged with optimistic overlays, replayed to every
  /// new listener. Hand-rolled replay, same shape as [BridgeRepository.state].
  Stream<BridgeState> get state {
    late final StreamController<BridgeState> out;
    StreamSubscription<BridgeState>? live;
    out = StreamController<BridgeState>(
      onListen: () {
        out.add(_merged);
        live = _updates.stream.listen(out.add);
      },
      onCancel: () => live?.cancel(),
    );
    return out.stream;
  }

  // ---- merge + settle ----

  void _onReal(BridgeState real) {
    _lastReal = real;
    // A real event supersedes every armed overlay: the camera's actual
    // (possibly clamped) value now wins. Non-armed overlays - writes
    // still in flight, or stale events that predate the ack - survive.
    for (final byField in _overlays.values) {
      byField.removeWhere((_, ov) {
        if (ov.armed) {
          ov.cancelTimer();
          return true;
        }
        return false;
      });
    }
    _overlays.removeWhere((_, byField) => byField.isEmpty);
    _emit();
  }

  void _emit() {
    _merged = _merge(_lastReal);
    if (!_updates.isClosed) _updates.add(_merged);
  }

  BridgeState _merge(BridgeState real) {
    if (_overlays.isEmpty) return real;
    var out = real;
    _overlays.forEach((deviceId, byField) {
      final dev = out.deviceById(deviceId);
      if (dev == null) return; // camera detached; its overlays are moot.
      var next = dev;
      for (final ov in byField.values) {
        next = ov.apply(next);
      }
      out = out.withDevice(deviceId, next);
    });
    return out;
  }

  void _writeOverlay(String deviceId, _Field field, _Apply apply) {
    final byField = _overlays.putIfAbsent(deviceId, () => <_Field, _Overlay>{});
    final ov = byField.putIfAbsent(field, () => _Overlay(apply));
    ov.apply = apply;
    ov.openSends += 1;
    ov.armed = false;
    ov.cancelTimer();
    _emit();
  }

  void _settleAfterAck(String deviceId, _Field field) {
    final ov = _overlays[deviceId]?[field];
    if (ov == null) return;
    ov.openSends -= 1;
    if (ov.openSends > 0) return; // newer write still in flight.
    ov.armed = true;
    ov.cancelTimer();
    ov.settleTimer = Timer(_settleGrace, () {
      final cur = _overlays[deviceId]?[field];
      if (cur == null || !cur.armed) return;
      cur.cancelTimer();
      _overlays[deviceId]?.remove(field);
      _overlays.removeWhere((_, byField) => byField.isEmpty);
      _emit();
    });
  }

  /// Optimistic write path: overlay first (instant), then send.
  Future<void> _mutate({
    required String deviceId,
    required _Field field,
    required _Apply apply,
    required Map<String, dynamic> frame,
  }) async {
    _writeOverlay(deviceId, field, apply);
    try {
      await _api.send(frame);
    } finally {
      // Runs on success AND failure: a rejected command must still arm so
      // the next real event reverts the optimistic value to the truth.
      _settleAfterAck(deviceId, field);
    }
  }

  /// Non-optimistic command path: no local value to predict.
  Future<void> _command(Map<String, dynamic> frame) async {
    await _api.send(frame);
  }

  // ---- PTZ (no overlay: continuous motion / target pose unknown locally) ----

  Future<void> ptzVelocity({
    required String deviceId,
    double yawSpeed = 0,
    double pitchSpeed = 0,
  }) => _command(<String, dynamic>{
    'action': 'ptz.velocity',
    'device_id': deviceId,
    'yaw_speed': yawSpeed,
    'pitch_speed': pitchSpeed,
    'roll_speed': 0,
  });

  Future<void> ptzStop({required String deviceId}) =>
      _command(<String, dynamic>{'action': 'ptz.stop', 'device_id': deviceId});

  Future<void> recenter({required String deviceId}) => _command(
    <String, dynamic>{'action': 'ptz.recenter', 'device_id': deviceId},
  );

  // ---- Zoom (overlay) ----

  /// Set absolute zoom.
  ///
  /// CLAUDE.md #28: mid-drag frames MUST be instant. A non-zero
  /// `duration_ms` mid-drag makes the bridge motion planner cancel and
  /// restart every ~100 ms. So [duration] is honored only on the terminal
  /// (release) frame; mid-drag it is forced to zero regardless of what
  /// the caller passes. [terminal] true also sends `final: true` to
  /// bypass the bridge's mid-drag coalesce.
  Future<void> zoomSet({
    required String deviceId,
    required double value,
    bool terminal = false,
    Duration duration = Duration.zero,
  }) {
    final durationMs = terminal ? duration.inMilliseconds : 0;
    return _mutate(
      deviceId: deviceId,
      field: _Field.zoom,
      apply: (d) => d.copyWith(zoom: value),
      frame: <String, dynamic>{
        'action': 'zoom.set',
        'device_id': deviceId,
        'value': value,
        if (terminal) 'final': true,
        'duration_ms': durationMs,
      },
    );
  }

  // ---- AI (overlay) ----

  Future<void> aiSetMode({
    required String deviceId,
    required String mode,
    String subMode = 'normal',
  }) => _mutate(
    deviceId: deviceId,
    field: _Field.ai,
    apply: (d) => d.copyWith(aiMode: mode, aiSubMode: subMode),
    frame: <String, dynamic>{
      'action': 'ai.set_mode',
      'device_id': deviceId,
      'mode': mode,
      'sub_mode': subMode,
    },
  );

  // ---- Image (overlay) ----

  Future<void> hdr({required String deviceId, required bool enabled}) =>
      _mutate(
        deviceId: deviceId,
        field: _Field.hdr,
        apply: (d) => d.copyWith(hdr: enabled),
        frame: <String, dynamic>{
          'action': 'image.set_hdr',
          'device_id': deviceId,
          'enabled': enabled,
        },
      );

  Future<void> fov({required String deviceId, required int fov}) => _mutate(
    deviceId: deviceId,
    field: _Field.fov,
    apply: (d) => d.copyWith(fov: fov),
    frame: <String, dynamic>{
      'action': 'image.set_fov',
      'device_id': deviceId,
      'fov': fov,
    },
  );

  Future<void> faceAe({required String deviceId, required bool enabled}) =>
      _mutate(
        deviceId: deviceId,
        field: _Field.faceAe,
        apply: (d) => d.copyWith(faceAe: enabled),
        frame: <String, dynamic>{
          'action': 'image.set_face_ae',
          'device_id': deviceId,
          'enabled': enabled,
        },
      );

  Future<void> faceFocus({required String deviceId, required bool enabled}) =>
      _mutate(
        deviceId: deviceId,
        field: _Field.faceFocus,
        apply: (d) => d.copyWith(faceFocus: enabled),
        frame: <String, dynamic>{
          'action': 'image.set_face_focus',
          'device_id': deviceId,
          'enabled': enabled,
        },
      );

  Future<void> flipH({required String deviceId, required bool enabled}) =>
      _mutate(
        deviceId: deviceId,
        field: _Field.flipH,
        apply: (d) => d.copyWith(flipH: enabled),
        frame: <String, dynamic>{
          'action': 'image.set_flip_h',
          'device_id': deviceId,
          'enabled': enabled,
        },
      );

  /// Update one or more color sliders (0..100). Only fields passed are
  /// sent and only they are overlaid; unset fields are left untouched on
  /// the camera and in local state.
  Future<void> colorSet({
    required String deviceId,
    int? brightness,
    int? contrast,
    int? saturation,
    int? sharpness,
  }) {
    final frame = <String, dynamic>{
      'action': 'image.set_color',
      'device_id': deviceId,
    };
    if (brightness != null) frame['brightness'] = brightness;
    if (contrast != null) frame['contrast'] = contrast;
    if (saturation != null) frame['saturation'] = saturation;
    if (sharpness != null) frame['sharpness'] = sharpness;
    return _mutate(
      deviceId: deviceId,
      field: _Field.color,
      apply: (d) => d.copyWith(
        brightness: brightness,
        contrast: contrast,
        saturation: saturation,
        sharpness: sharpness,
      ),
      frame: frame,
    );
  }

  Future<void> setExposureMode({
    required String deviceId,
    required String mode,
  }) => _mutate(
    deviceId: deviceId,
    field: _Field.exposureMode,
    apply: (d) => d.copyWith(exposureMode: mode),
    frame: <String, dynamic>{
      'action': 'image.set_exposure_mode',
      'device_id': deviceId,
      'mode': mode,
    },
  );

  Future<void> setEvBias({required String deviceId, required double bias}) =>
      _mutate(
        deviceId: deviceId,
        field: _Field.evBias,
        apply: (d) => d.copyWith(evBias: bias),
        frame: <String, dynamic>{
          'action': 'image.set_ev_bias',
          'device_id': deviceId,
          'bias': bias,
        },
      );

  Future<void> setAntiFlicker({
    required String deviceId,
    required String mode,
  }) => _mutate(
    deviceId: deviceId,
    field: _Field.antiFlicker,
    apply: (d) => d.copyWith(antiFlicker: mode),
    frame: <String, dynamic>{
      'action': 'image.set_anti_flicker',
      'device_id': deviceId,
      'mode': mode,
    },
  );

  Future<void> setWbAuto({required String deviceId, required bool enabled}) =>
      _mutate(
        deviceId: deviceId,
        field: _Field.wbAuto,
        apply: (d) => d.copyWith(wbAuto: enabled),
        frame: <String, dynamic>{
          'action': 'image.set_wb_auto',
          'device_id': deviceId,
          'enabled': enabled,
        },
      );

  Future<void> setWbTemp({required String deviceId, required int kelvin}) =>
      _mutate(
        deviceId: deviceId,
        field: _Field.wbKelvin,
        apply: (d) => d.copyWith(wbKelvin: kelvin),
        frame: <String, dynamic>{
          'action': 'image.set_wb_temp',
          'device_id': deviceId,
          'kelvin': kelvin,
        },
      );

  /// Ask the bridge to re-read live exposure / anti-flicker / WB from the
  /// camera and re-stamp its snapshot. No overlay: this is a read-back
  /// request, its whole point is to pull the camera's real values.
  Future<void> imageRefresh({required String deviceId}) => _command(
    <String, dynamic>{'action': 'image.refresh', 'device_id': deviceId},
  );

  // ---- Presets (no overlay: recalled/saved pose values not known locally) ----

  Future<void> presetSave({
    required String deviceId,
    required int presetId,
    required String name,
  }) => _command(<String, dynamic>{
    'action': 'preset.save',
    'device_id': deviceId,
    'preset_id': presetId,
    'name': name,
  });

  /// Recall a saved preset. [duration] drives the motion planner's eased
  /// move; omit (or `Duration.zero`) for the camera's fastest hardware
  /// recall. The caller's chosen move duration is passed straight
  /// through - the move-duration *preference* is a presentation concern
  /// and lives above this layer.
  Future<void> presetRecall({
    required String deviceId,
    required int presetId,
    Duration? duration,
  }) => _command(<String, dynamic>{
    'action': 'preset.recall',
    'device_id': deviceId,
    'preset_id': presetId,
    'duration_ms': (duration ?? Duration.zero).inMilliseconds,
  });

  Future<void> presetDelete({
    required String deviceId,
    required int presetId,
  }) => _command(<String, dynamic>{
    'action': 'preset.delete',
    'device_id': deviceId,
    'preset_id': presetId,
  });

  // ---- System ----

  Future<void> runStatus({required String deviceId, required String status}) =>
      _command(<String, dynamic>{
        'action': 'system.run_status',
        'device_id': deviceId,
        'status': status,
      });

  // ---- Sequencer (per-device) ----

  Future<void> sequenceSet({
    required String deviceId,
    required List<SequenceStep> steps,
    LoopMode mode = LoopMode.forward,
  }) => _command(<String, dynamic>{
    'action': 'sequence.set',
    'device_id': deviceId,
    'steps': steps.map((s) => s.toJson()).toList(),
    'mode': loopModeToWire(mode),
    // Legacy boolean for pre-v1.2 bridges that predate `mode`.
    'loop': mode != LoopMode.once,
  });

  Future<void> sequenceStart({required String deviceId}) => _command(
    <String, dynamic>{'action': 'sequence.start', 'device_id': deviceId},
  );

  Future<void> sequenceStop({required String deviceId}) => _command(
    <String, dynamic>{'action': 'sequence.stop', 'device_id': deviceId},
  );

  Future<void> sequenceSaveAs({
    required String deviceId,
    required String name,
    required List<SequenceStep> steps,
    LoopMode mode = LoopMode.forward,
  }) => _command(<String, dynamic>{
    'action': 'sequence.save_as',
    'device_id': deviceId,
    'name': name,
    'mode': loopModeToWire(mode),
    'steps': steps.map((s) => s.toJson()).toList(),
  });

  Future<void> sequenceLoad({required String deviceId, required String name}) =>
      _command(<String, dynamic>{
        'action': 'sequence.load',
        'device_id': deviceId,
        'name': name,
      });

  Future<void> sequenceDelete({
    required String deviceId,
    required String name,
  }) => _command(<String, dynamic>{
    'action': 'sequence.delete',
    'device_id': deviceId,
    'name': name,
  });

  Future<void> dispose() async {
    for (final byField in _overlays.values) {
      for (final ov in byField.values) {
        ov.cancelTimer();
      }
    }
    _overlays.clear();
    await _sub.cancel();
    await _updates.close();
  }
}
