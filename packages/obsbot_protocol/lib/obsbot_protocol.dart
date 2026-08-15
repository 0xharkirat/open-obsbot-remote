/// Shared Dart types for the OBSBOT Bridge WebSocket protocol.
///
/// Pure-Dart, no Flutter dependency. The wire format is documented in
/// `docs/PROTOCOL.md` at the repo root. Bridge implementation in
/// `apps/bridge_cpp/src/protocol.cpp` (C++); client implementation in
/// `apps/rc/lib/ws_client.dart` (Dart).
///
/// Versioning: the package version (in pubspec.yaml) tracks the wire
/// protocol version. The bridge advertises its supported protocol in
/// the state event's `version` field; clients should accept any
/// version they were built against.
///
/// **v2 multi-cam break**: [CameraState] was renamed to [DeviceState]
/// and wrapped in [BridgeState] which owns the per-camera list. State
/// events now ship as `{devices: [...], active_device_id: "..."}`
/// instead of a single device snapshot. v1 clients that connect to v2
/// bridges get an error from the handshake (and vice-versa).
library;

export 'src/audio_state.dart';
export 'src/available_source.dart';
export 'src/bridge_state.dart';
export 'src/device_state.dart';
export 'src/loop_mode.dart';
export 'src/mix_state.dart';
export 'src/move_duration_preset.dart';
export 'src/preset_entry.dart';
export 'src/recording_state.dart';
export 'src/sequence_state.dart';
export 'src/sequence_step.dart';
