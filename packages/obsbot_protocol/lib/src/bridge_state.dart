import 'package:meta/meta.dart';

import 'device_state.dart';
import 'mix_state.dart';

/// Top-level state pushed by the bridge in every v2 `state` event.
///
/// v1.x pushed a single [DeviceState] (then called `CameraState`)
/// directly as the state payload. v2 wraps N devices + multi-cam
/// concerns (which one is going out to OBS, what protocol version
/// the bridge speaks) into this envelope.
///
/// Wire shape:
/// ```json
/// {
///   "event": "state",
///   "version": "2.0",
///   "active_device_id": "RMOW1234",
///   "devices": [ {device_state_1}, {device_state_2}, ... ]
/// }
/// ```
@immutable
class BridgeState {
  /// Protocol version the bridge advertises. v1 bridges either omit
  /// this or send "1.x"; v2 bridges send "2.0" or later. Clients use
  /// this to bail early if the bridge speaks a version they don't
  /// understand.
  final String protocolVersion;

  /// Cameras the bridge sees, in attach order. Empty list = no
  /// cameras connected (covered by the empty state on cold boot).
  final List<DeviceState> devices;

  /// `device_id` of the camera that's currently routed to OBS (the
  /// "live" camera). Empty when no device is live. v2.0 ships
  /// without a virtual cam, so this is informational; phone + bridge
  /// UI still use it to badge the LIVE pill on the picker.
  final String activeDeviceId;

  /// Cross-camera sequencer (P3) status + scratch cues + saved library.
  /// [MixState.empty] on v1/v2.0 bridges that don't emit a `mix` block.
  final MixState mix;

  const BridgeState({
    required this.protocolVersion,
    required this.devices,
    required this.activeDeviceId,
    this.mix = MixState.empty,
  });

  static const empty = BridgeState(
    protocolVersion: '',
    devices: <DeviceState>[],
    activeDeviceId: '',
  );

  /// Returns the [DeviceState] matching [deviceId], or null if no
  /// device with that id is connected (e.g. it was unplugged after
  /// the client last refreshed).
  DeviceState? deviceById(String deviceId) {
    for (final d in devices) {
      if (d.deviceId == deviceId) return d;
    }
    return null;
  }

  /// The currently-live device, or null if no device is live or the
  /// live id doesn't match any connected device.
  DeviceState? get activeDevice => deviceById(activeDeviceId);

  /// Parses a v2 state event.
  ///
  /// Tolerates the v1 single-device shape: if the payload has no
  /// `devices` array but DOES have a top-level `device` field, it
  /// wraps that single device into a one-element list and uses its
  /// SN as the active id. Lets clients connect to v1 bridges during
  /// the rollout window without exploding.
  factory BridgeState.fromEvent(Map<String, dynamic> j) {
    final version = j['version'] as String? ?? '';
    final List<dynamic>? devicesRaw = j['devices'] as List<dynamic>?;
    if (devicesRaw == null) {
      // v1 shape - the whole payload IS one device. Wrap it.
      final single = DeviceState.fromEvent(j);
      return BridgeState(
        protocolVersion: version,
        devices: <DeviceState>[single],
        activeDeviceId: single.deviceId,
      );
    }
    final devices = devicesRaw
        .whereType<Map<String, dynamic>>()
        .map(DeviceState.fromEvent)
        .toList(growable: false);
    final mixRaw = j['mix'];
    return BridgeState(
      protocolVersion: version,
      devices: devices,
      activeDeviceId: j['active_device_id'] as String? ?? '',
      mix: mixRaw is Map<String, dynamic>
          ? MixState.fromJson(mixRaw)
          : MixState.empty,
    );
  }

  BridgeState copyWith({
    String? protocolVersion,
    List<DeviceState>? devices,
    String? activeDeviceId,
    MixState? mix,
  }) {
    return BridgeState(
      protocolVersion: protocolVersion ?? this.protocolVersion,
      devices: devices ?? this.devices,
      activeDeviceId: activeDeviceId ?? this.activeDeviceId,
      mix: mix ?? this.mix,
    );
  }

  /// Returns a copy with one device replaced. Used by the optimistic
  /// overlay in `device_repository` for per-device mutations:
  /// `current.withDevice(deviceId, dev.copyWith(...))`.
  /// Throws StateError if no device with that id exists.
  BridgeState withDevice(String deviceId, DeviceState next) {
    final idx = devices.indexWhere((d) => d.deviceId == deviceId);
    if (idx < 0) {
      throw StateError('no device with id "$deviceId" in BridgeState');
    }
    final updated = List<DeviceState>.from(devices);
    updated[idx] = next;
    return copyWith(devices: updated);
  }
}
