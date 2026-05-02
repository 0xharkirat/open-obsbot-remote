# Open OBSBOT Control

A phone & tablet remote for OBSBOT cameras.

Built for performers, presenters, and operators who need to control an OBSBOT camera from across the room — pan, tilt, zoom, recall preset positions, run a timed preset sequence — while their computer stays plugged in to the USB camera. Works over local Wi-Fi, no cloud, no account.

> **Status:** private alpha — working end-to-end on a Tiny 2 Lite.
> Phase A complete (auth, sequencer, simple mode, web client). Aiming for public release after notarization + OBSBOT licensing.

---

## What's in the box

| | |
|---|---|
| **Open OBSBOT Bridge** | A `.app` you install on your Mac. Runs the camera over USB, exposes a JSON-over-WebSocket control API + an HTTP MJPEG preview on your local Wi-Fi, and serves the web UI from the same address. |
| **Open OBSBOT Remote** | Phone controller. Available as native APK / iOS native / **and as a web page served by the bridge** (no install needed — Safari, Chrome, anything). |

```
┌──────────────────────┐    Wi-Fi      ┌─────────────────────┐    USB    ┌────────────────┐
│  Phone (RC)          │  ←WebSocket→  │  Mac (Bridge)       │  ←─────→  │ OBSBOT Tiny 2  │
│  iOS / Android / Web │   JSON + PIN  │  libdev + AVFound.  │           │      Lite      │
└──────────────────────┘     auth      └─────────────────────┘           └────────────────┘
        ↓ <img src=...>
   HTTP MJPEG preview ──────────────────────────┘
```

## What works today

- ✅ Live MJPEG preview (~20 fps, ~5 Mbps over LAN)
- ✅ PTZ: drag joystick (velocity) + absolute angle + recenter
- ✅ Zoom: 1.0× – 2.0× on Tiny 2 Lite (queried from camera; up to 4.0× on bigger models)
- ✅ Up to 6 named presets, saved on the camera firmware (survive unplug)
- ✅ Active-preset highlight in UI
- ✅ AI tracking modes (Human / None / Group / Hand / Whiteboard / Desk)
- ✅ HDR / FOV / brightness / contrast / saturation / sharpness / face AE / face focus / flip
- ✅ Sleep / wake
- ✅ **Sequencer** — define `{preset, seconds, speed}` steps; runs on the bridge so it survives phone disconnect.
  - **Once** — play through, stop
  - **Forward loop** — `P1→P2→P3→P1→P2→P3…`
  - **Ping-pong** — `P1→P2→P3→P2→P1→P2→P3…` (skips long P3→P1 jump)
- ✅ **Move-speed presets** — Instant / Slow / Medium / Fast for preset transitions (uses `gimbalSetSpeedPositionR` for cinematic moves)
- ✅ **PIN-paired auth** — 6-digit PIN shown in bridge UI; phone enters once, gets a long-lived token. Token gates WS messages + MJPEG (`?t=`).
- ✅ **Simple mode** — preview-big + preset grid only. For on-stage use.
- ✅ **Advanced mode** — full PTZ pad / sliders / image controls.
- ✅ **Web client** — phone → `http://<mac>:8765/` → live remote, no install.
- ✅ **QR code on bridge** + URL printed beneath.
- ✅ **Cache-clear** menu in phone apps for stale-build escape.
- ✅ Bridge **auto-restarts** on subprocess crash (5 attempts, quadratic backoff).
- ✅ Bridge **single-instance** enforced.
- ✅ SIGPIPE-safe — phone disconnect / reload doesn't kill the bridge.
- ✅ Logs persisted at `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.

## What's pending

- iPhone TestFlight + Play Store listings (today: APK sideload + web)
- Notarized DMG (today: ad-hoc signed dev build)
- mDNS auto-discovery (today: type LAN IP / scan QR)
- WebRTC preview alongside MJPEG (lower latency, hardware H.264)
- Foreground service on Android APK (keep WS alive when phone backgrounds)
- Other OBSBOT cameras (Tail Air, Tiny SE, Meet series, …)
- Pigeon → Swift → libdev rewrite of the bridge (single-process .app)

See [docs/ROADMAP.md](docs/ROADMAP.md) for the path to public release.

---

## Repo layout

```
.
├── apps/
│   ├── rc/            "Open OBSBOT Remote" — Flutter app, controller surface.
│   │                   Targets: iOS, Android, Web.
│   ├── bridge_cpp/    C++ WS+HTTP+MJPEG bridge talking to libdev.
│   │                   Single binary `obsbot-bridge`.
│   └── bridge/        "Open OBSBOT Bridge" — Flutter desktop app wrapping
│                       bridge_cpp as a managed subprocess.
│                       Currently macOS only; Windows + Linux planned.
├── packages/                    (planned) shared Dart packages — empty stubs.
├── docs/
│   ├── ARCHITECTURE.md          system design + threading
│   ├── PROTOCOL.md              WebSocket message spec
│   ├── SDK_EXPLORATION.md       libdev surface, per-camera matrix
│   ├── GETTING_THE_SDK.md       how to obtain the SDK
│   ├── RUN.md                   step-by-step usage
│   └── ROADMAP.md               path to public release
├── scripts/
│   ├── build-bridge-mac.sh      builds C++ → builds rc web → builds bridge .app
│   └── verify-sdk.sh            checks SDK files are in place
├── third_party/
│   └── obsbot-sdk/              gitignored — kept on local disk only
├── CHANGELOG.md
├── CLAUDE.md / AGENTS.md        AI coding-tool guidance (auto-loaded by Claude Code)
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
└── LICENSE                      Apache 2.0 (our code; SDK is licensed separately)
```

## SDK setup

The OBSBOT C++ SDK lives only on your local disk at `third_party/obsbot-sdk/`. It is **not** in git and is **not** something the end user sees. The build pulls `libdev.dylib` from there and bundles it inside the resulting `.app`, so the shipped DMG is a single self-contained installer.

If you're a new dev on this repo, see [docs/GETTING_THE_SDK.md](docs/GETTING_THE_SDK.md) for how to obtain a copy from OBSBOT and where to drop it.

## Quick start (Tiny 2 Lite, macOS Apple Silicon, any phone)

```bash
# 1) one-time setup
brew install cmake asio
./scripts/verify-sdk.sh                # confirms you have the local SDK

# 2) build + launch the bridge
./scripts/build-bridge-mac.sh
open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
# - First launch prompts for camera + local-network access — click Allow.
# - Click "Reveal" in the bridge window to see the 6-digit PIN + QR.

# 3) on your phone — pick one:
#    a) Web (no install): scan the QR or open http://<mac-ip>:8765/
#    b) Native APK: cd apps/rc && flutter build apk && adb install build/app/outputs/flutter-apk/app-release.apk
#    c) iOS sideload: cd apps/rc && flutter run -d <iphone-id>

# 4) On the phone, enter the 6-digit PIN. You're in.
```

Full walkthrough with troubleshooting: [docs/RUN.md](docs/RUN.md).

## Why does this exist?

OBSBOT's official Mac app (OBSBOT Center) is great for tuning a camera at a desk. It does **not** expose a remote control protocol — there's no way to drive the camera from a phone. This project fills that gap so the camera can be controlled from anywhere on the same Wi-Fi.

The author plays tabla on stage during worship services and streams them. He needs to pan to different parts of the stage / audience while playing — without leaving his seat. The Sequencer with ping-pong loop was added so the camera can cycle through "wide stage → soloist → audience → soloist → wide" automatically.

## Coexistence with OBSBOT Center

The two apps mostly do different things and **can run simultaneously for video preview**, but they fight over camera control (PTZ / zoom / AI). Treat them as mutually exclusive for daily use. Quit OBSBOT Center before starting Open OBSBOT Bridge if you want PTZ to work.

Use OBSBOT Center for first-time setup + firmware updates (only it can do those).

## License

| Component | License |
|---|---|
| Our code (apps/, packages/, docs/, scripts/) | Apache 2.0 — see [LICENSE](LICENSE) |
| OBSBOT C++ SDK (`libdev.dylib` + headers) | **Not redistributed.** Belongs to OBSBOT. We link against it; you obtain your own copy. |

Distributing a DMG that bundles `libdev.dylib` requires explicit written permission from OBSBOT. See [docs/GETTING_THE_SDK.md](docs/GETTING_THE_SDK.md) for the email draft and what we're asking them.

## Contributing

Repo is private during the demo phase. After we get OBSBOT's licensing answer the repo will go public — see [docs/ROADMAP.md](docs/ROADMAP.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

Bug reports and feature ideas welcome via GitHub issues once public.

## Author + Credits

- Built by [Harkirat Singh](https://github.com/0xharkirat) with [Claude Code](https://claude.com/claude-code).
- Tested on: MacBook Pro M5 (macOS 26.x arm64), OBSBOT Tiny 2 Lite (firmware 6.2.6.5), Moto g56 5G (Android 15), iPhone 17 Pro.
- OBSBOT C++ SDK provided by [OBSBOT](https://www.obsbot.com/) under their developer terms.
