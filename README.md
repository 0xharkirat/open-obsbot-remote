# Open OBSBOT Remote

Open OBSBOT Remote turns a phone or browser into a control surface for one or more OBSBOT cameras, and feeds OBS a single video source that you switch between cameras from the remote.

The bridge runs on the Mac the cameras are plugged into.
It controls each camera over USB and serves the remote UI, a JSON control API, and an MJPEG preview over the local network.
No cloud service or account is involved.

The point of the design: OBS holds one Browser Source pointed at the bridge.
Switching cameras, moving them, and running timed sequences all happen on the remote, so there are no per-camera sources or scene switches to manage in OBS.

> Just want to install it? [Skip to macOS installation](#install-the-macos-release).

## Current status

The tested path is two OBSBOT Tiny 2 Lite cameras on an Apple Silicon Mac, driven from the web remote.

- Cameras: OBSBOT Tiny 2 Lite (one or more). Other OBSBOT models are likely to work through the same SDK but are not validated on hardware.
- Bridge host: macOS. The release DMG is a universal build for Apple Silicon and Intel.
- Remote: the Flutter client targets Web, Android, and iOS. The web build is served by the bridge, so no app-store install is needed.
- Firmware updates still require OBSBOT Center.

## The two apps

| App | What it does |
| --- | --- |
| Open OBSBOT Bridge | macOS app. Talks to every attached camera over USB, serves the control API on `ws://<mac>:8765/v1`, serves the web remote at `http://<mac>:8765/`, and serves MJPEG preview on `:8766`. |
| Open OBSBOT Remote | Flutter controller for Web, Android, and iOS. Switches cameras, drives PTZ and zoom, recalls presets, edits image settings, and runs sequences. |

```
Phone / browser (Open OBSBOT Remote)
  |
  |  LAN, JSON over WebSocket, PIN-paired token
  v
Open OBSBOT Bridge on the Mac
  |  \
  |   \  MJPEG /preview/active.mjpg  -->  OBS Browser Source (one source)
  |
  |  USB via OBSBOT libdev SDK
  v
OBSBOT cameras (one or more)
```

## How switching works

Two ideas stay separate:

- Selection is which camera the remote is currently controlling.
- On air (active) is which camera OBS is showing, that is, which camera `/preview/active.mjpg` follows.

You stage a camera by selecting it, frame it, then press TAKE to put it on air.
A take is a hard cut by default, or a fade from black.
Because OBS follows `active.mjpg`, the cut happens inside the bridge and OBS needs no scene change.

## Features

### Multi-camera switching

- Any number of attached cameras appear in the remote and in the bridge window, each with its own status, name, and preview.
- The camera bus on the Live screen shows every camera and marks the one on air.
- TAKE commits the staged camera to air, as a cut or a fade from black.
- OBS reads one Browser Source (`/preview/active.mjpg`); the URL carries the pairing token.

### Live control

- Preview over the LAN with an optional grid overlay: center crosshair, attitude indicator, rule-of-thirds guides, and a live Pan/Tilt readout.
- Tap a direction to nudge by a fixed step, hold to glide at a ramped speed, or switch to an analog joystick with a squared response curve. Releasing stops the motor.
- Speed presets (Fine, Normal, Fast) set the nudge step and the glide ceiling.
- Zoom over the camera-reported range (1.0x to 2.0x on the Tiny 2 Lite).
- Six presets per camera (P1 to P6). Tap to recall, hold to save or rename.

### Mix sequencer

- A cross-camera timeline of cues. Each cue names the camera to put on air, the shot to take (a preset, or hold the current shot), how long the move takes, how long to hold, and whether to cut or fade in.
- A cue can pre-position a second camera while the current cue holds.
- The sequence runs on the bridge, so it keeps running if the phone disconnects. Loop modes are Once, Forward, and Ping-pong.
- Each camera also keeps its own single-camera sequence of preset moves.

### Image controls

- Auto-track work mode: Off, Person, or Group.
- FOV: Wide (86 deg), Normal (78 deg), Narrow (65 deg).
- Exposure mode (Auto or Manual) with an EV bias slider, anti-flicker (Off, 50 Hz, 60 Hz), and white balance (Auto, or a temperature slider from 2800 K to 6500 K).
- Brightness, Contrast, Saturation, and Sharpness sliders, each with a reset.
- HDR, Face exposure, Face focus, and Horizontal flip toggles. Refresh from camera re-reads the live values.

### Library

- Export the authored library (single-camera sequences, mix sequences, and camera names) as JSON, and import it on another Mac.
- Presets are stored on the camera hardware, so they move with the camera and are not part of the export.

### Bridge app

- The pairing PIN and QR sit at the top of the window. Reveal shows them for 60 seconds.
- A menu-bar item (`NSStatusItem`) keeps the bridge running when the window is closed. The tray menu shows the PIN inline and copies it, opens the log, restarts the subprocess, and quits.
- The dock icon follows window visibility. "Start hidden in menu bar" boots straight to the tray; the window still force-shows the first time so you can pair.
- Each attached camera has a row with its status, an on-air badge, a Set live action, and rename.
- The OBS output row masks the tokened `active.mjpg` URL and copies the real one on demand.
- Logs are at `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.

## Known limits

- The Tiny 2 Lite is the only camera validated end to end.
- The shipped bridge is macOS only. The SDK includes Windows and Linux binaries, but those targets are not packaged yet.
- The release DMG bundles OBSBOT's `libdev.dylib`. The SDK headers and samples are not committed to git.
- The bridge speaks `ws://` and `http://` with no TLS. Keep it on a trusted LAN and do not port-forward `8765` or `8766`.
- The macOS build is ad-hoc signed, not notarized. First launch needs the Gatekeeper steps below.

## Install the macOS release

### Homebrew

```bash
brew install --cask 0xharkirat/tap/open-obsbot-bridge
```

That taps [0xharkirat/homebrew-tap](https://github.com/0xharkirat/homebrew-tap) and installs the app.
Update later with `brew upgrade --cask open-obsbot-bridge`.
The cask clears the download quarantine, so Gatekeeper does not block first launch. Skip to Step 4 (Camera access).

If Homebrew 6+ refuses the tap, trust it once:

```bash
brew trust 0xharkirat/tap
```

### DMG download

Download `Open-OBSBOT-Bridge-universal.dmg` (Apple Silicon and Intel) from the [latest release](https://github.com/0xharkirat/open-obsbot-remote/releases/latest), open it, and drag `Open OBSBOT Bridge.app` into Applications.

The app is ad-hoc signed, so Gatekeeper blocks first launch.
Follow Steps 1 to 3, or clear the quarantine flag by hand after moving the app:

```bash
xattr -dr com.apple.quarantine "/Applications/Open OBSBOT Bridge.app"
```

Then skip to Step 4.

### Step 1 - Open the app

1. Quit OBSBOT Center if it is running. Both apps compete for the same camera control endpoint.
2. Plug the cameras into the Mac over USB.
3. Double-click Open OBSBOT Bridge in Applications.

macOS blocks it with _"Open OBSBOT Bridge.app" Not Opened_, because the app is not notarized.
Click Done. Do not click Move to Bin.

<img src="docs/images/step-1-click-done.png" alt="Gatekeeper blocks the app - click Done" width="260"/>

### Step 2 - Allow the app in Privacy & Security

Open System Settings, then Privacy & Security, and scroll to the Security section:

> _"Open OBSBOT Bridge.app" was blocked to protect your Mac._

Click Open Anyway.

<img src="docs/images/step-2-settings-privacy-security-open-anyway.png" alt="Privacy & Security - Open Anyway" width="500"/>

### Step 3 - Confirm open

macOS asks once more. Click Open Anyway.

<img src="docs/images/step-3-open-anyway-again.png" alt="Second confirmation - Open Anyway" width="280"/>

You may be asked for your Mac password.
Steps 1 to 3 are a one-time step.

### Step 4 - Allow Camera access

On launch the app asks for Camera access. Click Allow.
Answer this prompt promptly. If it is left unanswered for 60 seconds the capture path times out, and you will need to grant access and restart the bridge.

<img src="docs/images/step-4-allow-camera.png" alt="Allow Camera access" width="400"/>

### Step 5 - Allow network connections

The macOS firewall asks whether `obsbot-bridge` can accept incoming connections. Click Allow.

<img src="docs/images/step-5-allow-incoming-connections.png" alt="Allow incoming network connections" width="400"/>

### Step 6 - Connect a phone

The pairing card is at the top of the bridge window. Click Reveal to show the PIN and QR code.
On any device on the same Wi-Fi, scan the QR code or open `http://<your-mac-ip>:8765/`.
Enter the 6-digit PIN once. The remote saves a token, and later connections are automatic.

### Step 7 - Point OBS at the bridge

In the bridge window, copy the OBS output URL and add it as a Browser Source in OBS.
That one source shows whichever camera is on air. Switching cameras in the remote changes what OBS displays with no scene change.

If preview does not appear, check macOS Camera permission and the bridge log at `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.

## Build from source

Use this when there is no release to install, or when you are developing.

### 1. Install tools

On the macOS bridge host:

```bash
xcode-select --install
brew install cmake asio
```

Install Flutter stable and confirm it works:

```bash
flutter doctor
```

The build script needs Flutter with macOS desktop and web support.

### 2. Clone the repo

```bash
git clone <repo-url>
cd open-obsbot-remote
```

### 3. Add the OBSBOT SDK

The SDK is not checked into git.
Request the Camera SDK from OBSBOT, unzip it, and place it at `third_party/obsbot-sdk/`.
The required files include:

```text
third_party/obsbot-sdk/include/dev/dev.hpp
third_party/obsbot-sdk/include/dev/devs.hpp
third_party/obsbot-sdk/macos/arm64-release/libdev.dylib
```

Verify the layout:

```bash
./scripts/verify-sdk.sh
```

More detail: [docs/GETTING_THE_SDK.md](docs/GETTING_THE_SDK.md).

### 4. Build the bridge app

From the repo root:

```bash
./scripts/build-bridge-mac.sh
```

The script builds the C++ bridge as a universal binary, builds the Flutter web remote, builds the Flutter macOS shell, copies `obsbot-bridge`, `libdev.dylib`, and the web assets into the `.app`, ad-hoc signs the bundle so the subprocess inherits the camera grant, and packs a universal DMG.

Output:

```text
apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app
dist/Open-OBSBOT-Bridge-universal.dmg
```

### 5. Launch

```bash
open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
```

Then follow the install flow above: allow permissions, reveal the PIN, and open the bridge URL from the controller device.

### Developer ID signed release

For a public release, install a `Developer ID Application` certificate with its private key in your login keychain.
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

Then build, sign, notarize, staple, and package:

```bash
NOTARYTOOL_PROFILE=open-obsbot-notary ./scripts/package-mac-release.sh 2.0.0
```

If there are several Developer ID identities, pin one:

```bash
SIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
NOTARYTOOL_PROFILE=open-obsbot-notary \
./scripts/package-mac-release.sh 2.0.0
```

## Build the phone apps

The web remote is usually enough. Native builds are for development or sideloading.

```bash
cd apps/rc
flutter build apk --release
flutter build ios --release
flutter build web --release
```

iOS release builds need the usual Apple signing setup.
The web build is normally produced by `./scripts/build-bridge-mac.sh` and bundled into the bridge app.

## Developer workflow

```bash
./scripts/verify-sdk.sh
./scripts/build-bridge-mac.sh
flutter analyze apps/rc apps/bridge
```

For C++ bridge-only iteration:

```bash
./run-bridge.sh
```

`run-bridge.sh` starts the bridge from the terminal.
Terminal needs macOS Camera permission for preview capture. For end-user behavior, prefer the `.app` build.

| Path | Purpose |
| --- | --- |
| `apps/bridge_cpp/` | C++ bridge: OBSBOT `libdev`, Crow WebSocket and static HTTP, a BSD-socket MJPEG server. |
| `apps/bridge/` | Flutter macOS app that supervises the C++ subprocess. |
| `apps/rc/` | Flutter remote for Web, Android, and iOS. |
| `packages/` | Shared Dart packages: `obsbot_protocol`, `obsbot_api_client`, `auth_repository`, `bridge_repository`, `device_repository`. |
| `docs/PROTOCOL.md` | WebSocket API and pairing protocol. |
| `docs/ARCHITECTURE.md` | Runtime architecture and process boundaries. |
| `docs/RUN.md` | Manual test and troubleshooting guide. |

Persisted runtime files under `~/Library/Application Support/Open OBSBOT Bridge/`:

| File | Purpose |
| --- | --- |
| `auth.json` | Pairing PIN and issued tokens. |
| `active.json` | The camera OBS follows. |
| `device_names.json` | Per-camera friendly names. |
| `sequence.json` | Active single-camera sequence scratch. |
| `sequences.json` | Saved single-camera sequence library, keyed by serial number. |
| `mix.json` | Active mix-sequence scratch. |
| `mix_sequences.json` | Saved mix-sequence library. |

Logs are at `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Phone cannot connect | The phone and the bridge host must be on the same LAN. Check the bridge URL in the app. VPNs and guest Wi-Fi often block local devices. |
| Preview is blank | Confirm macOS Camera permission for Open OBSBOT Bridge. If the permission prompt was left unanswered on first launch, grant it and restart the bridge. |
| One camera shows no video | A sleeping OBSBOT emits no frames. Wake it from the camera bus, from Settings, or by putting it on air. |
| PTZ commands fail with `device_busy` | Quit OBSBOT Center or any other app controlling the camera, then restart the bridge. |
| Build cannot find the SDK | Run `./scripts/verify-sdk.sh` and fix the `third_party/obsbot-sdk/` layout. |
| Web remote looks stale | Use the cache-clear menu in the remote, or reload after restarting the bridge. |
| Camera is not detected | Try another USB cable or port and wait for the camera to finish booting. Cameras can take 6 to 20 seconds to enumerate. |

## Security

The bridge is built for trusted local networks.
Pairing uses a 6-digit PIN, then a 32-byte bearer token.
The MJPEG preview requires the token as `?t=<token>`.

Do not expose the bridge to the public internet.
See [SECURITY.md](SECURITY.md) for the threat model and current gaps.

## Camera compatibility

See [docs/CAMERAS.md](docs/CAMERAS.md).
The implementation is centered on the Tiny 2 Lite path.
Other OBSBOT models should work through the SDK, but each needs hardware validation before it is listed as supported.

## Roadmap

Items marked [Hark] are scoped for a development session.

### Camera sources beyond OBSBOT

- Add non-PTZ video sources (the built-in Mac camera, USB webcams, iPhone Continuity Camera) as program sources, so a mix can include a camera that only sends video. See `docs/CAMERA_SOURCES.md` when it lands.

### [Hark] Linux support

- Replace `video_capture.mm` (AVFoundation) with a V4L2 capture path.
- Wire `third_party/obsbot-sdk/linux/` into `CMakeLists.txt`.
- Add the Flutter Linux target and guard the macOS-only supervisor calls.

### [Hark] Windows support

- Replace `video_capture.mm` with a Windows Media Foundation capture path.
- Wire `third_party/obsbot-sdk/windows/win64-release/` into `CMakeLists.txt`.
- Add the Flutter Windows target and bundle `libdev.dll` next to the executable.

### Later

- Notarize the macOS release.
- Publish the phone apps to the app stores.
- Firmware updates without OBSBOT Center.
- An OBS virtual-camera output as an alternative to the Browser Source.

## License

| Component | License |
| --- | --- |
| Code in this repository | Apache 2.0. See [LICENSE](LICENSE). |
| OBSBOT SDK headers and samples | Not committed to git. Developers obtain their own copy from OBSBOT. |
| OBSBOT SDK runtime dylib | Bundled in macOS release artifacts so the app runs without a local SDK install. |

Check OBSBOT's SDK terms before publishing release assets that include `libdev.dylib`.

## Contributing

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).
