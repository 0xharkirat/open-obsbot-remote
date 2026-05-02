# CLAUDE.md — guidance for future Claude Code sessions in this repo

This file is auto-loaded into every Claude Code session. Read it before doing anything substantive.

## What this project is

Phone-based remote for OBSBOT cameras (currently Tiny 2 Lite). Performer / streamer has the camera + Mac on stage, and uses an Android or iOS app to pan/tilt/zoom/recall presets/toggle AI from across the room.

Two products:

- **Open OBSBOT Bridge** — macOS .app the user installs once. Wraps the C++ bridge subprocess that talks to the camera over USB via OBSBOT's libdev SDK + serves a JSON-over-WebSocket control API + an MJPEG preview stream on the LAN.
- **Open OBSBOT Remote** — Flutter mobile app (Android + iOS) the performer uses on their phone.

The repo is **private** while we build a working demo. SDK is gitignored (`third_party/obsbot-sdk/`); see `docs/GETTING_THE_SDK.md`.

## Repo layout

```
.
├── apps/
│   ├── rc/            "Open OBSBOT Remote" — Flutter app for the controller surface.
│   │                   Targets iOS + Android + Web (served by the bridge). Bundle IDs:
│   │                   com.harksingh.obsbotcontrol (iOS), com.harksingh.obsbot_control (Android).
│   │                   Internal pubspec name still `obsbot_control` — don't rename, breaks imports.
│   ├── bridge_cpp/    C++ WS+HTTP+MJPEG bridge — links libdev + AVFoundation. Single
│   │                   binary `obsbot-bridge`. Wrapped by apps/bridge/ as a subprocess.
│   └── bridge/        "Open OBSBOT Bridge" — Flutter desktop app wrapping bridge_cpp.
│                       Currently macOS only. Will grow Windows/Linux targets later.
│                       Internal pubspec name still `obsbot_bridge_mac` — leave it.
│                       Bundle ID: com.harksingh.obsbotbridge.
├── packages/          (planned) shared Dart pkgs — empty stubs.
├── docs/              ARCHITECTURE.md, PROTOCOL.md, SDK_EXPLORATION.md, GETTING_THE_SDK.md, RUN.md
├── scripts/
│   ├── build-bridge-mac.sh    builds bridge_cpp → flutter build web (rc) → flutter build
│   │                          macos (bridge) → bundles libdev + web build → ad-hoc sign.
│   └── verify-sdk.sh
├── third_party/obsbot-sdk/    GITIGNORED. SDK 1.3.0 from OBSBOT (received by email).
└── run-bridge.sh              dev shortcut: runs the C++ bridge from Terminal (no .app wrapper).
```

## Architecture in one sentence

Phone (Flutter) → WebSocket (port 8765, JSON) → Bridge (C++ inside Mac .app) → libdev USB → Camera. Live preview is HTTP MJPEG on port 8766.

See `docs/ARCHITECTURE.md` and `docs/PROTOCOL.md` for the full spec.

## Build & run

```bash
# every time you change C++ or Flutter macOS code
./scripts/build-bridge-mac.sh

# launch the Mac app
open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"

# launch the phone app (needs ANDROID_DEVICE_ID from `adb devices` or `flutter devices`)
cd apps/rc && flutter run -d <device-id>
```

For dev iteration on the C++ bridge alone (no Flutter wrapper), `./run-bridge.sh` runs it from Terminal — but Terminal needs camera permission for that to work.

## Things that bit us, don't repeat

1. **Crow's `response.write()` does not flush mid-handler.** It buffers the whole response until the handler returns. That makes multipart/x-mixed-replace impossible through Crow. We solved it with a hand-rolled BSD-socket server in `apps/bridge_cpp/src/mjpeg_server.cpp` listening on port+1.
2. **Unsigned subprocess + macOS TCC.** The bundled `obsbot-bridge` subprocess won't inherit camera-access grants from the parent .app unless the whole bundle is code-signed. We ad-hoc sign in `build-bridge-mac.sh` (`codesign --force --deep --sign -`). Without that, preview silently fails after the user clicks Allow.
3. **Bundle-ID changes break TCC.** Every time we change `PRODUCT_BUNDLE_IDENTIFIER`, macOS treats it as a new app and the camera/local-network prompt fires again. Don't rename bundle IDs casually.
4. **Sandbox must be OFF.** App sandbox blocks raw USB and binding TCP listeners. We ship via Developer ID, not Mac App Store, so this is fine. Both `Debug.entitlements` and `Release.entitlements` set `com.apple.security.app-sandbox` to false.
5. **Android cleartext traffic.** Bridge runs on `ws://` and `http://` over LAN, so the Android manifest needs `android:usesCleartextTraffic="true"`. iOS needs `NSAppTransportSecurity → NSAllowsLocalNetworking`. macOS clients need `com.apple.security.network.client`.
6. **`flutter create --platforms=...`** — it ONLY adds the platforms listed. The user needs Android + iOS + macOS (probably more later). Always re-run with all platforms when scaffolding.
7. **`MainActivity.kt` package must match `namespace` in `build.gradle.kts`** — moving Android `applicationId` is fine on its own, but if you change the `namespace` you must move the kotlin source under the matching `android/app/src/main/kotlin/<package-path>/`.
8. **`CameraStatus` from libdev is a tagged union by `productType()`.** Read `cs.tiny.*` only if `productType() == ObsbotProdTiny2 || ObsbotProdTiny2Lite`. Mis-cast = junk.
9. **AI tracking owns the gimbal.** Before sending a manual gimbal command, call `cameraSetAiModeU(AiWorkModeNone)` + `aiSetEnabledR(false)`. We do this in `device_session.cpp` already.
10. **HDR + media-mode switches** need a 3-second debounce per the SDK comments. We enforce this in the bridge.
11. **`flutter run` hot-reload doesn't always re-evaluate Dart logic in `build()`** — when changing widget logic, prefer hot RESTART (capital R).

## Conventions

- WS port 8765, MJPEG port 8766 (always WS-port + 1). Both are configurable but everywhere assumes the +1 relationship.
- Logs persist at `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.
- Caveman / terse responses by default — user prefers brevity.
- macOS app is *not* sandboxed and *not* notarized yet. Distribution is dev-only. Notarization is a future task.

## Camera permission flow

1. User double-clicks `Open OBSBOT Bridge.app`.
2. macOS reads `Info.plist`'s `NSCameraUsageDescription` + `NSLocalNetworkUsageDescription` and prompts.
3. User clicks Allow → entry added to System Settings → Privacy & Security → Camera as "Open OBSBOT Bridge".
4. The .app supervises the bridge subprocess. Because the whole bundle is ad-hoc signed, the subprocess inherits the parent's TCC grant and AVCaptureSession just works.
5. Bridge log line confirms: `video: capture session started`. UI flips status to "Granted".

If denied: UI shows a "Reset & retry" button that runs `tccutil reset Camera com.harksingh.obsbotbridge` and restarts the subprocess to retrigger the prompt.

## What's known to work (as of 2026-05-01)

- USB camera detection via libdev (Tiny 2 Lite, fw 6.2.6.5)
- PTZ velocity + absolute angle, gimbal recenter
- Zoom set
- Preset save / recall / delete (4 slots in mobile UI)
- AI mode toggle (Human / None)
- HDR / FOV / brightness / contrast / saturation / sharpness / face AE / face focus / flip
- Sleep / wake
- Live preview at ~12 fps, ~56 KB/frame, ~5 Mbps (downscaled to 960px max long-side, JPEG q=0.40)
- macOS .app + bundled bridge subprocess + libdev
- Phone connects over LAN; tested with Moto g56 5G

## What's pending

- WebRTC preview (alongside MJPEG, not replacing)
- Preset-first mobile UI redesign (preview big, preset buttons big, advanced sliders behind a sheet)
- Pigeon → Swift rewrite of bridge_cpp into bridge_mac (single-process .app, no subprocess)
- mDNS auto-discovery (currently manual IP entry)
- Notarized DMG + iOS TestFlight + Play internal track
- Other OBSBOT cameras (Tiny 2, Tiny SE, Meet, Tail Air...)
- OBSBOT licensing email — see `docs/GETTING_THE_SDK.md`

## Coexistence with the official OBSBOT Center app

- **Video preview:** macOS supports multiple AVCaptureSession consumers per camera, so our preview and the official app can both stream simultaneously without fighting.
- **Camera control (PTZ / zoom / AI mode):** libdev claims a UVC extension unit + HID control endpoint. These are typically *exclusive* — only one app can issue control commands at a time. If the official OBSBOT Center app is open and connected, our bridge will likely see `device_busy` errors when sending commands.
- **Firmware updates:** only the official app can do those. Use it for first-time setup, then quit it before launching Open OBSBOT Bridge.
- **In practice:** treat the two apps as mutually exclusive for daily use. Bridge log will print "device unplugged" or busy errors if the user has both running.

## Future-Claude operating tips

- The user is `0xharkirat` on GitHub, builds on a MacBook Pro M5 (macOS 26.x arm64), tests on a Moto g56 5G (Android 15) and an iPhone 17 Pro.
- `gh repo create` and `git push` to GitHub require a permission prompt — they're sometimes blocked in non-interactive automation. If so, hand the exact command back to the user.
- The user accepts terse caveman-style responses but switches to clearer prose for security/legal/permission topics. Match accordingly.
- Don't rewrite working code unless asked. Add features behind toggles, keep the demo path intact.
- Don't try to commit the SDK (`third_party/obsbot-sdk/`). It's gitignored on purpose.
