# Build from source

Use this guide to build the bridge and the remote yourself, either to develop or to run a version that has no release.

For installing a published release instead, see [Install the bridge on macOS](INSTALL.md).

## Prerequisites

- You have a Mac with Xcode command line tools: `xcode-select --install`.
- You have CMake and Asio: `brew install cmake asio`.
- You have Flutter stable with macOS desktop and web support enabled, and `flutter doctor` reports no blocking issues.
- You have your own copy of the OBSBOT Camera SDK. The SDK is not committed to git.

## Add the SDK

1. Request the Camera SDK from OBSBOT, and unzip it.
2. Place it at `third_party/obsbot-sdk/` so that these paths exist:

   ```text
   third_party/obsbot-sdk/include/dev/dev.hpp
   third_party/obsbot-sdk/include/dev/devs.hpp
   third_party/obsbot-sdk/macos/arm64-release/libdev.dylib
   ```

3. Verify the layout:

   ```bash
   ./scripts/verify-sdk.sh
   ```

[Getting the SDK](GETTING_THE_SDK.md) covers the request in detail.

## Build the bridge

From the repository root, run:

```bash
./scripts/build-bridge-mac.sh
```

The script builds the C++ bridge as a universal binary and builds both the Flutter web remote and the Flutter macOS shell.
It then copies `obsbot-bridge`, `libdev.dylib`, and the web assets into the app bundle.
Finally it ad-hoc signs the bundle, so the subprocess inherits the camera grant, and packs a DMG.

It writes 2 artifacts:

```text
apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app
dist/Open-OBSBOT-Bridge-universal.dmg
```

Launch the result:

```bash
open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
```

Then follow [Grant camera access](INSTALL.md#grant-camera-access) and the steps after it.

## Build the remote

The bridge serves the web remote, so most people never build these.

```bash
cd apps/rc
flutter build apk --release        # Android
flutter build ios --release        # iOS, needs Apple signing
flutter build macos --release      # macOS desktop
flutter build web --release        # Web, also built by build-bridge-mac.sh
```

Android release builds sign with the keystore named in `apps/rc/android/key.properties`.
Without that file the release build falls back to debug signing and prints a warning, so a fresh clone still builds.

## Sign and notarize a public release

1. Install a `Developer ID Application` certificate with its private key in your login keychain, and confirm macOS sees it:

   ```bash
   security find-identity -v -p codesigning
   ```

2. Store a notarization credential once:

   ```bash
   xcrun notarytool store-credentials open-obsbot-notary \
     --apple-id "<apple-id>" \
     --team-id "<team-id>" \
     --password "<app-specific-password>"
   ```

3. Build, sign, notarize, staple, and package:

   ```bash
   NOTARYTOOL_PROFILE=open-obsbot-notary ./scripts/package-mac-release.sh 2.5.0
   ```

   With several Developer ID identities in the keychain, pin one:

   ```bash
   SIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
   NOTARYTOOL_PROFILE=open-obsbot-notary \
   ./scripts/package-mac-release.sh 2.5.0
   ```

## Iterate on the C++ bridge

To run the bridge without rebuilding the Flutter shell:

```bash
./run-bridge.sh
```

The script starts the bridge in your terminal, which means Terminal itself needs macOS camera permission for the preview to work.
Test end-user behavior against the app bundle instead.

Static analysis across both Flutter apps:

```bash
flutter analyze apps/rc apps/bridge
```

## Repository layout

| Path | Contents |
| --- | --- |
| `apps/bridge_cpp/` | C++ bridge: OBSBOT `libdev`, Crow WebSocket and static HTTP, and a hand-rolled MJPEG server. |
| `apps/bridge/` | Flutter macOS app that supervises the C++ subprocess. |
| `apps/rc/` | Flutter remote for Web, Android, iOS, and macOS. |
| `packages/` | Shared Dart packages: `obsbot_protocol`, `obsbot_api_client`, `auth_repository`, `bridge_repository`, `device_repository`. |
| `scripts/` | Build, packaging, and SDK verification scripts. |
| `tests/` | Node test batteries that drive a running bridge over WebSocket. |

## Runtime files

The bridge persists state under `~/Library/Application Support/Open OBSBOT Bridge/`:

| File | Contents |
| --- | --- |
| `auth.json` | Pairing PIN and issued tokens. |
| `active.json` | The camera OBS follows. |
| `device_names.json` | Per-camera friendly names. |
| `sources.json` | Generic (non-OBSBOT) video sources the operator added. |
| `sequence.json` | Active single-camera sequence scratch. |
| `sequences.json` | Saved single-camera sequences, keyed by serial number. |
| `mix.json` | Active mix-sequence scratch. |
| `mix_sequences.json` | Saved mix sequences. |

Logs are at `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.

## Additional resources

- [Architecture](ARCHITECTURE.md) explains the process boundaries.
- [Protocol](PROTOCOL.md) documents the WebSocket API.
- [Contributing](CONTRIBUTING.md) covers the pull request workflow.
