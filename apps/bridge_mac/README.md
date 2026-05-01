# bridge_mac (planned)

Flutter macOS app that replaces `apps/bridge_cpp/` with a single user-friendly bundle.

## Architecture

```
[ Flutter UI (Dart) ]
        │
        ├── shelf_web_socket  →  serves the LAN WS API on :8765
        │
        └── Pigeon-generated bridge ──►  Swift wrapper  ──► libdev (C++)
```

- **No Terminal.** Drag-and-drop `.app` install, menu-bar status icon, "start at login" toggle.
- **WebSocket server in pure Dart** via [`shelf_web_socket`](https://pub.dev/packages/shelf_web_socket). Same JSON protocol documented in `docs/PROTOCOL.md`.
- **Pigeon** generates the type-safe Dart ↔ Swift bridge for SDK calls. See `packages/obsbot_native/`.
- **Swift wrapper** uses Swift 5.9+ C++ interop to call `libdev` directly. No `extern "C"` shim required.
- Same `libdev.dylib` from `third_party/obsbot-sdk/macos/<arch>-release/` is bundled inside `Frameworks/`.

## Status

Not started yet. C++ version (`apps/bridge_cpp/`) is the working reference today.

When this is built it will replace the C++ bridge; that folder will be deleted.
