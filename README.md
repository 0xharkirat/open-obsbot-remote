# OBSBOT Control

An open-source phone & tablet remote for OBSBOT cameras.

Built for performers, presenters, and operators who need to control an OBSBOT camera (currently **Tiny 2 Lite**) from across the room — pan, tilt, zoom, recall presets, switch AI tracking — while their computer stays plugged in to the USB camera.

> **Status:** alpha. Working end-to-end PTZ + zoom + presets + AI mode + image controls. No live preview yet. Tiny 2 Lite is the only tested camera.

## How it works

```
┌────────────────────────┐    Wi-Fi (LAN)     ┌─────────────────────┐    USB     ┌────────────────┐
│  Phone (iOS/Android)   │  ◄──WebSocket──►   │  Mac (bridge app)   │  ◄────►    │ OBSBOT camera  │
│  Flutter UI            │   JSON messages    │  uses libdev SDK    │            │                │
└────────────────────────┘                    └─────────────────────┘            └────────────────┘
```

- **Phone app** (Flutter): the user-facing remote.
- **Bridge** (currently C++; migrating to Flutter+Pigeon+Swift): runs on the Mac, links the OBSBOT C++ SDK, exposes a JSON-over-WebSocket API on the local network.
- Both must be on the same Wi-Fi.

## Repo layout

```
.
├── apps/
│   ├── mobile/        Flutter phone app (iOS + Android), the actual product
│   ├── bridge_cpp/    C++ bridge — currently working, linked against libdev directly
│   └── bridge_mac/    [planned] Flutter macOS app replacing bridge_cpp; uses Pigeon → Swift → libdev
├── packages/
│   ├── obsbot_protocol/   [planned] shared Dart types for the WS protocol
│   └── obsbot_native/     [planned] Pigeon-generated FFI to libdev
├── docs/
│   ├── ARCHITECTURE.md          system design
│   ├── PROTOCOL.md              WebSocket message spec
│   ├── SDK_EXPLORATION.md       what libdev exposes, per camera
│   ├── GETTING_THE_SDK.md       how to obtain the SDK (see below)
│   └── RUN.md                   step-by-step usage
├── scripts/
│   └── verify-sdk.sh            checks SDK files are in place
├── third_party/
│   └── obsbot-sdk/              **NOT IN REPO — fetch separately, see below**
└── run-bridge.sh                one-shot launcher for the C++ bridge
```

## Getting the SDK

This project depends on **OBSBOT's C++ SDK**, which OBSBOT distributes by request and **cannot be redistributed**. You need to fetch your own copy before anything builds.

See [docs/GETTING_THE_SDK.md](docs/GETTING_THE_SDK.md). Short version: email `developer@obsbot.com`, drop the archive into `third_party/obsbot-sdk/`, run `./scripts/verify-sdk.sh`.

## Quick start (Tiny 2 Lite, macOS Apple Silicon, iPhone or Android)

```bash
# 1) one-time setup
brew install cmake asio
./scripts/verify-sdk.sh                   # confirms SDK is in place

# 2) plug in Tiny 2 Lite via USB; start the bridge
./run-bridge.sh
# → prints 'ws://<your-LAN-ip>:8765/v1' addresses

# 3) on your phone:
cd apps/mobile && flutter run -d <android-or-ios-device-id>
# In the app: type <your-LAN-ip>:8765, tap Connect.
```

Full walkthrough with troubleshooting: [docs/RUN.md](docs/RUN.md).

## Why does this exist?

OBSBOT's official Mac app is great for solo creators tuning a camera at a desk. It does **not** expose a remote control protocol — there's no way to drive the camera from a phone. This project fills that gap so the camera can be controlled from anywhere on the same Wi-Fi.

The author plays tabla on stage during worship services and streams them. He needs to pan to different parts of the stage / audience while playing — without leaving his seat.

## Roadmap

- [x] PTZ velocity + absolute angle from phone
- [x] Zoom set
- [x] Preset save / recall (4 slots)
- [x] AI tracking mode toggle
- [x] HDR / FOV / image color / face AE / face focus / flip
- [x] Sleep / wake
- [ ] Live preview on phone (UVC capture via AVFoundation → MJPEG over WS)
- [ ] Migrate bridge from C++ to Flutter macOS + Pigeon + Swift wrapping libdev
- [ ] Native macOS menu-bar UI (no Terminal)
- [ ] Auto-discovery via mDNS (currently manual IP entry)
- [ ] Notarized macOS DMG / iOS TestFlight / Play internal track
- [ ] Other OBSBOT cameras (Tiny 2, Tiny SE, Meet series, Tail Air...)
- [ ] Windows + Linux bridge

## License

[Apache 2.0](LICENSE) for everything in this repo. Note that **the OBSBOT SDK is licensed separately by OBSBOT** — building this project requires a copy of the SDK obtained directly from them.

## Contributing

Issues + PRs welcome. Please don't include any binaries from the SDK in commits or screenshots that contain code — `git status` should show `third_party/obsbot-sdk/` as ignored at all times.
