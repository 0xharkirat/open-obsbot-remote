# Changelog

All notable changes to Open OBSBOT Control. Format: [Keep a Changelog](https://keepachangelog.com/), versioning per [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **Saved sequence library** — name + persist sequences, switch between them via dropdown. Bridge stores them at `~/Library/Application Support/Open OBSBOT Bridge/sequences.json`. New WS actions `sequence.save_as / sequence.load / sequence.delete`. State event ships `sequence.available` + `sequence.loaded`.
- **AGENTS.md** symlink to CLAUDE.md so non-Claude AI tools find the same guidance.
- **CHANGELOG.md** (this file).
- **CONTRIBUTING.md**, **CODE_OF_CONDUCT.md**, **docs/ROADMAP.md**, GitHub issue + PR templates.

### Changed
- Folder rename: `apps/bridge_mac → apps/bridge`, `apps/mobile → apps/rc`. Internal pubspec names unchanged.

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

[Unreleased]: https://github.com/0xharkirat/obsbot-control/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/0xharkirat/obsbot-control/compare/v0.3...v0.3.1
[0.3.0]: https://github.com/0xharkirat/obsbot-control/compare/v0.2...v0.3
[0.2.0]: https://github.com/0xharkirat/obsbot-control/compare/v0.1...v0.2
[0.1.0]: https://github.com/0xharkirat/obsbot-control/releases/tag/demo-v0.1
