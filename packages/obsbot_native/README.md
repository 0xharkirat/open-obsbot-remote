# obsbot_native (planned)

Flutter plugin / federated FFI package wrapping the OBSBOT C++ SDK so Dart code can call camera APIs without a separate bridge process.

## Layers

```
Dart API  (obsbot_native.dart)
   │
Pigeon-generated bridge code  (lib/src/messages.g.dart  ←→  ios/Classes/Messages.g.swift  ←→  macos/Classes/Messages.g.swift)
   │
Platform-side wrapper  (Swift on macOS / iOS, .kt on Android)
   │
libdev  (third_party/obsbot-sdk/<platform>/<arch>-release/)
```

- iOS likely won't be wired up at first  -  `libdev` ships only macOS / Linux / Windows binaries. (iOS would need an OBSBOT-compiled iOS slice, which we'd need to request.)
- macOS uses Swift 5.9+ C++ interop directly against the SDK headers.
- Android uses JNI + an arm64 `libdev.so` from OBSBOT's Linux build.

## Distribution

The package itself can be MIT/Apache. The SDK binary it depends on **cannot** be redistributed today (see [docs/GETTING_THE_SDK.md](../../docs/GETTING_THE_SDK.md)). Until OBSBOT clarifies licensing, the plugin pulls libdev from `third_party/obsbot-sdk/` at build time rather than bundling it.

## Status

Not started.
