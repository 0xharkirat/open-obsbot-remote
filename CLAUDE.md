# CLAUDE.md - guidance for future Claude Code sessions in this repo

This file is auto-loaded into every Claude Code session. Read it before doing anything substantive.
A duplicate copy lives at `AGENTS.md` for non-Claude AI tools that follow that convention.

## What this project is

Phone-based remote for OBSBOT cameras (Tiny 2 Lite is the only camera tested). A controller device uses Android, iOS, or a **web browser** to pan/tilt/zoom/recall presets/run a timed sequence while the camera stays connected to the bridge host over USB.

Two products:

- **Open OBSBOT Bridge** - macOS `.app` the user installs once. Wraps the C++ subprocess (`obsbot-bridge`) that talks to the camera over USB via OBSBOT's libdev SDK. Serves a JSON-over-WebSocket control API on `:8765`, an HTTP MJPEG preview on `:8766`, and the Flutter web build of the remote at `http://<mac>:8765/`.
- **Open OBSBOT Remote** - Flutter app for the phone (iOS + Android + Web). Web build is bundled inside the Bridge .app and served directly, so users don't need an app-store install.

## Repo layout

```
.
├── apps/
│   ├── rc/            "Open OBSBOT Remote" - Flutter app for the controller surface.
│   │                   Targets iOS + Android + Web. Bundle IDs:
│   │                   com.harksingh.obsbotcontrol (iOS), com.harksingh.obsbot_control (Android).
│   │                   Internal pubspec name still `obsbot_control` - don't rename, breaks imports.
│   ├── bridge_cpp/    C++ WS+HTTP+MJPEG bridge - links libdev + AVFoundation. Single
│   │                   binary `obsbot-bridge`. Wrapped by apps/bridge/ as a subprocess.
│   └── bridge/        "Open OBSBOT Bridge" - Flutter desktop app wrapping bridge_cpp.
│                       Currently macOS only. Windows + Linux planned in same project.
│                       Internal pubspec name still `obsbot_bridge_mac` - leave it.
│                       Bundle ID: com.harksingh.obsbotbridge.
├── packages/                    (planned) shared Dart pkgs - empty stubs.
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

For dev iteration on the C++ bridge alone (no Flutter wrapper), `./run-bridge.sh` runs it from Terminal - but Terminal needs camera permission for that to work.

## Things that bit us, don't repeat

1. **Crow's `response.write()` does not flush mid-handler.** It buffers the whole response until the handler returns. Multipart/x-mixed-replace is impossible through Crow. We solved it with a hand-rolled BSD-socket server in `apps/bridge_cpp/src/mjpeg_server.cpp` listening on port+1.
2. **Unsigned subprocess + macOS TCC.** The bundled `obsbot-bridge` won't inherit camera-access grants from the parent .app unless the whole bundle is code-signed. We ad-hoc sign in `build-bridge-mac.sh` (`codesign --force --deep --sign -`). Without that, preview silently fails.
3. **Bundle-ID changes break TCC.** Every time we rename `PRODUCT_BUNDLE_IDENTIFIER`, macOS treats it as a new app and the camera/local-network prompts re-fire. Don't rename casually.
4. **Sandbox must be OFF.** App Sandbox blocks raw USB and binding TCP listeners. We ship via Developer ID (eventually), not Mac App Store, so `com.apple.security.app-sandbox = false` in both entitlements files is fine.
5. **Android cleartext traffic.** Bridge runs on `ws://` and `http://` over LAN. Android needs `android:usesCleartextTraffic="true"`. iOS needs `NSAppTransportSecurity → NSAllowsLocalNetworking`. macOS clients need `com.apple.security.network.client`.
6. **Tiny 2 Lite digital-zoom max is 2.0×, not 4.0×.** The slider's `zoomMax` came back as `4.0` from a default; out-of-range commands silently clamped, looking broken. Bridge now picks `2.0` for Tiny 2 Lite via product type and snaps `snap_.zoom` immediately on set so phone UI feels instant instead of waiting for the 500ms poll.
7. **Use `cameraSetZoomWithSpeedAbsoluteR`, not `cameraSetZoomAbsoluteR`** - the vendor sample uses the former; the latter sometimes silently fails.
8. **`cameraSetAiModeU(AiWorkModeNone)` before any manual gimbal command.** AI tracking owns the gimbal otherwise. `device_session.cpp::cmd_ptz_*` already does this.
9. **HDR + media-mode switches** need a 3-second debounce per the SDK comments. Bridge enforces this.
10. **`flutter run` hot-reload doesn't always re-evaluate Dart logic in `build()`** - when changing widget logic, prefer hot RESTART (capital R).
11. **`MainActivity.kt` package must match `namespace` in `build.gradle.kts`** - moving `applicationId` is fine, but if you change `namespace` you must move the kotlin source under the matching directory.
12. **`CameraStatus` from libdev is a tagged union by `productType()`.** Read `cs.tiny.*` only if `productType() == ObsbotProdTiny2 || ObsbotProdTiny2Lite`. Mis-cast = junk.
13. **SIGPIPE kills the bridge on phone disconnect** unless you `signal(SIGPIPE, SIG_IGN)` at startup. Browsers / phones drop sockets uncleanly all the time.
14. **libdev's `DevicesPrivate::~DevicesPrivate()` throws on shutdown** → `std::terminate`. Use `_Exit(0)` from signal handler to skip global destructors.
15. **Stable `TextEditingController` per row** - recreating a controller every parent rebuild kills cursor + focus. Was the bug behind "can't type seconds in sequencer". Each `_EditStep` now owns its controller.
16. **`WebSocketChannel.stream` is a single-subscription stream.** Don't cancel + re-listen - messages arriving in between are lost. The pair() flow uses a single subscription + a Completer matched by id.
17. **flutter_mjpeg doesn't work on Flutter web.** `Image.network` doesn't decode multipart streams either. Use `HtmlElementView` + a real `<img>` element. Conditional import via `dart.library.js_interop`.
18. **Crow returns 404 for paths > 3 segments** (we now have 4-segment routes for nested Flutter web assets). Add more if needed.
19. **OBSBOT Center is NOT required** for first-time setup or daily use - our bridge does everything except firmware updates. But if both are running at once, they fight over the camera control endpoint; PTZ commands return `device_busy`. Quit OBSBOT Center before launching our bridge.
20. **AppDelegate single-instance** is needed because ad-hoc-signed dev builds occasionally slip through `LSMultipleInstancesProhibited`. Self-quit if a sibling exists.

## Conventions

- WS port 8765, MJPEG port 8766 (always WS-port + 1). Both configurable but everywhere assumes the +1 relationship.
- Logs persist at `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.
- Auth state at `~/Library/Application Support/Open OBSBOT Bridge/auth.json` (PIN + tokens).
- Active sequence persists at `~/Library/Application Support/Open OBSBOT Bridge/sequence.json`.
- Saved sequence library persists at `~/Library/Application Support/Open OBSBOT Bridge/sequences.json`.
- Keep responses concise. Use clearer prose for security, legal, and permission topics.
- macOS app is _not_ sandboxed and _not_ notarized yet. Distribution is GitHub Release ZIP or source build.
- **Never use em dashes (—) in any file in this repo.** Use a plain hyphen surrounded by spaces ( - ) instead.

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

See README.md "Features" and "Known Limits" sections. Tiny 2 Lite is the tested path; firmware updates still require OBSBOT Center.

## Operating tips

- GitHub operations may require permission prompts and may be blocked in non-interactive automation. If so, hand the exact command back to the user.
- Don't rewrite working code unless asked. Add features behind toggles, keep the demo path intact.
- Don't try to commit the SDK (`third_party/obsbot-sdk/`). It's gitignored on purpose.
- When re-launching the Mac app after a rebuild, kill the old subprocess first: `pkill -9 -f obsbot-bridge` and `osascript -e 'quit app "Open OBSBOT Bridge"'`. The supervisor's `_killStalePortsHolders` covers most cases now but is best-effort.

## Current dev state (v1.2 in progress)

**Last release:** v1.1.0 (commit `87bbe0a`). After v1.1, the workflow is PR-styled — no direct main commits. Branches named `feat/...`, `fix/...`, `docs/...`, `chore/...`.

**Recently merged into main since v1.1.0:**
- PR #2 `feat/slow-motion` (commit `55d9615`): MotionPlanner — sub-SDK-floor smoothness via wall-clock `duration_ms` waypoint interpolation. Replaced `MoveSpeed` enum with explicit `duration_ms` int. Migration helper `legacy_speed_to_ms()` keeps v1.0/v1.1 sequences.json files working. See `docs/SLOW_MOTION_DESIGN.md`.
- PR #3 `fix/footer-credit` (commit `3d19a09`): restored "by Hark Singh + harksingh.com" credit in footers.

**Open / awaiting review:**
- PR #4 `feat/grid-overlay`: live preview grid overlay with 4 independently-toggled layers (center crosshair / center alignment lines / rule-of-thirds / Pan-Tilt readout). `apps/rc/lib/grid_overlay.dart` is a `CustomPaint` wrapped in `IgnorePointer`. Toggles persisted via SharedPreferences (`grid_crosshair`, `grid_center_lines`, `grid_thirds`, `grid_readout`). Plain-language readout shows `PAN ←→ X°` / `TILT ↑↓ Y°` (not Yaw/Pitch).
- PR #5 `docs/ui-redesign-spec`: `docs/UI_REDESIGN_SPEC.md` (5-tab layout) + `docs/EXPOSURE_REFERENCE.md` (OBSBOT Center capture for future PR G).

**Active branch as of this writing:** `docs/ui-redesign-spec`.

### v1.2 PR sequence (from `docs/UI_REDESIGN_SPEC.md`)

User directive: do redesign first, then exposure. Execute in order A → K.

| # | Branch | What |
|---|---|---|
| A | `feat/tab-bar-shell` | 5-tab shell below pinned preview, no behavior change |
| B | `feat/joystick-tab` | Move joystick into Tab 1 (fixes scroll-eats-gesture conflict) |
| C | `feat/buttons-tab` | Hold-button 8-way pad with speed slider |
| D | `feat/presets-tab` | 6 preset cards 2×3 |
| E | `feat/sequencer-tab` | Timeline-style step cards |
| F | `feat/image-tab` | Image-tab shell: HDR/FOV/face/color sliders |
| G | `feat/exposure-controls` | Exposure mode + EV bias + anti-flicker + WB (per `docs/EXPOSURE_REFERENCE.md`) |
| H | `feat/bridge-tray` | macOS menubar tray (`tray_manager` package) |
| I | `feat/forui-shell` | First forui screen (pair + header) |
| J | `feat/forui-tabs` | forui for all tab content |
| K | `chore/release-v1.2.0` | Bump versions, CHANGELOG, GH release |

### Test harness

Run before merging any PR. All run against a connected Tiny 2 Lite.

```bash
NODE=/Users/hark/.nvm/versions/node/v22.21.1/bin/node
$NODE tests/bridge_smoke.mjs       # 27 tests — connect / preset / sequence / image controls
$NODE tests/sequencer_save.mjs     # 6 tests — duration_ms persistence + legacy speed migration
$NODE tests/slow_motion.mjs        # 7 tests — duration_ms timings (200ms / 1s / 5s / 30s)
$NODE tests/zoom_speed.mjs         # 9 tests — zoom planner duration timings
```

Total: **49/49** pass with no warning log lines. Add tests for each new PR's surface (e.g. PR F adds image-control tests, PR G adds exposure-mode tests).

### MotionPlanner architecture (`apps/bridge_cpp/src/device_session.{h,cpp}`)

- Single worker thread (`motion_loop`) owns interpolation between waypoints.
- `MotionTarget { optional yaw/pitch/roll/zoom + duration_ms + tick_ms + tag }`.
- `motion_start(target)` enqueues + signals cv; `motion_cancel()` preempts (cancel-replace).
- Easing: `ease_in_out_sine` for cinematographic deceleration.
- Adaptive tick: stretches tick to keep per-step delta ≥ 0.1° / ≥ 0.005 zoom (avoids motor jitter at sub-SDK floors).
- Issues `gimbalSetSpeedPositionR(..., speed=90)` per waypoint — speed is the SDK ceiling; we control the rate by how often we update the target.
- Zoom: `cameraSetZoomWithSpeedAbsoluteR(..., speed=10)` per waypoint.
- Any direct gimbal/zoom command (instant jog, velocity, terminal zoom snap) calls `motion_cancel()` first to preempt in-flight planner.

### Protocol (v1.2 deltas vs v1.1)

- `ptz.angle`, `ptz.preset_recall`, `zoom.set` take `"duration_ms": <int>` (ms). `0` = instant hardware command, `>0` = planner.
- `sequence.save` step shape: `{ "preset_id", "seconds", "transition_ms" }` (no more `move_speed`).
- `ptz.velocity` no longer carries `speed` — rate is implicit, planner not invoked.

### Skills checklist per PR (see `.agents/skills/`)

Tab/layout PRs (A–F) use:
- `flutter-build-responsive-layout` — every layout PR; constraints-driven, not device-class.
- `flutter-add-widget-preview` — preview tabs at all breakpoints without launching the app.

Design + a11y PRs:
- `design:design-system` — token review before A; deep review before G/H.
- `design:ux-copy` — string sweep before each PR merge.
- `design:design-critique` — screenshot review before merge.
- `design:accessibility-review` — color + tap-target audit on G/H.
- `design:design-handoff` — exact spec sheet into PR description.

19 skills total under `.agents/skills/`; prefer these over Playwright-only flows (see `memory/project_tooling_pref.md`).

### Reference docs

- `docs/ARCHITECTURE.md`, `docs/PROTOCOL.md` — protocol + system shape.
- `docs/SLOW_MOTION_DESIGN.md` — duration_ms / MotionPlanner rationale + math.
- `docs/UI_REDESIGN_SPEC.md` — v1.2 layout, copy table, breakpoints, PR sequence.
- `docs/EXPOSURE_REFERENCE.md` — OBSBOT Center exposure UI + SDK functions for PR G.
- `docs/CONTRIBUTING.md` — PR workflow rules.
- `docs/TOUCH_FINDINGS_2026-05-10.md` — touch-emulation regression notes.

### Things that bit us during v1.2

21. **`speed_str()` switch non-exhaustive** — when adding new MoveSpeed values pre-removal, sequencer save silently downgraded `ultra`/`cinema` to `medium` on disk. Lesson: any enum-to-string switch must be exhaustive + tested via `tests/sequencer_save.mjs`. Now moot (enum gone) but the test stays for migration coverage.
22. **Zoom planner pre-stamped target** — `cmd_zoom_set` planner branch wrote `snap_.zoom = v` before the planner ran, so state events showed the target instantly instead of progressively. Removed the pre-stamp; planner ticks own `snap_.zoom` while running.
23. **Instant zoom didn't cancel planner** — terminal/instant zoom path skipped `motion_cancel()`, so an in-flight slow zoom kept pushing the old target. Added `if (terminal) motion_cancel();` to instant branch.
24. **Joystick eats scroll** — pre-redesign single-page layout meant the joystick PtzPad swallowed scroll gestures in the surrounding ListView. Cannot be fixed incrementally — solved structurally by PR A/B (joystick gets its own tab; scrolling action rows live on other tabs).
25. **`Yaw`/`Pitch` jargon** — operators don't know these. Replaced with `Pan`/`Tilt` in grid overlay readout, will sweep the rest in PR F per the copy table.
