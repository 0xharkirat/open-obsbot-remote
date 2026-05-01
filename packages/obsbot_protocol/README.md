# obsbot_protocol (planned)

Pure-Dart package: shared types + JSON codec for the WebSocket protocol between mobile clients and the bridge.

Both `apps/mobile/` and `apps/bridge_mac/` will depend on this package so they can't drift apart.

Spec: [docs/PROTOCOL.md](../../docs/PROTOCOL.md).

## Status

Not started. Today the protocol types live inline in `apps/mobile/lib/ws_client.dart` and in C++ in `apps/bridge_cpp/src/protocol.cpp`. To be extracted here.
