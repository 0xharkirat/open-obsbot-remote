/// Shared Dart types for the OBSBOT Bridge WebSocket protocol.
///
/// Pure-Dart, no Flutter dependency. The wire format is documented in
/// `docs/PROTOCOL.md` at the repo root. Bridge implementation in
/// `apps/bridge_cpp/src/protocol.cpp` (C++); client implementation in
/// `apps/rc/lib/ws_client.dart` (Dart).
///
/// Versioning: the package version (in pubspec.yaml) tracks the wire
/// protocol version. The bridge advertises its supported protocol in
/// the `hello` ack's `server.protocol` field; clients should accept
/// any version they were built against.
library;

export 'src/camera_state.dart';
export 'src/loop_mode.dart';
export 'src/move_duration_preset.dart';
export 'src/preset_entry.dart';
export 'src/sequence_state.dart';
export 'src/sequence_step.dart';
