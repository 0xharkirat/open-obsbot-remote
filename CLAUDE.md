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

## Current dev state (v1.2 ready for merge)

**Last release:** v1.1.0 (commit `87bbe0a`). After v1.1 the workflow is PR-styled. Branches named `feat/...`, `fix/...`, `docs/...`, `chore/...`. Squash-merge to `main` is the default.

**v1.2 work lives on a single PR** (`PR #16` / branch `fix/ui-revamp-from-review`) that supersedes the original A through K plan. The branch carries every commit from the v1.2 stack, plus the post-review fix-ups. Once that PR merges, `[Unreleased]` in `CHANGELOG.md` becomes `[1.2.0]`.

### Final v1.2 shape

| Area | Result |
|---|---|
| Advanced UI | 3 tabs: Joystick / Buttons / Image. Same template on Joystick and Buttons: top quick-actions row, gimbal control + vertical zoom slider, inline P1 to P6 preset row, duration chip strip at the bottom. |
| Sequence editor | Inline timeline; opened via an AppBar action (`Icons.timeline`). The Sequence tab was dropped. |
| Presets | Inlined on Joystick and Buttons (long-press for Save / Recall instantly / Rename). The Presets tab was dropped. |
| Status chip bar | Removed. Pan/Tilt is in the preview overlay, zoom is next to its slider, AI/FOV live on the Image tab, run-status is the tray icon glyph. |
| Image tab | Auto-track (Off / Person / Group), View (Wide / Normal / Narrow), Tone toggles (HDR / Face exposure / Face focus / Flip), Exposure (Auto / Manual + EV bias slider), Anti-flicker, White balance (Auto + Temperature), Color sliders. Per-section Reset buttons + per-slider inline reset. |
| Grid overlay | 4 layers (crosshair / attitude indicator / rule of thirds / Pan-Tilt readout). Toggled from an AppBar grid menu; persisted via SharedPreferences. |
| Color scheme | OBSBOT red `#FF3B30` accent on deep neutral `#0F1115`. |
| Bridge tray | macOS menubar via `tray_manager`. Closing the window hides it; the bridge keeps running. |
| forui migration | Pair screen migrated (FScaffold / FHeader.nested / FButton on `FThemes.zinc.dark.touch`). TabShell wrapped in FTheme; tab content stays on Material via a transparent Material shim where inputs need a Material ancestor. |
| Plain language sweep | "Yaw / Pitch" -> "Pan / Tilt", "Auto-expose for face" -> "Face exposure", "AI HUMAN/GROUP" -> "Person/Group", "FOV 86" -> "Wide". |

### Test harness

Run before merging. All run against a connected Tiny 2 Lite.

```bash
NODE=/Users/hark/.nvm/versions/node/v22.21.1/bin/node
$NODE tests/bridge_smoke.mjs       # 27 tests: connect / preset / sequence / image / sign convention
$NODE tests/sequencer_save.mjs     # 6 tests:  duration_ms persistence + legacy speed migration
$NODE tests/slow_motion.mjs        # 7 tests:  duration_ms timings (200ms / 1s / 5s / 15s / 60s)
$NODE tests/zoom_speed.mjs         # 9 tests:  zoom planner duration timings
$NODE tests/exposure.mjs           # 8 tests:  exposure mode + EV bias + anti-flicker + WB
$NODE tests/zoom_smoothness.mjs    # samples zoom over 5s and 30s plans; flags lens stalls
```

Plus offline widget tests:

```bash
cd apps/rc && flutter test
# tab_shell_test.dart   - 20 tests for the 3-tab structure + Image tab sections
# pin_entry_test.dart   - 1  test  for the forui pair screen
```

Total: **78 / 78** with no log warnings on live camera.

### MotionPlanner architecture (`apps/bridge_cpp/src/device_session.{h,cpp}`)

- Single worker thread (`motion_loop`) owns interpolation between waypoints.
- `MotionTarget { optional yaw/pitch/roll/zoom + duration_ms + tick_ms + tag }`.
- `motion_start(target)` enqueues + signals cv; `motion_cancel()` preempts (cancel-replace).
- Easing: `ease_in_out_sine` for cinematographic deceleration.
- Adaptive tick on gimbal axes: stretches tick to keep per-step delta at least 0.1 deg per tick (avoids motor jitter at sub-SDK floors).
- Gimbal: `gimbalSetSpeedPositionR(..., speed=90)` per waypoint. Speed is the SDK ceiling; we control the rate by how often we update the target.
- Zoom: `cameraSetZoomAbsoluteR(value, -1)` per waypoint, where `value` is a float. The uint-API `cameraSetZoomWithSpeedAbsoluteR` is broken on Tiny 2 Lite (gets stuck around 1.33x); the float-API produces smooth continuous motion.
- Any direct gimbal/zoom command (instant jog, velocity, terminal zoom snap) calls `motion_cancel()` first to preempt the in-flight planner.

### Protocol (v1.2 deltas vs v1.1)

- `ptz.angle`, `zoom.set`, `preset.recall` take `"duration_ms": <int>` (ms). `0` is instant; positive integers run the planner with ease-in-out-sine.
- `zoom.set` also takes an optional `"final": true` flag (terminal release value; bypasses the mid-drag coalesce).
- `sequence.set` / `sequence.save_as` step shape is `{ "preset_id", "seconds", "transition_ms" }`. The old `"speed": "instant" | "slow" | "medium" | "fast" | "cinema"` enum is gone; legacy saves still load via `legacy_speed_to_ms()`.
- `ptz.velocity` no longer carries `speed`. Rate is implicit from `yaw_speed` and `pitch_speed`; the planner is not invoked.
- New image actions: `image.set_exposure_mode` (auto / manual), `image.set_ev_bias` (float -3.0 to +3.0), `image.set_anti_flicker` (off / 50 / 60 / auto), `image.set_wb_auto` (boolean), `image.set_wb_temp` (kelvin 2800 to 6500).
- State event `image` block gains `exposure_mode`, `ev_bias`, `anti_flicker`, `wb_auto`, `wb_kelvin`. `sequence` block gains `steps` so the editor can hydrate after reconnecting.

### Skills checklist per PR (see `.agents/skills/`)

Tab/layout work uses:
- `flutter-build-responsive-layout` (constraints-driven, not device-class).
- `flutter-add-widget-preview` (preview tabs at all breakpoints without launching the app).

Design + a11y work uses:
- `design:design-system`, `design:ux-copy`, `design:design-critique`,
- `design:accessibility-review`, `design:design-handoff`.

19 skills total under `.agents/skills/`. Prefer these over Playwright-only flows (see `memory/project_tooling_pref.md`). Playwright is still the right tool for end-to-end web-shell verification (it caught the "Recenter wraps" and "preview not visible after cache" issues during v1.2).

### Reference docs

- `docs/PROTOCOL.md` (refreshed for v1.2: duration_ms, exposure, WB, anti-flicker, sequence step migration).
- `docs/ARCHITECTURE.md` (system shape + bundle layout).
- `docs/SLOW_MOTION_DESIGN.md` (design doc that landed as `duration_ms`; see header for the rename).
- `docs/UI_REDESIGN_SPEC.md` (original 5-tab plan + post-review revision section explaining the 3-tab final state).
- `docs/EXPOSURE_REFERENCE.md` (OBSBOT Center capture; PR G shipped these).
- `docs/CONTRIBUTING.md` (PR workflow rules; smoke battery is 78/78).
- `docs/TOUCH_FINDINGS_2026-05-10.md` (v1.1 touch-emulation reproduction; resolution footnote at the bottom).

### Things that bit us during v1.2

21. **`speed_str()` switch non-exhaustive.** When adding new MoveSpeed values pre-removal, sequencer save silently downgraded `ultra`/`cinema` to `medium` on disk. The MoveSpeed enum is now gone (v1.2 uses `duration_ms`) but `tests/sequencer_save.mjs` keeps a migration test so the same trap cannot reopen.
22. **Zoom planner pre-stamped target.** `cmd_zoom_set` planner branch wrote `snap_.zoom = v` before the planner ran, so state events showed the target instantly instead of progressively. Removed the pre-stamp; planner ticks own `snap_.zoom` while running.
23. **Instant zoom didn't cancel planner.** Terminal/instant zoom path skipped `motion_cancel()`, so an in-flight slow zoom kept pushing the old target. Added `if (terminal) motion_cancel();` to the instant branch.
24. **Joystick eats scroll.** Pre-redesign single-page layout meant the joystick `PtzPad` swallowed scroll gestures in the surrounding `ListView`. Could not be fixed incrementally. Solved structurally by giving the joystick its own tab; scrolling action rows live on other tabs.
25. **`Yaw` / `Pitch` jargon.** Operators do not know these. Replaced with `Pan` / `Tilt` everywhere a user reads it (grid overlay readout, Image tab copy).
26. **`cameraSetZoomWithSpeedAbsoluteR` is broken on Tiny 2 Lite.** The uint-API gets stuck around 1.33x regardless of the speed param. The SDK's zoom_speed field is tagged "tail2 / tail2s only" in `dev.hpp`, so on Tiny 2 Lite it is effectively ignored. The float-API `cameraSetZoomAbsoluteR(value, -1)` works (smooth 3-second 1.0x -> 2.0x sweep at default speed) and accepts sub-percent waypoints. Verified by `tests/zoom_probe.mjs` (kept locally; the helper bridge action was removed before merge).
27. **`HoldDirBtn` lost pointer events on web.** Wrapping `Listener` inside a `FilledButton.tonal` with a no-op `onPressed: () {}` let the button's internal `TapGestureRecognizer` win the gesture arena on quick taps, so `Listener.onPointerUp` never fired and the velocity ticker stayed running. The rewrite uses a raw `Listener` on a `Material` surface so press / release / cancel are first-class.
28. **ZoomSlider mid-drag fought the planner.** During a drag the slider sent the user's chosen `duration_ms` on every tick; the planner cancelled and restarted every 100 ms. Mid-drag is now always `duration: Duration.zero` (instant); the chosen duration is applied only on release (`final: true`).
29. **forui `FButton` overflow at 3-per-row narrow widths.** At 360 px the Joystick quick-actions row gives each button ~110 px; `FButton`'s intrinsic padding overflows even with `mainAxisSize.min` + `size.sm`. Kept those buttons on Material `OutlinedButton`. Image tab toggles (2 per row, ~184 px each) could use FButton but were left on Material in this PR for simplicity. Worth filing an upstream issue or shimming.
30. **`SharedPreferences` plugin hangs in flutter_test.** `WsClient`'s constructor calls `SharedPreferences.getInstance()` which under the test harness has no platform implementation. Tests must call `SharedPreferences.setMockInitialValues({})` in `setUp` to unblock. Added to `apps/rc/test/tab_shell_test.dart` + `pin_entry_test.dart`.
