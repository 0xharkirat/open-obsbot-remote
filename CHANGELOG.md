# Changelog

All notable changes to Open OBSBOT Control. Format: [Keep a Changelog](https://keepachangelog.com/), versioning per [SemVer](https://semver.org/).

## [Unreleased]

## [1.1.0] - 2026-05-10

Real-world livestream feedback (temple program, Tiny 2 Lite over USB,
web client over LAN) drove this release. Five ship-blocker bugs and one
slow-pan tier.

### Added
- **Cinema speed tier.** New `MoveSpeed.cinema` below `slow` for wedding-
  movie pace. Maps to s_yaw=4, s_pitch=3, s_roll=2 deg/s on
  `gimbalSetSpeedPositionR`. Available everywhere a speed is selectable
  (control screen menu, simple-mode menu, preset recall, sequencer steps).
- **Zoom-gimbal duration sync** for preset recall + sequencer steps.
  Bridge now estimates how long the gimbal will take to reach the target
  attitude based on yaw/pitch/roll deltas + chosen MoveSpeed, then picks
  a zoom-motor speed (1-10) that lands the zoom move at roughly the
  same time. Biased 10% slower so zoom always finishes after gimbal.
- **`final` flag on `zoom.set`.** Client tags the `onChangeEnd` zoom value
  as terminal; bridge bypasses the mid-drag coalesce so the lens always
  lands where the user released. `WsClient.zoomSet(value, terminal: true)`.
- **Production-grade test infrastructure.**
  - `tests/bridge_smoke.mjs` — Node + ws smoke harness, 27 tests against
    real Tiny 2 Lite, runs in ~28s. Tails bridge log for new errors.
  - `docs/V1.1_PLAN.md` — full v1.1 backlog with sequencing.
  - `docs/TOUCH_FINDINGS_2026-05-10.md` — touch-emulation reproduction
    recipe + diagnostics for any future gesture-arena bug.
- **PR-styled workflow** for every change going forward.
  `docs/CONTRIBUTING.md` documents branch model + PR template +
  release-branch process.
- **Bridge cache chain** — `index.html`, `flutter_bootstrap.js`, and
  `main.dart.js` all now have `?v=<mtime>` cache busters; service worker
  replaced with self-unregistering stub. New builds ship instantly.
- **Auto-HDR-off on connect** — Tiny 2 Lite ships HDR DOL2TO1 raw frames
  that our AVFoundation passthrough doesn't tone-map. Bridge forces
  HDR off on every device-plugged so preview always looks like OBSBOT
  Center's tone-mapped output.

### Fixed
- **PTZ velocity sign convention inverted.** Down button moved camera
  up, Up moved down, joystick was reversed on yaw too. Single-line
  negate in `cmd_ptz_velocity`. Documents canonical convention:
  positive yaw_speed pans right (viewer frame), positive pitch_speed
  tilts up.
- **Joystick swallowed by page scroll on small viewports.** The
  mobile-portrait layout wrapped the entire page in
  `SingleChildScrollView`, which won the gesture arena over the
  joystick's `GestureDetector` for vertical-first drags. Reproduced at
  Pixel 360x800 and iPad 768x1024 (overflow ≥56px) — 0 velocity messages
  pre-fix, 16 post-fix. Hero controls (preview + joystick + zoom slider)
  are now pinned above a scrollable region; only the action rows scroll.
- **Intermittent zoom failure.** `zoom.set`'s mid-drag coalesce dropped
  the user's release-value if it was a tiny-step (<0.1×) within 80ms of
  the previous tick. New `final` flag forces the apply.
- **Sequencer zoom snapped while gimbal panned slowly.** Wedding/temple
  use case: a slow-pan transition had zoom finish in <500ms while gimbal
  took 3-5s. Now they finish together via duration-paced zoom-speed.
- **`MoveSpeed.fast` was overflowing SDK.** Old mapping `s_yaw=120` was
  silently clamped to 90 by the SDK. Honest mapping now caps at 90.
- **MJPEG color cast (green/dark vs OBSBOT Center).** `video_capture.mm`
  now pins sRGB color space end-to-end, captures at 1080p (Tiny 2 Lite
  native instead of forced 720p), and JPEG quality 0.55 → 0.80.
- **State-poll clobbered freshly-set zoom / AI mode / FOV / face AE /
  face focus / flip H / HDR.** Pending-target gates plus inline snap
  updates so client UI sees the new value on the next state event
  without waiting for the camera-firmware echo (~500ms cadence).
- **First velocity tick swallowed by AI tracker.** 50ms settle after
  the first manual AI-off so camera firmware releases the gimbal
  before `aiSetGimbalSpeedCtrlR` arrives.

### Tooling
- Project-scoped Playwright MCP at `.mcp.json` with CDP touch emulation
  for repeatable mobile-touch regression tests.
- 19 Flutter + Dart agent skills installed under `.agents/skills/`.
- Memory note `project_tooling_pref.md` directing future sessions to
  prefer skills, fall back to Playwright only for web-shell e2e.

## [1.0.0] - 2026-05-09

### Added
- **Developer-friendly docs refresh** — README, run guide, architecture, protocol, app READMEs, and security policy now match the current public-source plus macOS release ZIP flow.
- **macOS release packaging script** — `scripts/package-mac-release.sh` builds the app, verifies the bundle, optionally Developer ID signs/notarizes/staples it, creates an arm64 release ZIP, and writes a SHA-256 checksum.
- **Saved sequence library** — name + persist sequences, switch between them via dropdown. Bridge stores them at `~/Library/Application Support/Open OBSBOT Bridge/sequences.json`. New WS actions `sequence.save_as / sequence.load / sequence.delete`. State event ships `sequence.available` + `sequence.loaded`.
- **AGENTS.md** so AI coding tools find the same repo guidance.
- **CHANGELOG.md** (this file).
- **CONTRIBUTING.md**, **CODE_OF_CONDUCT.md**, GitHub issue + PR templates.
- **Footers** in both apps crediting the project, OBSBOT SDK, and Flutter.

### Changed
- Folder rename: `apps/bridge_mac → apps/bridge`, `apps/mobile → apps/rc`. Internal pubspec names unchanged.
- Repo renamed `obsbot-control → open-obsbot-remote`.

### Fixed
- **Auth gate** — unauthenticated WebSocket clients no longer receive `state` broadcasts or subscribe snapshots before pairing.
- **Zoom validation** — zoom commands now use the camera-reported range instead of accepting a hardcoded 1.0-4.0 range.
- **Preview exposure** — removed the stale unauthenticated Crow MJPEG route; preview is served only by the token-gated MJPEG server on `ws_port + 1`.
- **Static web assets** — bridge now serves five-segment Flutter asset paths such as `assets/packages/cupertino_icons/assets/CupertinoIcons.ttf`.
- **Bridge restarts** — reset-pairing and camera-permission retry now wait for the subprocess to exit before starting it again.
- **Control commands** — recenter, preset recall, and sequence steps release AI tracking before moving the gimbal; direct zoom uses the reliable speed-aware SDK call.
- **Auth persistence** — `auth.json` is chmodded to user-only permissions after writes.

## [0.3.1] - 2026-05-02

### Added
- **Move-speed presets** (Instant / Slow / Medium / Fast). Each `preset.recall` and each sequencer step honors a per-call speed via `gimbalSetSpeedPositionR`. Speed selector lives in the app bar of both Simple and Advanced modes; saved per-app in `shared_preferences`.
- **Three sequence loop modes**: `once`, `forward`, `ping_pong` (P1→P2→P3→P2→P1→…). Bridge tracks `seq_direction_` flag.
- **Mid-sequence edit** semantics — `sequence.set` while running clamps current index to new list bounds, applies at next step boundary; if the list becomes empty the sequence stops.
- **Cache-clear menu** in mobile/web (PinEntry + Simple + Advanced) — wipes shared_preferences, unregisters service worker, clears Cache Storage, hard-reloads.
- **Hide/Show PIN+QR** on bridge UI; auto-hides 60 s after Reveal.
- **URL printed under QR** + Copy URL button (in case scan is slow).
- **Single-instance enforcement** for the .app: `LSMultipleInstancesProhibited`, AppDelegate self-quit if a sibling exists, `applicationShouldHandleReopen` raises existing window.
- **SIGPIPE ignored** in bridge — phone disconnects no longer kill the bridge.
- **Auto-restart** in supervisor (5 attempts, quadratic backoff) for unexpected subprocess exit.
- **`_killStalePortsHolders`** in supervisor frees ports 8765/8766 before spawning a new subprocess.
- Bridge wraps MJPEG / WS startup in try/catch — port-busy or bind failure logs + continues instead of crashing.

### Fixed
- **Pair race**: `pair()` was cancelling + re-listening on the WebSocket stream and missing the ack. Now uses a Completer + msg-id matched in the always-on subscription.
- **Sequencer text field**: stable `TextEditingController` per step so cursor + focus aren't destroyed on parent rebuild.
- **Zoom range**: Tiny 2 Lite max is 2.0× not 4.0×; out-of-range commands silently clamped, looking broken. Bridge picks max per `productType()`, snaps `snap_.zoom` immediately on set so phone UI feels instant.
- **`cameraSetZoomWithSpeedAbsoluteR`** preferred over `cameraSetZoomAbsoluteR` (vendor sample path).

## [0.3.0] - 2026-05-02

### Added
- **PIN-paired auth** — 6-digit PIN displayed in bridge UI; phone enters once, gets 32-byte hex bearer token. Token gates all WS actions and MJPEG GETs. Persisted in `~/Library/Application Support/Open OBSBOT Bridge/auth.json`.
- **Simple mode** UI on phone: preview big + 2×3 preset grid + active-preset highlight + sequencer overlay bar.
- **Sequencer** backend on bridge: dedicated thread, persisted at `sequence.json`, broadcast as `state.sequence.{running,step_index,elapsed_s,total_s,mode}`.
- **Sequencer UI** on phone: drag-reorder steps, +/- step, per-step duration + speed, Start/Stop, live progress.
- **Active-preset tracking**: `snap_.active_preset_id` set on `preset.recall`/save, cleared on any manual PTZ.
- **Preset list** fetched from camera via `aiGetGimbalPresetListR` on connect — UI shows actual saved names.
- **MJPEG quality bump** to 20 fps, q=0.55.

## [0.2.0] - 2026-05-01

### Added
- **Web client** — Flutter web bundle served by the bridge from `/`. Phones use any browser, no install. Auto-detects bridge host from `window.location` so user doesn't retype IP.
- **Static file serving** in bridge (Crow routes for nested asset paths).
- **MJPEG server** standalone on port 8766 — Crow can't stream multipart, so we hand-rolled a BSD-socket server.
- **CORS** on MJPEG endpoint so cross-origin browser fetches work.
- **Web preview** uses `HtmlElementView` + `<img>` (browsers natively render multipart) with conditional import; native uses `flutter_mjpeg`.

## [0.1.0] - 2026-05-01

Initial demo working end-to-end on a Tiny 2 Lite.

### Added
- C++ bridge (`bridge_cpp`) linking libdev for camera control + AVFoundation for UVC capture.
- WebSocket protocol on `:8765/v1` carrying JSON commands.
- MJPEG preview on `:8765/preview.mjpeg` (later moved to `:8766` for streaming).
- Flutter `bridge_mac` app supervising the C++ subprocess.
- Flutter `mobile` app: PTZ pad, zoom slider, 4 hardcoded preset slots, AI mode toggle, HDR/FOV/image sliders, sleep/wake.
- Bundle layout, ad-hoc signing, build-bridge-mac.sh script.
- Logs persist at `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.
- Camera permission wired through Info.plist + entitlements; first-launch prompt under "OBSBOT Bridge" name.
