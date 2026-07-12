/// WebSocket transport for the Open OBSBOT Bridge protocol.
///
/// This is the bottom of the client stack. It moves JSON frames, assigns
/// request ids, and correlates acks. It has no idea what a camera is.
/// Domain types and per-device semantics live in `bridge_repository` and
/// `device_repository` above it.
library;

export 'src/exceptions.dart';
export 'src/obsbot_api_client.dart';
