# Open OBSBOT Remote

Control multiple OBSBOT cameras from a phone, browser, or Mac on your local network.

A bridge app runs on the Mac your cameras are plugged into.
It drives each camera over USB and serves 3 things on your local network: the remote interface, a JSON control API, and an MJPEG preview.
No cloud service or account is involved.

The design turns OBS into a passive display.
OBS reads a single source that always shows whichever camera is on air.
Switching cameras, moving them, and running timed sequences all happen in the remote, so you never build per-camera scenes.

## Table of contents

- [Background](#background)
- [Install](#install)
- [Usage](#usage)
- [Features](#features)
- [Known limits](#known-limits)
- [Build from source](#build-from-source)
- [Security](#security)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## Background

The project ships 2 apps:

| App | Role |
| --- | --- |
| Open OBSBOT Bridge | macOS app. Drives every attached camera over USB, serves the control API on `ws://<mac>:8765/v1`, serves the web remote at `http://<mac>:8765/`, and serves MJPEG preview on `:8766`. |
| Open OBSBOT Remote | Flutter controller for Web, Android, iOS, and macOS. Switches cameras, drives pan, tilt, and zoom, recalls presets, edits image settings, and runs sequences. |

```text
Phone, browser, or Mac (Open OBSBOT Remote)
  |
  |  LAN, JSON over WebSocket, PIN-paired token
  v
Open OBSBOT Bridge on the Mac
  |  \
  |   \  MJPEG /preview/active.mjpg  -->  OBS Media Source (1 source)
  |
  |  USB via OBSBOT libdev SDK
  v
Cameras: OBSBOT over the SDK, plus any camera macOS can see
```

Switching rests on 2 ideas that stay separate:

- **Selection** is the camera the remote controls.
- **On air** is the camera OBS shows, which is the camera `/preview/active.mjpg` follows.

You select a camera to stage it, and frame it while it is off air.
Pressing **TAKE** then puts it on air, as a hard cut or a crossfade.
Because OBS follows `active.mjpg`, the bridge performs the switch and OBS needs no scene change.

[Architecture](docs/ARCHITECTURE.md) covers the runtime in depth.

## Install

```bash
brew install --cask 0xharkirat/tap/open-obsbot-bridge
```

DMG downloads are on the [latest release](https://github.com/0xharkirat/open-obsbot-remote/releases/latest) page.

[Install the bridge on macOS](docs/INSTALL.md) walks through the whole first run: Gatekeeper, camera and firewall permissions, pairing a controller, and configuring OBS.

### Requirements

- macOS 12 Monterey or later on the bridge host. The release DMG is universal, for Apple Silicon and Intel.
- 1 or more OBSBOT cameras on USB. The Tiny 2 Lite is the model validated on hardware.
- OBS, for streaming or recording. The remote works without it.

## Usage

Open the remote, pair once with the PIN from the bridge window, and the Live screen appears.
Select a camera to stage it, frame it, and press **TAKE** to put it on air.

In OBS, add a **Media Source**, clear **Local File**, and paste the OBS output URL copied from the bridge window:

```text
Input:          http://<mac-ip>:8766/preview/active.mjpg?t=<token>
Input Format:   mjpeg
Reconnect Delay: 2
FFmpeg Options: reconnect=1 reconnect_streamed=1 reconnect_delay_max=2
```

Use a Media Source rather than a Browser Source.
A Browser Source runs a full Chromium instance to decode the same stream, drops frames under load, and never reconnects when a stream ends.

## Features

**Multi-camera switching.** Every attached camera appears in the remote with its own status, name, and preview. TAKE commits the staged camera to air as a cut or a crossfade, and the crossfade length is yours to pick. OBS keeps reading 1 source.

**Any camera as a source.** Alongside OBSBOT cameras, add the Mac's built-in camera, a capture device, or a phone-camera app as a video source. Preview it, put it on air, and crossfade with the PTZ cameras. These sources carry no PTZ or preset controls, and they survive both restarts and unplugging.

**Live control.** Preview with optional grid overlays, a crosshair, and a live pan and tilt readout. Tap a direction to nudge, hold to glide at a ramped speed, or use an analog joystick with a squared response curve. Hold the zoom rocker for continuous zoom, or drag the slider. Each camera keeps 6 presets, recalled at a glide speed you choose.

**Mix sequencer.** A cross-camera timeline where you author shots, and the bridge derives the rest. A crossfade dissolves between 2 feeds, so consecutive cues must use different cameras. The bridge solves that assignment, and walks each idle camera to the shot it needs next. Disable a cue and the sequence relinks around it. Sequences run on the bridge, so they survive a disconnected phone, and they save without serial numbers, so they move between rigs.

**Image controls.** Auto-track modes, field of view, exposure mode with EV bias, anti-flicker, and white balance. Brightness, contrast, saturation, and sharpness sliders, plus toggles for HDR, face exposure, face focus, and horizontal flip.

**Desk layout.** On a Mac window, an iPad in landscape, or a desktop browser, the remote becomes a small vision mixer. Preview and program sit side by side over the camera bus, and every control moves into a rail instead of hiding behind a toggle.

**Bridge app.** A pairing card with a PIN and a QR code that encodes a 1-scan pairing link. A menu bar item that keeps the bridge running with the window closed. A row per camera, and a copyable OBS output URL.

## Known limits

- The Tiny 2 Lite is the only camera validated end to end. Other OBSBOT models should work through the same SDK.
- The bridge is macOS only. The SDK ships Windows and Linux binaries, but neither target is packaged yet.
- The bridge speaks `ws://` and `http://` with no TLS. Keep it on a trusted network, and never port-forward `8765` or `8766`.
- The macOS build is ad-hoc signed rather than notarized, so a DMG install needs the Gatekeeper steps.
- Firmware updates still need OBSBOT Center.

## Build from source

```bash
./scripts/verify-sdk.sh
./scripts/build-bridge-mac.sh
```

The build needs your own copy of the OBSBOT Camera SDK, which is not committed to git.
[Build from source](docs/BUILD.md) covers the toolchain, the SDK layout, remote builds for each platform, signing and notarizing a release, and the repository layout.

## Security

The bridge is built for trusted local networks.
Pairing uses a 6-digit PIN and then a 32-byte bearer token, and the MJPEG preview requires that token as `?t=<token>`.

Never expose the bridge to the public internet.
[SECURITY.md](SECURITY.md) documents the threat model and the current gaps.

## Roadmap

Planned work lives in the [GitHub issues](https://github.com/0xharkirat/open-obsbot-remote/issues), grouped under epics.
The open epics cover app store releases, Windows and Linux builds, a CoreMediaIO virtual camera, and convergence of the 2 desktop windows.

## Contributing

Questions and bug reports go to [GitHub issues](https://github.com/0xharkirat/open-obsbot-remote/issues).
Pull requests are welcome.
[Contributing](docs/CONTRIBUTING.md) covers the branch and review workflow, and [Run and test](docs/RUN.md) covers the manual test pass.

## License

Apache-2.0 (c) Harkirat Singh. See [LICENSE](LICENSE).

The OBSBOT SDK is not part of this repository.
Its headers and samples stay out of git, and each developer obtains their own copy.
macOS release artifacts bundle the SDK runtime library so the app runs without a local SDK install.
Check OBSBOT's SDK terms before publishing release assets that include `libdev.dylib`.
