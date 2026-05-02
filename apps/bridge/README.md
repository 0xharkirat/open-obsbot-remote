# Open OBSBOT Bridge

Flutter desktop app that wraps the C++ `obsbot-bridge` (under `apps/bridge_cpp/`) as a managed subprocess inside a single notarizable `.app` bundle.

## Today

- macOS Apple Silicon, ad-hoc signed for dev. Bundle ID `com.harksingh.obsbotbridge`, display name "Open OBSBOT Bridge".
- UI shows: bridge status, camera permission, paired-device count, pairing PIN (hidden until "Reveal"), QR code + URL for the web client, scrolling subprocess log, "Reset pairing" button.
- Auto-restarts the subprocess if it crashes (5 attempts, quadratic backoff).
- Single-instance enforced via `LSMultipleInstancesProhibited` + `applicationDidFinishLaunching` self-quit if a sibling is already running.

## Build

```bash
./scripts/build-bridge-mac.sh
open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
```

## Planned (folder name reflects this)

- Windows + Linux targets in the same Flutter project.
- Eventually fold the C++ subprocess into the .app via Pigeon → Swift → libdev (single-process).

Internal Dart package name in `pubspec.yaml` stays as `obsbot_bridge_mac` to avoid breaking imports during the rename — that's purely cosmetic.
