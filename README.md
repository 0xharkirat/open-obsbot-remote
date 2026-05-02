# Open OBSBOT Control

A phone & tablet remote for OBSBOT cameras.

Built for performers, presenters, and operators who need to control an OBSBOT camera from across the room — pan, tilt, zoom, recall preset positions, run a timed preset sequence — while their computer stays plugged in to the USB camera. Works over local Wi-Fi, no cloud, no account.

> **Status:** feature-complete for Tiny 2 Lite. PIN auth, named saved sequences (loop / forward / ping-pong), simple mode for stage use, advanced mode for tuning, web + native clients, MJPEG live preview, auto-restart, single-instance enforcement.
>
> Replaces OBSBOT Center for daily use — only firmware updates still need their app (planned for a future release).
>
> macOS bundle ships ad-hoc-signed today; notarized DMG is the next step before wide release.

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
│   └── CAMERAS.md               compatibility matrix per OBSBOT model
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

## Install — for end users

> **Currently only macOS Apple Silicon is shipped.** Windows + Linux bridge builds are planned (the C++ + Flutter stack works on those platforms; we just haven't packaged it yet). If you're on Windows or Linux today, see "Build from source" below — it's the same project, different build target.

### Mac (.app bundle)

1. Download `Open OBSBOT Bridge.dmg` from the [Releases](https://github.com/0xharkirat/open-obsbot-remote/releases) page (coming once notarized).
2. Drag **Open OBSBOT Bridge.app** to `/Applications`.
3. Plug in your OBSBOT camera over USB.
4. Open the app. macOS will prompt for **Camera** + **Local Network** access — click Allow on both.
5. The bridge window shows status + a "Reveal" button. Click it to see your 6-digit pairing PIN and a QR code.
6. On your phone, scan the QR or open `http://<mac-ip>:8765/` in any browser. Type the PIN once. You're in.

### Phone

| | What | How |
|---|---|---|
| **Easiest** | Web (any phone, no install) | Open the bridge URL in Safari/Chrome → Add to Home Screen for fullscreen feel |
| **Android** | Native APK | Download from Releases, sideload (settings → install unknown apps) |
| **iOS** | Native (no App Store) | Sideload via Xcode (Free dev account works), or use the web app |

---

## Build from source — for developers + AI agents

If you want to build for a platform we don't have a release for yet (Windows, Linux), or you want to hack on the code, do this. Suitable for a human or for handing the repo to an AI coding agent.

### 1. Prerequisites

- macOS 13+ Apple Silicon (only macOS is supported as a build host today)
- [Flutter](https://flutter.dev/) 3.27+
- Xcode 15+ with Command Line Tools (`xcode-select --install`)
- Homebrew

```bash
brew install cmake asio
```

### 2. Get the OBSBOT SDK

The project depends on OBSBOT's C++ SDK (`libdev`). It ships out-of-band, not in this repo, because OBSBOT distributes it directly.

1. Go to **<https://www.obsbot.com/sdk>**.
2. Fill in the simple form requesting the **Camera SDK**. (Mention you're building a third-party controller; they typically reply within minutes.)
3. Download the archive they email you. Unzip.
4. Rename the extracted folder to **`obsbot-sdk`** and copy it into the repo:

```bash
# After cloning, drop the SDK in:
mv ~/Downloads/Camera_SDK_v1.3.0  third_party/obsbot-sdk
# Final layout must look like:
#   third_party/obsbot-sdk/include/dev/dev.hpp
#   third_party/obsbot-sdk/macos/arm64-release/libdev.dylib
#   ... etc

./scripts/verify-sdk.sh   # exits 0 if everything is in the right place
```

If you skip this step, the build aborts with a clear error pointing back here. See [docs/GETTING_THE_SDK.md](docs/GETTING_THE_SDK.md) for details.

### 3. Build

```bash
git clone https://github.com/0xharkirat/open-obsbot-remote
cd open-obsbot-remote
# (drop the SDK as above)
./scripts/build-bridge-mac.sh
```

This single script:
1. Builds the C++ subprocess (`apps/bridge_cpp/`) with CMake.
2. Builds the Flutter web bundle (`apps/rc/`).
3. Builds the Flutter macOS .app (`apps/bridge/`).
4. Bundles libdev.dylib + the obsbot-bridge subprocess + the web build into the .app.
5. Ad-hoc signs the bundle.

Output:
```
apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app
```

### 4. Launch + use

```bash
open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
```

Same install steps as the bundle path: allow camera + local network, click Reveal, type PIN on phone. Full walkthrough in [docs/RUN.md](docs/RUN.md).

### 5. Build the phone apps separately (optional)

```bash
cd apps/rc
flutter build apk --release   # Android APK
flutter build ios --release   # iOS (requires Apple Developer account)
flutter build web --release   # Web — usually you let build-bridge-mac.sh do this
```

### Doing this with an AI coding agent

The repo is shaped for AI-assisted development. Any agent (Claude Code, Cursor, etc.) auto-loads [CLAUDE.md](CLAUDE.md) / [AGENTS.md](AGENTS.md) which contains:
- Repo layout, conventions
- 20+ specific gotchas hit during development
- Build + run commands

Just point the agent at the repo, tell it your goal, and it'll have enough context to be productive. The SDK acquisition step is the only manual gate.

## Why does this exist?

OBSBOT's official Mac app (OBSBOT Center) is great for tuning a camera at a desk. It does **not** expose a remote control protocol — there's no way to drive the camera from a phone. This project fills that gap so the camera can be controlled from anywhere on the same Wi-Fi.

The author plays tabla on stage during worship services and streams them. He needs to pan to different parts of the stage / audience while playing — without leaving his seat. The Sequencer with ping-pong loop was added so the camera can cycle through "wide stage → soloist → audience → soloist → wide" automatically.

## Do I need OBSBOT Center?

**No.** Open OBSBOT Bridge does everything OBSBOT Center does for daily use:
- First-time setup (just plug in via USB; the bridge handles initialization)
- Pan / tilt / zoom
- Preset save + recall
- AI tracking modes
- HDR / FOV / image color tuning
- Sleep / wake

The **only** thing it can't do today is **firmware updates** — those require OBSBOT Center. We plan to add firmware-update support in a future phase.

If you have OBSBOT Center installed already, that's fine — but **quit it before launching Open OBSBOT Bridge**, otherwise the two apps will fight over the camera's control endpoint and PTZ commands will fail with `device_busy`.

## License

| Component | License |
|---|---|
| Our code (apps/, packages/, docs/, scripts/) | Apache 2.0 — see [LICENSE](LICENSE) |
| OBSBOT C++ SDK (`libdev.dylib` + headers) | **Not redistributed.** Belongs to OBSBOT. We link against it; you obtain your own copy. |

Distributing a DMG that bundles `libdev.dylib` requires explicit written permission from OBSBOT. See [docs/GETTING_THE_SDK.md](docs/GETTING_THE_SDK.md) for the email draft and what we're asking them.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports + feature ideas welcome via GitHub issues.

## Author + Credits

- Built by [Harkirat Singh](https://github.com/0xharkirat) with [Claude Code](https://claude.com/claude-code).
- Tested on: MacBook Pro M5 (macOS 26.x arm64), OBSBOT Tiny 2 Lite (firmware 6.2.6.5), Moto g56 5G (Android 15), iPhone 17 Pro.
- OBSBOT C++ SDK provided by [OBSBOT](https://www.obsbot.com/) under their developer terms.
