# CLAUDE.md — guidance for future Claude Code sessions in this repo

This file is auto-loaded into every Claude Code session. Read it before doing anything substantive.
A duplicate copy lives at `AGENTS.md` for non-Claude AI tools that follow that convention.

## What this project is

Phone-based remote for OBSBOT cameras (Tiny 2 Lite is the only camera tested). The performer / streamer has the camera + Mac on stage, and uses an Android, iOS, or **web browser** on their phone to pan/tilt/zoom/recall presets/run a timed sequence — all from across the room.

Two products:

- **Open OBSBOT Bridge** — macOS `.app` the user installs once. Wraps the C++ subprocess (`obsbot-bridge`) that talks to the camera over USB via OBSBOT's libdev SDK. Serves a JSON-over-WebSocket control API on `:8765`, an HTTP MJPEG preview on `:8766`, and the Flutter web build of the remote at `http://<mac>:8765/`.
- **Open OBSBOT Remote** — Flutter app for the phone (iOS + Android + Web). Web build is bundled inside the Bridge .app and served directly, so users don't need an app-store install.

## Repo layout

```
.
├── apps/
│   ├── rc/            "Open OBSBOT Remote" — Flutter app for the controller surface.
│   │                   Targets iOS + Android + Web. Bundle IDs:
│   │                   com.harksingh.obsbotcontrol (iOS), com.harksingh.obsbot_control (Android).
│   │                   Internal pubspec name still `obsbot_control` — don't rename, breaks imports.
│   ├── bridge_cpp/    C++ WS+HTTP+MJPEG bridge — links libdev + AVFoundation. Single
│   │                   binary `obsbot-bridge`. Wrapped by apps/bridge/ as a subprocess.
│   └── bridge/        "Open OBSBOT Bridge" — Flutter desktop app wrapping bridge_cpp.
│                       Currently macOS only. Windows + Linux planned in same project.
│                       Internal pubspec name still `obsbot_bridge_mac` — leave it.
│                       Bundle ID: com.harksingh.obsbotbridge.
├── packages/                    (planned) shared Dart pkgs — empty stubs.
├── docs/                        ARCHITECTURE, PROTOCOL, SDK_EXPLORATION, GETTING_THE_SDK,
│                                RUN, CAMERAS.
├── scripts/
│   ├── build-bridge-mac.sh      builds bridge_cpp → flutter build web (rc) → flutter build
│   │                            macos (bridge) → bundles libdev + web → ad-hoc signs.
│   └── verify-sdk.sh
├── third_party/obsbot-sdk/      GITIGNORED. SDK 1.3.0 from OBSBOT (received by email).
└── run-bridge.sh                dev shortcut: runs the C++ bridge from Terminal (no .app wrapper).
```

## Architecture in one sentence

Phone (Flutter, native or web) → WebSocket on `:8765/v1` (JSON, PIN-token-gated) → C++ subprocess inside the Mac .app → libdev USB → camera. Live preview is HTTP MJPEG on `:8766` (port = ws_port + 1) gated by `?t=<token>`. The Flutter web build of the phone app is served from `http://<mac>:8765/`.

See `docs/ARCHITECTURE.md` and `docs/PROTOCOL.md`.

## Build & run

```bash
# every time you change C++, web, or Flutter macOS code
./scripts/build-bridge-mac.sh

# launch the Mac app
open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"

# launch the phone app
cd apps/rc && flutter run -d <device-id>          # native APK / iOS
# OR phone browser → http://<mac-ip>:8765/         # web, served by bridge
```

For dev iteration on the C++ bridge alone (no Flutter wrapper), `./run-bridge.sh` runs it from Terminal — but Terminal needs camera permission for that to work.

## Things that bit us, don't repeat

1. **Crow's `response.write()` does not flush mid-handler.** It buffers the whole response until the handler returns. Multipart/x-mixed-replace is impossible through Crow. We solved it with a hand-rolled BSD-socket server in `apps/bridge_cpp/src/mjpeg_server.cpp` listening on port+1.
2. **Unsigned subprocess + macOS TCC.** The bundled `obsbot-bridge` won't inherit camera-access grants from the parent .app unless the whole bundle is code-signed. We ad-hoc sign in `build-bridge-mac.sh` (`codesign --force --deep --sign -`). Without that, preview silently fails.
3. **Bundle-ID changes break TCC.** Every time we rename `PRODUCT_BUNDLE_IDENTIFIER`, macOS treats it as a new app and the camera/local-network prompts re-fire. Don't rename casually.
4. **Sandbox must be OFF.** App Sandbox blocks raw USB and binding TCP listeners. We ship via Developer ID (eventually), not Mac App Store, so `com.apple.security.app-sandbox = false` in both entitlements files is fine.
5. **Android cleartext traffic.** Bridge runs on `ws://` and `http://` over LAN. Android needs `android:usesCleartextTraffic="true"`. iOS needs `NSAppTransportSecurity → NSAllowsLocalNetworking`. macOS clients need `com.apple.security.network.client`.
6. **Tiny 2 Lite digital-zoom max is 2.0×, not 4.0×.** The slider's `zoomMax` came back as `4.0` from a default; out-of-range commands silently clamped, looking broken. Bridge now picks `2.0` for Tiny 2 Lite via product type and snaps `snap_.zoom` immediately on set so phone UI feels instant instead of waiting for the 500ms poll.
7. **Use `cameraSetZoomWithSpeedAbsoluteR`, not `cameraSetZoomAbsoluteR`** — the vendor sample uses the former; the latter sometimes silently fails.
8. **`cameraSetAiModeU(AiWorkModeNone)` before any manual gimbal command.** AI tracking owns the gimbal otherwise. `device_session.cpp::cmd_ptz_*` already does this.
9. **HDR + media-mode switches** need a 3-second debounce per the SDK comments. Bridge enforces this.
10. **`flutter run` hot-reload doesn't always re-evaluate Dart logic in `build()`** — when changing widget logic, prefer hot RESTART (capital R).
11. **`MainActivity.kt` package must match `namespace` in `build.gradle.kts`** — moving `applicationId` is fine, but if you change `namespace` you must move the kotlin source under the matching directory.
12. **`CameraStatus` from libdev is a tagged union by `productType()`.** Read `cs.tiny.*` only if `productType() == ObsbotProdTiny2 || ObsbotProdTiny2Lite`. Mis-cast = junk.
13. **SIGPIPE kills the bridge on phone disconnect** unless you `signal(SIGPIPE, SIG_IGN)` at startup. Browsers / phones drop sockets uncleanly all the time.
14. **libdev's `DevicesPrivate::~DevicesPrivate()` throws on shutdown** → `std::terminate`. Use `_Exit(0)` from signal handler to skip global destructors.
15. **Stable `TextEditingController` per row** — recreating a controller every parent rebuild kills cursor + focus. Was the bug behind "can't type seconds in sequencer". Each `_EditStep` now owns its controller.
16. **`WebSocketChannel.stream` is a single-subscription stream.** Don't cancel + re-listen — messages arriving in between are lost. The pair() flow uses a single subscription + a Completer matched by id.
17. **flutter_mjpeg doesn't work on Flutter web.** `Image.network` doesn't decode multipart streams either. Use `HtmlElementView` + a real `<img>` element. Conditional import via `dart.library.js_interop`.
18. **Crow returns 404 for paths > 3 segments** (we now have 4-segment routes for nested Flutter web assets). Add more if needed.
19. **OBSBOT Center is NOT required** for first-time setup or daily use — our bridge does everything except firmware updates. But if both are running at once, they fight over the camera control endpoint; PTZ commands return `device_busy`. Quit OBSBOT Center before launching our bridge.
20. **AppDelegate single-instance** is needed because ad-hoc-signed dev builds occasionally slip through `LSMultipleInstancesProhibited`. Self-quit if a sibling exists.

## Conventions

- WS port 8765, MJPEG port 8766 (always WS-port + 1). Both configurable but everywhere assumes the +1 relationship.
- Logs persist at `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.
- Auth state at `~/Library/Application Support/Open OBSBOT Bridge/auth.json` (PIN + tokens).
- Sequence persists at `~/Library/Application Support/Open OBSBOT Bridge/sequence.json`.
- Caveman / terse responses preferred — user explicitly likes brevity. Switch to clearer prose for security/legal/permission topics.
- macOS app is *not* sandboxed and *not* notarized yet. Distribution is dev-only.

## Camera permission flow

1. User double-clicks `Open OBSBOT Bridge.app`.
2. macOS reads `Info.plist`'s `NSCameraUsageDescription` + `NSLocalNetworkUsageDescription` and prompts.
3. User clicks Allow → entry added to System Settings → Privacy & Security → Camera as "Open OBSBOT Bridge".
4. The .app supervises the bridge subprocess. Because the whole bundle is ad-hoc signed, the subprocess inherits the parent's TCC grant and AVCaptureSession just works.
5. Bridge log line confirms: `video: capture session started`. UI flips status to "Granted".

If denied: UI shows a "Reset & retry" button that runs `tccutil reset Camera com.harksingh.obsbotbridge` and restarts the subprocess to retrigger the prompt.

## PIN-paired auth flow

1. Bridge generates a random 6-digit PIN on first launch (or after "Reset pairing"). Stored at `~/Library/Application Support/Open OBSBOT Bridge/auth.json` along with issued tokens.
2. Bridge UI hides PIN+QR by default. User clicks "Reveal" → shows for 60s, auto-hides.
3. Phone connects to WS, sends `{"action":"hello","token":<saved>}` if it has one. If token missing or invalid, server replies `auth_required` and phone shows pair screen.
4. Phone sends `{"action":"pair","pin":"123456"}`. Bridge replies with `{"ok":true,"token":"<32-byte-hex>"}` on match. Phone saves token.
5. Subsequent WS messages and MJPEG GETs carry the token. MJPEG uses `?t=<token>` query param.
6. Bridge UI shows "N paired" count. "Reset pairing" deletes auth.json + restarts subprocess.

## What's known to work

See README.md "What works today" section. Tiny 2 Lite is feature-complete for daily use — replaces OBSBOT Center for everything except firmware updates.

## Future-Claude operating tips

- The user is `0xharkirat` on GitHub, builds on a MacBook Pro M5 (macOS 26.x arm64), tests on a Moto g56 5G (Android 15) and an iPhone 17 Pro.
- `gh repo create` and `git push` to GitHub require a permission prompt — they're sometimes blocked in non-interactive automation. If so, hand the exact command back to the user.
- The user accepts terse caveman-style responses but switches to clearer prose for security/legal/permission topics. Match accordingly.
- Don't rewrite working code unless asked. Add features behind toggles, keep the demo path intact.
- Don't try to commit the SDK (`third_party/obsbot-sdk/`). It's gitignored on purpose.
- When re-launching the Mac app after a rebuild, kill the old subprocess first: `pkill -9 -f obsbot-bridge` and `osascript -e 'quit app "Open OBSBOT Bridge"'`. The supervisor's `_killStalePortsHolders` covers most cases now but is best-effort.
