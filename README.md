# Open OBSBOT Remote

Open OBSBOT Remote is a phone and browser remote for OBSBOT cameras.

It lets a phone, tablet, or laptop on the same local network control a USB-connected OBSBOT camera: pan, tilt, zoom, recall presets, adjust image settings, run saved timed sequences, and view a live MJPEG preview. The bridge runs locally on the computer connected to the camera. No cloud service or account is involved.

## Current Status

This project is usable today for the tested camera path. The macOS release artifact is an ad-hoc signed `.app` ZIP for Apple Silicon Macs.

- Tested camera: OBSBOT Tiny 2 Lite.
- Bridge host: macOS with Apple Silicon.
- Phone remote: Web, Android, and iOS Flutter clients are present. The web client is the easiest path because it is served by the bridge.
- Distribution: GitHub Release ZIP for macOS, plus source builds for developers.
- Firmware updates still require OBSBOT Center.

## What You Get

| App | Purpose |
| --- | --- |
| Open OBSBOT Bridge | macOS app that talks to the camera over USB, exposes a local WebSocket API on `:8765`, serves the web remote at `http://<computer-ip>:8765/`, and serves MJPEG preview on `:8766`. |
| Open OBSBOT Remote | Flutter phone/web controller for presets, PTZ, zoom, image controls, AI mode, and sequences. |

```
Phone / browser
  |
  |  local Wi-Fi, JSON WebSocket + PIN token
  v
Open OBSBOT Bridge on the camera computer
  |
  |  USB via OBSBOT libdev SDK
  v
OBSBOT camera
```

## Features

- Live MJPEG preview over the LAN.
- PTZ joystick, absolute angle moves, stop, and recenter.
- Zoom with camera-reported min/max range.
- Camera presets with names and active-preset highlight.
- Move-speed choices for preset recalls: instant, slow, medium, fast.
- Saved timed sequences with once, forward loop, and ping-pong loop modes.
- AI modes: none, human, group, hand, whiteboard, desk.
- Image controls: HDR, FOV, brightness, contrast, saturation, sharpness, face AE, face focus, horizontal flip.
- Sleep and wake.
- PIN pairing with long-lived tokens. Tokens gate WebSocket commands and MJPEG preview URLs.
- Simple mode for quick preset control and advanced mode for tuning.
- Bridge auto-restart and single-instance enforcement.
- Logs at `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.

## Known Limits

- The Tiny 2 Lite path is the only hardware path tested end to end.
- The shipped bridge target is macOS only today. The SDK includes other platform binaries, but Windows and Linux packaging are not wired yet.
- The macOS release ZIP bundles OBSBOT's runtime `libdev.dylib`; the SDK headers/samples are not committed to git.
- Public macOS ZIPs should be Developer ID signed and notarized. If no Developer ID certificate is installed locally, the packaging script falls back to ad-hoc signing for development builds.
- There is no TLS. Keep the bridge on trusted LANs and do not port-forward ports `8765` or `8766`.
- Native app store distribution is not set up. Use the web remote or build native clients yourself.

## Install The macOS Release

Use this path if you just want to control a camera and do not need to build from source.

1. Download `Open-OBSBOT-Bridge-macOS-arm64-v<version>.zip` from GitHub Releases.
2. Unzip it (double-click the ZIP in Finder).
3. Drag `Open OBSBOT Bridge.app` to `/Applications`.
4. Quit OBSBOT Center if it is running — both apps compete for the same camera control endpoint.
5. Plug the OBSBOT camera into the computer over USB.
6. **First launch — Gatekeeper:** Because this release is not notarized with Apple (that requires a paid $99/yr developer account), macOS will block the first open. To allow it:
   - Go to **System Settings → Privacy & Security**.
   - Scroll down to the **Security** section — you will see a message like *"Open OBSBOT Bridge" was blocked from use because it is not from an identified developer*.
   - Click **Open Anyway**, then click **Open** in the confirmation dialog.
   - You only need to do this once. _(Screenshots in [docs/INSTALL_SCREENSHOTS](docs/INSTALL_SCREENSHOTS/))_
7. Allow the macOS **Camera** and **Local Network** permission prompts.
8. In the bridge window, click **Reveal** to show the pairing PIN and QR code.
9. On a phone or laptop on the same Wi-Fi, scan the QR code or open `http://<computer-ip>:8765/`.
10. Enter the 6-digit PIN once. The remote saves a token for future connects.

The release ZIP includes the bridge app, the bundled C++ bridge subprocess, the bundled Flutter web remote, and the OBSBOT SDK runtime dylib needed by the app. It does not include the full OBSBOT SDK source/header package.

If preview does not appear, check macOS Camera permission and the bridge log at `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.

## Build From Source

Use this path when no release ZIP is available, when you want to develop, or when you need to rebuild the app yourself.

### 1. Install Tools

On the macOS bridge host:

```bash
xcode-select --install
brew install cmake asio
```

Install Flutter stable and confirm it works:

```bash
flutter doctor
```

The build script expects Flutter to support macOS desktop and web builds.

### 2. Clone The Repo

Use the clone URL you have access to:

```bash
git clone <repo-url>
cd open-obsbot-remote
```

### 3. Add The OBSBOT SDK

The OBSBOT SDK is not checked into git. Request the Camera SDK from OBSBOT, unzip it, and place it here:

```text
third_party/obsbot-sdk/
```

The required files include:

```text
third_party/obsbot-sdk/include/dev/dev.hpp
third_party/obsbot-sdk/include/dev/devs.hpp
third_party/obsbot-sdk/macos/arm64-release/libdev.dylib
```

Verify the SDK layout:

```bash
./scripts/verify-sdk.sh
```

More detail: [docs/GETTING_THE_SDK.md](docs/GETTING_THE_SDK.md).

### 4. Build The Bridge App

From the repo root:

```bash
./scripts/build-bridge-mac.sh
```

The script does five things:

1. Builds `apps/bridge_cpp/obsbot-bridge` with CMake.
2. Builds the Flutter web remote from `apps/rc/`.
3. Builds the Flutter macOS bridge shell from `apps/bridge/`.
4. Copies `obsbot-bridge`, `libdev.dylib`, and web assets into the `.app`.
5. Ad-hoc signs the bundle so the subprocess can inherit camera permission.

Output:

```text
apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app
```

### 5. Launch

```bash
open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
```

Then follow the install flow above: allow permissions, reveal the PIN, and open the bridge URL from the controller device.

To create the same ZIP shape used for GitHub Releases:

```bash
./scripts/package-mac-release.sh
```

Output lands in `dist/` and is intentionally gitignored.

### Developer ID Signed Release

For a public macOS release, install a `Developer ID Application` certificate with its private key in your login keychain. Xcode can create this from `Xcode > Settings > Accounts > Manage Certificates`.

Confirm macOS can see it:

```bash
security find-identity -v -p codesigning
```

Create a saved notarization credential once:

```bash
xcrun notarytool store-credentials open-obsbot-notary \
  --apple-id "<apple-id>" \
  --team-id "<team-id>" \
  --password "<app-specific-password>"
```

Then build, Developer ID sign, notarize, staple, ZIP, and checksum:

```bash
NOTARYTOOL_PROFILE=open-obsbot-notary ./scripts/package-mac-release.sh 1.0.0
```

If there are multiple Developer ID identities, pin the one to use:

```bash
SIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
NOTARYTOOL_PROFILE=open-obsbot-notary \
./scripts/package-mac-release.sh 1.0.0
```

## Optional: Build Native Phone Apps

The web remote is usually enough. Native builds are useful for development or sideloading.

```bash
cd apps/rc
flutter build apk --release
flutter build ios --release
flutter build web --release
```

iOS release builds require normal Apple signing setup. The web build is normally produced by `./scripts/build-bridge-mac.sh` and bundled into the bridge app.

## Developer Workflow

Common commands:

```bash
./scripts/verify-sdk.sh
./scripts/build-bridge-mac.sh
flutter analyze apps/rc apps/bridge
```

For C++ bridge-only iteration:

```bash
./run-bridge.sh
```

`run-bridge.sh` starts the bridge directly from the terminal. Terminal must have macOS Camera permission for preview capture to work. For realistic end-user behavior, prefer the `.app` build.

Useful paths:

| Path | Purpose |
| --- | --- |
| `apps/bridge_cpp/` | C++ bridge using OBSBOT `libdev`, Crow WebSocket/static HTTP, and a small BSD-socket MJPEG server. |
| `apps/bridge/` | Flutter macOS wrapper app that supervises the C++ subprocess. |
| `apps/rc/` | Flutter remote for web, Android, and iOS. |
| `docs/PROTOCOL.md` | WebSocket and pairing protocol. |
| `docs/ARCHITECTURE.md` | Runtime architecture and process boundaries. |
| `docs/RUN.md` | Manual test and troubleshooting guide. |

Persisted runtime files:

| File | Purpose |
| --- | --- |
| `~/Library/Logs/Open OBSBOT Bridge/bridge.log` | Bridge and SDK logs. |
| `~/Library/Application Support/Open OBSBOT Bridge/auth.json` | Pairing PIN and issued tokens. |
| `~/Library/Application Support/Open OBSBOT Bridge/sequence.json` | Last active sequence. |
| `~/Library/Application Support/Open OBSBOT Bridge/sequences.json` | Saved sequence library. |

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Phone cannot connect | Phone and bridge host must be on the same LAN. Check the bridge URL shown in the app. VPNs and guest Wi-Fi often block local devices. |
| Preview is blank | Confirm macOS Camera permission for Open OBSBOT Bridge. Reopen the app after granting permission. |
| PTZ commands fail with `device_busy` | Quit OBSBOT Center and any other app controlling the camera, then restart the bridge. |
| Build cannot find SDK | Run `./scripts/verify-sdk.sh` and fix the `third_party/obsbot-sdk/` layout. |
| Web app looks stale | Use the cache-clear menu in the remote, or reload the browser after restarting the bridge. |
| Camera is not detected | Try another USB cable/port and wait for the camera boot sequence to finish. |

## Security

The bridge is designed for trusted local networks. Pairing uses a 6-digit PIN and then a 32-byte bearer token. The MJPEG preview requires the token as `?t=<token>`.

Do not expose the bridge to the public internet. See [SECURITY.md](SECURITY.md) for the threat model and current hardening gaps.

## Camera Compatibility

See [docs/CAMERAS.md](docs/CAMERAS.md).

The current implementation is intentionally centered on the tested OBSBOT Tiny 2 Lite path. Other OBSBOT models should be possible because the SDK exposes broad camera support, but each model needs real hardware validation before it should be listed as supported.

## License

| Component | License |
| --- | --- |
| Code in this repository | Apache 2.0. See [LICENSE](LICENSE). |
| OBSBOT SDK headers/samples | Not committed to git. Developers obtain their own local copy from OBSBOT. |
| OBSBOT SDK runtime dylib | Bundled in macOS release artifacts so the app runs without a local SDK install. |

Check OBSBOT's SDK terms before publishing release assets that include `libdev.dylib`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
