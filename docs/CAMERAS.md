# Camera support

Today this project is **only tested on the OBSBOT Tiny 2 Lite**. The bridge talks to OBSBOT's `libdev` SDK, which supports a much wider range of cameras  -  adding any of them is a matter of decoding the right `CameraStatus` struct and wiring the per-model UI quirks. No bottom-up rewrites needed for any model.

## Compatibility matrix

| Camera | Status struct | Hardware PTZ | Max digital zoom | Effort to add |
|---|---|---|---|---|
| **Tiny 2 Lite** | `tiny.*` | ✓ motorized | 2.0× | ✅ Done  -  only camera tested today |
| **Tiny 2** | `tiny.*` | ✓ motorized | 4.0× | **~half day**  -  same status struct as Tiny 2 Lite, just bump zoom range. AI sub-modes already wired. |
| **Tiny SE** | `tiny.*` | ✓ motorized | 4.0× | **~1 day**  -  adds zone-tracking commands; existing ai mode covers most. |
| **Tiny 4K** | `tiny.*` (FrmVer0) | image-crop only | 2.0× | **~1 day**  -  no real PTZ, slider drives image-crop pan/tilt. |
| **Tiny** (1st gen) | `tiny.*` (FrmVer0) | image-crop only | 2.0× | **~1 day**  -  same path as Tiny 4K. Older API quirks. |
| **Tiny 3 / Tiny 3 Lite** | `tiny.*` | ✓ motorized | 4.0× | **~1-2 days**  -  adds Speech-track AI mode + audio modes (`AudioModeType`). |
| **Meet** / **Meet 4K** | `meet.*` | digital pan/tilt only | 2.0× / 4.0× | **~3 days**  -  different status union branch + virtual-background commands + auto-framing UI. |
| **Meet 2 / Meet SE** | `meet.*` | digital pan/tilt only | 2.0× / 4.0× | **~3 days**  -  same plus gesture-zoom param block. |
| **Tail Air** | `tail_air.*` | ✓ motorized | 4.0× | **~1-2 weeks**  -  different AI track mode set, photo / video record / NDI / RTSP / SRT, BLE + Wi-Fi pairing flow, watermark, HDMI output config. Big surface. |
| **Tail 2 / Tail 2S** | `tail_air.*` (extended) | ✓ motorized | 20.0× | **~1-2 weeks**  -  same as Tail Air plus virtual-track + remo protocol v3 commands. |

Source for the matrix: `docs/SDK_EXPLORATION.md`. The numbers above are estimated effort assuming the developer has each camera in hand for testing.

## How to add a new camera (rough guide)

1. **Pick a camera and have it plugged in.** Without the hardware you cannot verify the libdev calls return what you expect.
2. **Grep `apps/bridge_cpp/src/device_session.cpp` for `ObsbotProdTiny2 || ObsbotProdTiny2Lite`**  -  those are the gates that branch on product type. Add your new product enum.
3. **Status decoding.** In `poll_status_locked()`, extend the `if (productType() == ...)` branch to read the right union member. For Meet series read `cs.meet.*`. For Tail Air read `cs.tail_air.*`.
4. **Zoom range.** In `on_dev_changed()`, set `snap_.zoom_max` per model.
5. **Camera-specific actions.** If your camera has features the protocol doesn't currently expose (e.g. Meet's virtual background, Tail Air's recording), add new actions in `protocol.cpp` + `device_session.{h,cpp}`. Document in `docs/PROTOCOL.md` first.
6. **UI.** In v1.2 the advanced-mode controls split across `apps/rc/lib/control_screen.dart` (the screen shell, AppBar actions like grid menu and Sequence) and `apps/rc/lib/tab_shell.dart` (the 3-tab body: Joystick, Buttons, Image). Add gating per-camera in the relevant section so, for example, virtual background only shows for Meet, or zone-tracking only shows for Tiny SE. Simple mode is in `apps/rc/lib/simple_mode_screen.dart`.
7. **Test on real hardware** for at least an hour  -  libdev's failure modes are weird and surface only over time.
8. **Update this file** with what you learned.

## What's already camera-agnostic

- WebSocket protocol shape (auth, state event, commands).
- Sequencer (uses preset IDs which every camera with PTZ supports).
- MJPEG preview pipeline (AVFoundation captures whatever the camera presents as a UVC video stream  -  works for every OBSBOT model).
- PIN auth.
- Web client.
- Build script.

So when someone with a Tail Air shows up, they don't need to invent an architecture  -  they need to add ~5 if/else branches and a bunch of UI pages.

## Things that won't work without manufacturer cooperation

- **iOS native build of the bridge.** The SDK ships only macOS / Linux / Windows binaries. No iOS slice. We'd need OBSBOT to compile an iOS-friendly libdev for an iPad-based bridge, or rewrite the camera control in-process via UVC commands (huge undertaking).
- **Firmware updates.** Currently only OBSBOT Center can do those  -  planned for a future phase of this project (libdev exposes the right hooks; just hasn't been wired yet).

## A note on testing

If you contribute a camera you don't actually own, please mark the PR as "untested on real hardware" in the description. We accept those PRs but flag them in the changelog so users know which cameras have been smoke-tested vs blind-coded.
