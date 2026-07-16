# CLAUDE.md - guidance for future Claude Code sessions in this repo

This file is auto-loaded into every Claude Code session. Read it before doing anything substantive.
A duplicate copy lives at `AGENTS.md` for non-Claude AI tools that follow that convention.

## What this project is

Phone and browser remote for OBSBOT cameras. Tiny 2 Lite is the tested model; the bridge drives one or more cameras at once. A controller (Android, iOS, or **web browser**) selects a camera, drives pan/tilt/zoom/presets, switches which camera is on air (TAKE - cut or crossfade), and runs both single-camera and cross-camera timed sequences. Cameras stay on USB to the bridge host. OBS reads one Browser Source pointed at `active.mjpg`, so camera switching happens in the bridge, not in OBS scenes.

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
- **Never use em dashes ( - ) in any file in this repo.** Use a plain hyphen surrounded by spaces ( - ) instead.

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

## Current dev state (v2.0.0-dev on `v2-dev`; last public release v1.5.2)

**Where things are (2026-07-12):** the multi-camera and mix-sequencing work is built and merged to `v2-dev`, stamped `2.0.0-dev`, and not yet released. `main` is still v1.5.2. Public version numbers are for releases only; dev work is tracked as phases, not minted versions. The next public release is 2.0.0 (everything below); 2.5.0 then adds non-OBSBOT camera sources.

Built and merged to `v2-dev`:
- Multi-camera bridge: one `DeviceManager` owns N `DeviceSession`s keyed by serial number. State is a `BridgeState` envelope (`devices[]` plus `active_device_id` plus `mix{}`) on the `event:"state"` wire discriminator.
- v3 remote UI: one Live screen replaced the old Drive/Image/More tabs and Simple mode. forui is retired; the app is Material 3 only. Selection (which camera the phone controls) and on-air (which camera `active.mjpg` follows) are separate; TAKE commits the cut, as a hard cut or a crossfade.
- P1 PTZ precision: tap is an absolute nudge, hold is a ramped glide, the joystick uses a squared curve, and release double-stops with a bridge watchdog. Tuning lives in `apps/rc/lib/ptz_tuning.dart`.
- P3 mix sequencer: a bridge-level engine on `DeviceManager` runs cross-camera cues (`mix.*` protocol, `state.mix` block, `mix.json` and `mix_sequences.json`). No on-air movement lock - a live camera moves on air by design.
- P4 crossfade: `jpeg_crossfade` dissolves the outgoing camera's frozen frame into the incoming live frames over `fade_ms`, baked into `active.mjpg`; `jpeg_darken` (fade from black) is the first-take fallback. Library export/import via `library.export` and `library.import`.
- Client packages: `obsbot_api_client` -> `bridge_repository` -> `device_repository` -> the `WsClient` facade, with `auth_repository` for pairing and `obsbot_protocol` for the shared wire types.

Test batteries (against connected cameras): `tests/two_cam_smoke.mjs`, `tests/mix_sequence.mjs`, `tests/fade.mjs`, `tests/library.mjs`, plus the v1 batteries. Run widget and protocol tests through the very_good_cli MCP test tool, not `flutter test` / `dart test` directly.

**Workflow:** PR-styled, squash-merge default. Branches `feat/...`, `fix/...`, `docs/...`, `chore/...`. v2 work merges to `v2-dev`, not `main`, until the real-prod test passes. Parallel worktree agents (`isolation: worktree`) handle independent file-set work.

### History: v1.4.1 (tag `v1.4.1`, commit `c794ac2` on `main`)

### v1.4.x rolled up

v1.4.0 (2026-05-18, PR #25, 6 worktree branches): phone-app advanced-mode redesigned around OBSBOT Center patterns (Drive / Image / More tabs, CollapsibleSection, AI sub-mode pills, preset long-press bottom sheet, sequencer split-fields). Plus 5 major bridge / sequencer / preview fixes - MJPEG silent-disconnect, sequencer move/stay race, pairing JSON leak, bridge text wrap, preset-overwrite UI discoverability.

v1.4.1 (2026-05-18, PR #26 + main pushes): bridge UI polish. Native `macos_ui` widgets (MacosScaffold + ToolBar + MacosListTile-style rows), simpler tray menu (12 -> 6 items, clickable PIN, key equivalents), camera-connected falls back to AVFoundation when libdev misses a hot-replug, em-dashes stripped repo-wide, logo in toolbar, action-button padding bumped, firewall row uses info icon (informational not status) and deep-links to Network pane on Sonoma+, settings footer collapsed to one inline GitHub link.

### v1.2 historic (left here for context)

v1.2.0 shipped the original UI redesign + smooth zoom + exposure controls + first
tray. v1.2.1 was the polish-after-real-use release that landed in a
single consolidated PR (#23) on top of #17–#22:

| Area | v1.2.1 result |
|---|---|
| Bridge tray | **First-party NSStatusItem** (`apps/bridge/macos/Runner/NativeTray.swift` + `apps/bridge/lib/native_tray.dart`). Replaced `tray_manager` 0.5.2  -  its `popUpContextMenu` toggling broke NSMenu click dispatch on macOS Sonoma+. Channel `obsbot.bridge/tray`. Icon bytes pass as `FlutterStandardTypedData` (Flutter assets live in `App.framework`, not main bundle, so `Bundle.main.url` returns nil). |
| Dock lifecycle | **Handy-style**: dock icon follows main-window visibility. Hide window → `.accessory` (no dock); show window → `.regular`. Channel `obsbot.bridge/dock` in `MainFlutterWindow.swift`. The `bridge_start_hidden` pref (renamed from v1.2.1 PR O's `bridge_menubar_only`; migrated in `BridgePrefs.load`) only affects launch state. Onboarding override: when no phones are paired yet, force-show the window so the user sees the PIN/QR. |
| Tray menu | Version line at top; `Status: Running (camera OK)` / paired count; **inline `Pairing PIN: ######` + Copy PIN to clipboard** (Tailscale/Dropbox idiom); Show PIN+QR in main window; Show main window; Open log file; Restart bridge subprocess; Quit. |
| Code signing | `obsbot-bridge` subprocess re-signed AFTER the parent `--deep` pass with stable id `com.harksingh.obsbotbridge.helper`. Without this, default ad-hoc id is `obsbot-bridge-<contenthash>` which changes per build → macOS TCC throws away the camera grant on every rebuild. |
| Motion planner | Gimbal: rate-scaled SDK speed (was flat 90 per tick) so motor flows through eased curve instead of pulse-racing. Headroom 2.0×, floor 15%. Zoom: hybrid  -  short plans (≤1s) one-shot the target; longer plans tick at ≥600ms cadence so the lens converges per waypoint without re-arming. Both branches honour `duration_ms`. |
| Preset card | `_InlinePresetCard._saved` is now `entry != null` (was `entry != null && name.isNotEmpty`). Unnamed saves used to silently become tap-to-save; now tap = recall, hold = save, regardless of name. |
| Protocol | New action `image.refresh` reads back `exposure_mode` / `ev_bias` / `anti_flicker` / `wb_type+kelvin` from the camera via SDK getters, stamps `snap_`, flows out to clients via state event. UI has a "Refresh from camera" button on the Image tab (top-right). |
| Exposure | `cameraSetExposureModeR` + `cameraSetAAEEvBiasR` empirically verified r=0 on Tiny 2 Lite firmware 6.2.8.1 (PR P). SDK header's "tail air" tag is misleading. v1.2.0's `unsupported` guard removed; UI no longer greys out. |
| Cleanup | `velocityScale` field gone (#17). Pure-Dart `packages/obsbot_protocol/` extracts shared types (#18). Custom 22/44 px template PNG replaces the v1.2.0 Unicode glyph (#19). `_QuickActions` Recenter/Sleep/Wake + `_toggleBtn` HDR/Face/Flip/AutoWB migrated to `FButton.raw` (#22). |

### Test harness

Run before merging. All run against a connected Tiny 2 Lite.

```bash
NODE=/Users/hark/.nvm/versions/node/v22.21.1/bin/node
$NODE tests/bridge_smoke.mjs       # 27 tests: connect / preset / sequence / image / sign convention
$NODE tests/sequencer_save.mjs     # 6 tests:  duration_ms persistence + legacy speed migration
$NODE tests/slow_motion.mjs        # 7 tests:  duration_ms timings (500ms / 1s / 5s / 15s / 60s)
$NODE tests/zoom_speed.mjs         # 9 tests:  zoom planner duration timings + hybrid handoff
$NODE tests/exposure.mjs           # 11 tests: exposure mode + EV bias + anti-flicker + WB + refresh
$NODE tests/zoom_smoothness.mjs    # samples zoom over 5s and 30s plans; flags lens stalls
```

Plus the v1.4 W3 sequencer-race regression:

```bash
$NODE tests/sequence_timing.mjs    # 4 tests:  stay-timer chain, phase transitions, stop-mid-move
```

Plus offline widget + protocol-package tests:

```bash
cd apps/rc && flutter test
# tab_shell_test.dart            - Drive / Image / More structure + preset long-press sheet + 320px overflow
# sequencer_screen_test.dart     - move/stay split fields
# collapsible_section_test.dart  - open/close persistence
# pin_entry_test.dart            - forui pair screen

cd packages/obsbot_protocol && dart test
# obsbot_protocol_test.dart      - JSON round-trips + SequenceState.phase + CameraState.fromEvent
```

Total: **125 / 125** (64 backend + 45 widget + 16 protocol) on v1.4.1.

### MotionPlanner architecture (`apps/bridge_cpp/src/device_session.{h,cpp}`)

- Single worker thread (`motion_loop`) owns interpolation between waypoints.
- `MotionTarget { optional yaw/pitch/roll/zoom + duration_ms + tick_ms + tag }`.
- `motion_start(target)` enqueues + signals cv; `motion_cancel()` preempts (cancel-replace).
- Easing: `ease_in_out_sine` for cinematographic deceleration.
- Adaptive tick on gimbal axes: stretches tick to keep per-step delta at least 0.1 deg per tick (avoids motor jitter at sub-SDK floors).
- **Gimbal speed (v1.2.1 change):** rate-scaled per-axis. `pct = (deg_per_sec / 1.5) * 2.0`, clamped `[15, 100]`. Old v1.2.0 flat-90 raced/waited per tick → visible 100 ms-cadence shake on any duration_ms > 0.
- **Zoom (v1.2.1 hybrid):** short plans (`duration_ms <= 1000`) call `cameraSetZoomAbsoluteR(target, -1)` ONCE; let the lens drive itself. Longer plans tick at `>= 600 ms` cadence  -  lens converges per waypoint before next arrives. Old v1.2.0 ticked every 100 ms which re-armed the lens's internal plan → `in/out/in/out` oscillation. The uint-API `cameraSetZoomWithSpeedAbsoluteR` is broken on Tiny 2 Lite (stuck at 1.33x); float-API is the only path.
- Any direct gimbal/zoom command (instant jog, velocity, terminal zoom snap) calls `motion_cancel()` first to preempt the in-flight planner.

### Protocol (v1.4 deltas vs v1.2.1)

- **`sequence.phase`** state-event field: `"moving"` while MotionPlanner is in flight, `"holding"` while stay-timer counts. Default `"holding"`. Defensive backward compat - old clients ignore the field.
- **`MotionPlanner.motion_wait_idle(timeout_ms)`** public method on the bridge - blocks until the planner is idle. Used by the sequencer to chain `trigger_step -> wait -> reset stay clock` so `seconds` no longer overlaps `transition_ms`.
- AI `sub_mode` now respected from `ai.set_mode` (was always sent as `"normal"`) - 5 sub-modes wired: `normal` / `upper_body` / `close_up` / `headless` / `lower_body`.

### Protocol (v1.2.1 deltas vs v1.2.0)

- `image.refresh`  -  re-read live exposure / anti-flicker / WB state from the camera via SDK getters; stamps `snap_` so all subscribers get a state event with current values. Useful when OBSBOT Center or another phone changed values out-of-band.
- Exposure mode + EV bias `unsupported` guard removed; both return `ok=true` on Tiny 2 Lite firmware 6.2.8.1+.
- Carryovers from v1.2.0 still valid: `duration_ms` on `ptz.angle` / `zoom.set` / `preset.recall`; `final: true` on `zoom.set`; sequence step shape `{ preset_id, seconds, transition_ms }`; new image actions (`image.set_exposure_mode` / `image.set_ev_bias` / `image.set_anti_flicker` / `image.set_wb_auto` / `image.set_wb_temp`); state-event fields `exposure_mode` / `ev_bias` / `anti_flicker` / `wb_auto` / `wb_kelvin`.

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

### Things that bit us during v1.2 - v1.4

21. **`speed_str()` switch non-exhaustive.** When adding new MoveSpeed values pre-removal, sequencer save silently downgraded `ultra`/`cinema` to `medium` on disk. The MoveSpeed enum is now gone (v1.2 uses `duration_ms`) but `tests/sequencer_save.mjs` keeps a migration test so the same trap cannot reopen.
22. **Zoom planner pre-stamped target.** `cmd_zoom_set` planner branch wrote `snap_.zoom = v` before the planner ran, so state events showed the target instantly instead of progressively. Removed the pre-stamp; planner ticks own `snap_.zoom` while running.
23. **Instant zoom didn't cancel planner.** Terminal/instant zoom path skipped `motion_cancel()`, so an in-flight slow zoom kept pushing the old target. Added `if (terminal) motion_cancel();` to the instant branch.
24. **Joystick eats scroll.** Pre-redesign single-page layout meant the joystick `PtzPad` swallowed scroll gestures in the surrounding `ListView`. Could not be fixed incrementally. Solved structurally by giving the joystick its own tab; scrolling action rows live on other tabs.
25. **`Yaw` / `Pitch` jargon.** Operators do not know these. Replaced with `Pan` / `Tilt` everywhere a user reads it (grid overlay readout, Image tab copy).
26. **`cameraSetZoomWithSpeedAbsoluteR` is broken on Tiny 2 Lite.** The uint-API gets stuck around 1.33x regardless of the speed param. The SDK's zoom_speed field is tagged "tail2 / tail2s only" in `dev.hpp`, so on Tiny 2 Lite it is effectively ignored. The float-API `cameraSetZoomAbsoluteR(value, -1)` works (smooth 3-second 1.0x -> 2.0x sweep at default speed) and accepts sub-percent waypoints. Verified by `tests/zoom_probe.mjs` (kept locally; the helper bridge action was removed before merge).
27. **`HoldDirBtn` lost pointer events on web.** Wrapping `Listener` inside a `FilledButton.tonal` with a no-op `onPressed: () {}` let the button's internal `TapGestureRecognizer` win the gesture arena on quick taps, so `Listener.onPointerUp` never fired and the velocity ticker stayed running. The rewrite uses a raw `Listener` on a `Material` surface so press / release / cancel are first-class.
28. **ZoomSlider mid-drag fought the planner.** During a drag the slider sent the user's chosen `duration_ms` on every tick; the planner cancelled and restarted every 100 ms. Mid-drag is now always `duration: Duration.zero` (instant); the chosen duration is applied only on release (`final: true`).
29. **forui `FButton` overflow at 3-per-row narrow widths.** At 360 px the Joystick quick-actions row gives each button ~110 px; `FButton`'s intrinsic padding overflowed at first. Solved in v1.2.1 by using `FButton.raw` with a `Flexible + Text(maxLines: 1, overflow: TextOverflow.ellipsis)` child  -  structural cap on width. Regression test at 320 px in `tab_shell_test.dart`.
30. **`SharedPreferences` plugin hangs in flutter_test.** `WsClient`'s constructor calls `SharedPreferences.getInstance()` which under the test harness has no platform implementation. Tests must call `SharedPreferences.setMockInitialValues({})` in `setUp` to unblock. Added to `apps/rc/test/tab_shell_test.dart` + `pin_entry_test.dart`.
31. **`tray_manager` 0.5.2 drops menu click dispatch on macOS Sonoma+.** Its `popUpContextMenu` assigns `statusItem.menu = trayMenu` then nulls it in `menuDidClose`. That dance breaks NSMenu's target/action chain  -  menus render fine but clicks never reach the Dart-side `TrayListener`. Symptom: Quit / Show window / Reveal PIN are no-ops. Replaced entirely by first-party `NativeTray.swift` that keeps the NSMenu permanently attached.
32. **`.accessory` windows can `orderFront` but never become key.** When the bridge is in `.accessory` (dock hidden) and the user clicks tray > Show main window, calling `windowManager.show()` then `focus()` is not enough  -  the window appears but can't accept clicks. Fix in `MainFlutterWindow.swift`'s `obsbot.bridge/dock` channel: flip `setActivationPolicy(.regular)` FIRST, then `makeKeyAndOrderFront(nil)` + `NSApp.activate(ignoringOtherApps:)`. TrayController's `_showAndFocus` awaits the policy flip before calling `windowManager.focus()` so the chain converges in order.
33. **Flutter assets aren't in `Bundle.main` on macOS.** `flutter_assets/` ships inside `Contents/Frameworks/App.framework/Resources/`, not the main bundle. `Bundle.main.url(forResource:withExtension:)` returns nil. Pass raw PNG bytes through the channel via `FlutterStandardTypedData` instead (matches what `tray_manager` did with base64, but binary). See `NativeTray.swift::setIcon` + `native_tray.dart::setIcon`.
34. **Ad-hoc subprocess id changes per build → camera TCC grant evaporates.** Without explicit `-i`, codesign stamps `obsbot-bridge-<contenthash>`. Every rebuild a new identity, macOS TCC creates a new entry, user must re-grant. Fix: re-sign subprocess AFTER the parent `--deep` pass with stable `-i com.harksingh.obsbotbridge.helper`, then re-seal the parent bundle. See `scripts/build-bridge-mac.sh`.
35. **`applicationShouldTerminateAfterLastWindowClosed` must return false.** True (default) auto-quits the app when the window hides. With the tray owning lifecycle (red-dot just hides; explicit quit via tray menu), false is correct. Also required for the start-hidden launch path  -  the hidden window was misread as "last window closed" and the app died instantly on launch.
36. **`gimbalSetSpeedPositionR(.., 90, 90, 90)` per tick = motor races + waits.** v1.2.0 set the SDK speed to 90 (ceiling) on every 100 ms waypoint. With small deltas per tick, motor finished each waypoint in <10 ms then idled, producing visible 100 ms-cadence stutter. v1.2.1 scales speed per-axis to roughly match per-tick deg/s with 2.0× headroom + 15% floor; motor flows.
37. **`cameraSetZoomAbsoluteR(value, -1)` ticked at 100 ms = lens oscillation.** Lens motor has its own internal motion plan; each call re-arms it. Tick every 100 ms and the lens never converges  -  visible in/out/in/out on any preset recall combining motion + zoom. v1.2.1 hybrid: one-shot for `duration_ms <= 1000`; else tick at ≥600 ms so the lens has time to settle between waypoints.
38. **`_InlinePresetCard._saved` required non-empty `name`.** Unnamed saves are valid (the bridge stores the pose) but the UI's `_saved` check fell through to the empty-slot branch  -  tap-to-recall silently became tap-to-save. Now `_saved = entry != null`.
39. **MJPEG `send()` blocks forever on a wedged TCP write.** Bridge accepted client sockets with only `SO_REUSEADDR`. When Wi-Fi roamed / phone backgrounded / NAT dropped state, the kernel send-queue filled, `send()` blocked the serving thread for ~15 min (macOS default retransmit) before noticing. Symptom: "preview stops mid-stream" with no browser error, no bridge crash. Evidence: 145 `client connected` vs 104 `client disconnected` log entries. Fix in v1.4 (W2): `SO_KEEPALIVE` + `SO_SNDTIMEO=5s` + `SO_NOSIGPIPE` per-socket in `mjpeg_server.cpp::serve_client`. Wedged writes now fail fast and the existing loop-exit path logs disconnect.
40. **Sequencer stay-timer ran concurrently with move-timer.** v1.2's loop reset `step_started` immediately after dispatching `motion_start` and used `seconds` as the only budget. User-observed: `seconds=40, transition_ms=30000` -> only ~10 s of actual hold. Fix in v1.4 (W3): chain `trigger_step -> motion_wait_idle(transition_ms + 500) -> reset step_started`. New `MotionPlanner.motion_wait_idle` blocks until `motion_active_` atomic flips back to false. `cmd_sequence_stop` also calls `motion_cancel()` before joining so stops mid-move release the planner promptly. New `sequence.phase` state-event field surfaces `"moving"` / `"holding"` for UI affordances.
41. **Pair screen leaked server developer-facing protocol hint as a red error.** On `auth_required` the bridge sends `msg: "send {action:'pair', pin:<6-digit>} or {action:'hello', token:<token>}"`. Dart side put that JSON-ish string into `_lastAuthError`, the pair screen rendered it under the PIN input. Entering the pair screen is a state transition not an error; `_lastAuthError = null` is correct. Same pattern likely applies anywhere we store server hints as user copy - audit before exposing.
42. **macOS deep-link URL fragments dropped on Sonoma+.** `x-apple.systempreferences:com.apple.preference.security?Firewall` was the macOS 12 way to open Firewall; on Sonoma+ the `?Firewall` fragment is silently ignored and you land on Privacy & Security root. Firewall moved to Network. Use `com.apple.Network-Settings.extension` with a fallback to the legacy URL.
43. **`MacosApp` provides CupertinoLocalizations, not MaterialLocalizations.** Wrapping the entire app in `MacosApp` breaks Scaffold/AlertDialog/SnackBar/SwitchListTile - they need Material context. Two-layer wrapper works: `MacosApp(home: MaterialApp(home: ...))`. macos_ui widgets render inside the Material subtree without complaint; Material widgets get the localizations they need.
44. **`ControlSize.small` PushButtons look cramped at default text sizes.** macos_ui's small size matches the AppKit small-control density; if your label is more than ~6 chars or visually adjacent to body text, prefer `ControlSize.regular`. Save small for inline-with-text micro-affordances ("Reveal" next to a log path, "Copy URL" under a QR).
45. **Em dashes (`—`) keep creeping in despite the project rule.** Repo policy since v1.1 is plain hyphen surrounded by spaces (` - `). Most agents emit em dashes when generating prose. v1.4.1 stripped ~80 from Dart/Swift/C++/Markdown/shell. Future PRs: grep for `—` before commit.
46. **macOS Application Firewall keys by binary code-signature hash.** Stable codesign identifier (`com.harksingh.obsbotbridge.helper`) doesn't help - the firewall hashes the binary, not the identifier. Every rebuild = new entry in Firewall -> Options. Cosmetic mess on repeated rebuilds + every release update. `scripts/clean-firewall-entries.sh` enumerates + removes via `socketfilterfw` (requires sudo). True fix would need bit-reproducible C++ builds.
47. **`cameraConnected` is independent of `video.running`.** libdev's USB plug callback can miss a hot-replug (camera unplugged + replugged); `snap_.connected` stays false even though AVFoundation grabs the camera and the preview works. v1.4.1 (W2) fix: bridge supervisor returns `_cameraConnected || _videoRunning`; the `_videoRunning` flag is parsed from the bridge log's `video: capture session started` line. `detectedModel` falls back to `using device '<name>'` for the same reason.
48. **Flutter web filenames are NOT content-hashed - never serve them `immutable`.** `ws_server.cpp`'s static handler hard-cached everything outside a small allowlist (`public, max-age=31536000, immutable`), on a comment that claimed "Flutter web's asset filenames are hashed". They are not. `index.html`, `main.dart.js`, and everything under `assets/` keep the same filename while their bytes change every build. The icon font is the worst case: Flutter tree-shakes `MaterialIcons-Regular.otf` down to only the glyphs that build actually uses (~13KB), so a phone holding a copy cached from an older build is missing the new codepoints and **every icon renders blank**. The JS side had already been patched three separate ways (mtime cache-bust query on `flutter_bootstrap.js` + `main.dart.js`, a self-unregistering service-worker stub, `no-store` headers) but `assets/` was never covered, so the bug kept coming back through the font. Fixed by inverting the default: serve everything `no-cache` and hard-cache only `canvaskit/` (37MB, changes only on a Flutter SDK bump). Note that a client already poisoned cannot be rescued from the server - `immutable` means the browser never revalidates, so affected phones must clear site data once.
