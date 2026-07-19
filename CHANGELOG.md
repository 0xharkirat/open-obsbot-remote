# Changelog

All notable changes to Open OBSBOT Bridge and Open OBSBOT Remote. Format: [Keep a Changelog](https://keepachangelog.com/), versioning per [SemVer](https://semver.org/).

## [Unreleased]

## [2.5.0] - 2026-07-19

The live-stream hardening release, plus the mix rework and any-camera sources.
Driven by two real multi-hour services: every stream-stability failure they surfaced is root-caused and fixed here.

### Fixed

- The MJPEG stream no longer freezes after exactly 2 hours. The serving loop had a hard 2-hour deadline per connection; OBS's Browser Source never reconnects on stream end, so a long service hit a frozen frame that needed a manual source refresh. Streams now live as long as the client holds the connection.
- The stream now delivers the camera's full frame rate. The serving loop slept 50 ms after every frame (a hard ~20 fps ceiling) and every frame was JPEG-encoded in software through Core Image (~54 ms at 1080p, ~80% CPU). Frames are now encoded by VideoToolbox straight off the capture buffer and sent the moment they arrive: camera-rate delivery at roughly 13% bridge CPU.
- One canonical program format. Every source is scaled (letterboxed if needed) to 1920x1080 at capture time, so `active.mjpg` never changes dimensions mid-stream - a dimension change made OBS re-init its decoder, which showed as a white flash and abrupt cut on every fade involving a differently-sized camera.
- The bridge Settings sheet is native macOS now (MacosSheet + MacosSwitch, quick fade instead of the scale-pop), and the last Material island in the shell is gone.

### Added

- Mix sequencer 2.1: author SHOTS, the bridge derives the cameras. Crossfades force consecutive cues onto different cameras (graph 2-colouring); an odd forward loop with 2 cameras sacrifices exactly one transition as a slow on-air pan, chosen where the pan is shortest; disabling a cue re-links the sequence around it; per-cue crossfade lengths; saved sequences carry no serial numbers, so they are portable between rigs (pre-2.1 files run verbatim as fully pinned).
- Any camera as a source. Add the Mac's built-in camera, a phone-camera app, or any UVC device as a session-less video source: preview it, TAKE it on air, crossfade with the PTZ cameras. Sources persist across restarts and survive unplug/replug. No PTZ/preset/image controls, by construction.
- Continuous zoom rocker (T/W hold keys) at a smooth 0.25x/s, driven through the motion planner because the SDK's own continuous-zoom routes latch and cannot stop on this camera. The zoom slider commands on a 0.05x grid so the readout no longer drifts a hundredth after release.
- Desktop remote. 'Open OBSBOT Remote' builds and runs on macOS - including on the bridge machine itself. On any surface 900px or wider (Mac window, iPad landscape, desktop browser) the Live screen becomes a desk: PREVIEW and PROGRAM panes side by side, camera bus, and a control rail with transition cluster, presets, and framing all visible at once.
- One-scan pairing. The bridge QR now encodes a connection link with the PIN in the URL fragment: a phone browser opens the web remote already paired, the phone app's new Scan QR button connects and pairs in one step, and desktops use the new Copy link / Paste link buttons.
- The remote holds a wake lock while open - the operator's screen no longer dims or locks mid-service.
- Android release signing: the phone app now builds as a Play-Store-ready signed APK/AAB.

### Known limits

- The venue checklist for this release is issues #56 and #57: two-camera load, solver behaviour with real cameras, and physical unplug/replug of generic sources.

## [2.0.1] - 2026-07-18

Patch release driven by the first real multi-camera live streams. Update the bridge on any machine running 2.0.0.

### Added

- Preset glide speed. A Glide selector (Instant / 1s / 2s / 5s) above the preset grid controls how long a tapped preset takes to move the camera; the v3 redesign had left recall stuck at a fixed 2 seconds.
- Crossfade length. A picker (0.3s - 2s) next to the crossfade toggle controls how slow a manual TAKE dissolves; it was hardwired to 500 ms.

### Fixed

- Web assets are no longer served as `immutable`. Flutter tree-shakes the Material icon font to only the glyphs a given build uses, under a filename that never changes, so a phone holding a copy cached from an older build was missing the new codepoints and every icon rendered blank. Everything except `canvaskit/` (which changes only on a Flutter SDK bump) is now served `no-cache`. Note: a phone already showing blank icons cannot be fixed from the server, because `immutable` means the browser never revalidates - clear that site's data once.
- The mix sequencer's Hold field no longer closes the on-screen keyboard on every keystroke. It pushed a `mix.set` per character, and the state-event echo of an earlier keystroke disposed the text field mid-typing. The push is now debounced.
- The preview streams at capture resolution (1080p) instead of being downscaled to 720p, and JPEG quality went from 0.80 to 0.85, so the OBS feed no longer looks soft.
- Dragging the zoom slider no longer stutters the lens (mid-drag commands are throttled to one per 160 ms) and the thumb no longer jumps back after release; the released value holds until the camera's reported zoom converges on it.

## [2.0.0] - 2026-07-12

Multi-camera release.
One bridge now drives several OBSBOT cameras at once, the phone and browser remote is rebuilt around a single Live switcher screen, and a bridge-level engine runs cross-camera mix sequences.
OBS still reads one Browser Source; camera switching happens in the bridge, not in OBS scenes.

### Added

- Multi-camera control. One `DeviceManager` owns N `DeviceSession`s keyed by serial number. Bridge state is a `BridgeState` envelope on the `event: "state"` message, carrying `devices[]`, `active_device_id`, and a `mix` block.
- Live switcher screen in the remote. Selection (which camera the phone drives) and on-air (which camera `active.mjpg` and OBS follow) are separate. TAKE commits the change.
- Crossfade transition. A TAKE with a non-zero fade dissolves the outgoing camera into the incoming one, baked into `active.mjpg` so OBS needs no scene changes. The first take, with no outgoing frame captured yet, falls back to a fade from black.
- Cross-camera mix sequencer. A bridge-level engine runs timed cues that switch and move across cameras, persisted to `mix.json` and `mix_sequences.json`. A live camera keeps moving while on air by design; there is no on-air movement lock.
- PTZ precision engine. Tap is an absolute nudge, hold is a ramped glide, the joystick uses a squared response curve, and release double-stops behind a bridge watchdog. Tuning lives in `apps/rc/lib/ptz_tuning.dart`.
- Sequence library export and import, via the `library.export` and `library.import` actions and a Settings section in the remote.
- Client packages `obsbot_api_client`, `bridge_repository`, `device_repository`, and `auth_repository`, over the shared `obsbot_protocol` wire types.
- Multi-camera deck in the Mac bridge window, driven by a local WebSocket client.
- Copyable OBS Browser Source URL in the bridge window.

### Changed

- The remote is Material 3 only. forui is retired.
- Camera auto-sleep is disabled on connect via `cameraSetSuspendTimeU(0)`, and a capture left stranded by a sleep is restarted on wake. This fixes a camera that slept and then showed a dead preview and OBS feed after waking while the other camera kept working.

### Removed

- The Drive / Image / More tab layout and Simple mode, replaced by the single Live screen.

### Fixed

- Three deadlocks and crashes found on the first live two-camera run.
- `notifyListeners()` firing after dispose in the remote's WebSocket client.
- A per-serial preview stream now ends when its camera detaches.
- A late camera-permission grant now retries the capture instead of leaving the preview blank.

## [1.5.2] - 2026-07-10

Release artifact switched from a ZIP to a universal DMG (arm64 and x86_64) installed through a Homebrew cask (`brew install --cask 0xharkirat/tap/open-obsbot-bridge`), which clears the Gatekeeper quarantine at install time.
Same code as 1.5.1; the bump is release metadata only. See PR #30.

## [1.5.1] - 2026-05-18

3-flat-tab restore, Image-tab theme and latency fix, sequencer Update versus Save-as-new, bridge web-root walk-up, and UI polish. See PR #28.

## [1.5.0] - 2026-05-18

Sequencer UX overhaul, phone-nav consistency, FButton-primary brand-red
fix (cosmetic regression since v1.2.1), attitude indicator HUD-green +
clamping, and a Playwright mobile-e2e harness. Five worktree branches
(W1-W5) merged into `feat/v1.5-major`. Plus a documented known-edge:
60s/20° gimbal plans undershoot on Tiny 2 Lite (motor floor).

### Added

- **Playwright mobile e2e harness** (W5). `tests/playwright/` covers
  iPhone 15 Pro (393×852) + Samsung Galaxy S22 (360×780) viewports.
  Smoke: page load, pair (auto-skip when no bridge), tab swap, image
  toggles. Run via `cd tests/playwright && npx playwright test`. Docs
  at `docs/PLAYWRIGHT.md`. Skips cleanly when port 8765 isn't
  listening.
- **Sequence progress shows moving phase + remaining time** (W1).
  New `widgets/sequence_progress_bar.dart` reads `sequence.phase`
  (added in v1.4 W3) and interpolates a per-phase progress fill:
  during `moving` against the planner's `transition_ms`, during
  `holding` against `step.seconds`. Label switches between
  "Moving to P3..." and "P3 - 38s left". Wired into tab strip,
  sequencer running banner, simple-mode preview banner.
- **Running-sequence highlight in the library dropdown** (W1).
  When a saved sequence is currently executing, the dropdown
  pre-selects its name + shows a "Running" chip.
- **Bookmark + Start split** (W1). Footer is now
  `[+ Add step] [Start/Stop] [Apply (in-flight only)] [bookmark icon]`.
  Bookmark prompts for a name and persists via `sequenceSaveAs`.
  Start no longer implicitly persists - scratch sequences stay
  scratch unless the user explicitly bookmarks.
- **Sequencer Add-step visual feedback** (W1). 300 ms button
  debounce prevents accidental double-add. New card scrolls into
  view via `Scrollable.ensureVisible` and pulses a
  primaryContainer border for 600 ms so the user can see what
  just happened.
- **`OverflowMenu` (3-dot) on both phone screens** (W2). Simple +
  advanced both expose the same destructive-action menu:
  Disconnect + Clear cache. Removes per-screen icon-row drift.

### Fixed

- **FButton-primary rendered near-white since v1.2.1** (W3).
  `FThemes.zinc.dark.colors.primary` is `#E4E4E7` by design (shadcn
  "inverted primary" convention for dark themes). Every
  `FButtonVariant.primary` call site - `_toggleBtn` ON state,
  `ForSegmented` selected pill, AI sub-mode pills - has been
  rendering as a near-white slab instead of OBSBOT red. The Image
  tab made it visible (two ON face buttons next to two OFF
  outline buttons). Fix: override the forui primary in
  `tab_shell.dart`'s `FTheme` to `#FF3B30` (OBSBOT brand), white
  foreground. One-field swap; no per-button changes. Regression
  test added.
- **Attitude indicator HUD-green + clamps to preview bounds** (W4).
  `grid_overlay.dart::_paintAttitude` now strokes the moving
  cross + ring in `#00FF66` with a dark `#003314` shadow under
  for legibility on washed-out frames. Off-screen positions
  clamp to `[14, w-14] x [14, h-14]` and draw a small heading
  arrow 20 px beyond the clamp pointing along world-axes (canvas
  space, so roll doesn't tip the arrow off-axis). Operator always
  sees which way to pan back.
- **8-way buttons is the default control style** (W2). New users
  land on discrete buttons (`_driveControlStyle = 'buttons'` in
  `ws_client.dart`); joystick reserved for users who pick it.
  Persisted choice still honoured for existing users.
- **Sequence library dropdown crashes on `sequenceDelete`** (W1).
  DropdownButton threw when its `value` was no longer in `items`
  after a delete; added `lib.contains(loadedName)` guard.
- **Simple-mode AppBar consistency** (W2). Sequence icon now
  matches advanced-mode (`Icons.timeline`); old timer glyph
  retired. Disconnect + Cache moved into the new overflow menu.
- **Sequencer density** (W1). Step card padding tightened across
  the board (`vertical: 12 -> 8`, drag handle `8 -> 4`, etc).
  Loop-mode radios collapsed into a `SegmentedButton<LoopMode>`
  `[Once | Loop | Ping-pong]`. Verbose `(P1->P2->P3->P1...)`
  subtitles dropped.

### Known limits

- **60s / 20° gimbal plans undershoot on Tiny 2 Lite.** Rate is
  0.33°/s = below the motor's reliable per-tick floor at our
  current 100 ms tick + ease_in_out_sine. `tests/slow_motion.mjs`
  60s-plan assertion fails consistently. The motor still moves -
  just slower than the test expects. Users who pick "1 min"
  duration for a recall are pushing the hardware boundary; "30 s"
  works fine. Will need a different motion strategy (single
  velocity command + monitor instead of waypoint ticks) to truly
  fix - deferred.

## [1.4.1] - 2026-05-18

Bridge UI polish on v1.4.0. Two worktree branches (W1 + W2) plus
small visual fixes after live screenshot review.

### Added

- **Bridge HomeScreen rewritten with `macos_ui` widgets** (W1).
  `MacosScaffold` + `ToolBar` + native-shaped status group card.
  Hero status banner, sectioned Status + Pairing + Bridge log.
  Reads as a Mac app, not a debug console.
- **App logo in the toolbar title.** 22 px rounded OBSBOT icon
  next to the "OBSBOT Bridge" text.
- **`informational: true` flag on the status row helper.** Swaps
  the leading dot for an info-circle icon. Used on the firewall
  row because we can't measure firewall state from a
  non-privileged app - the row is a hint, not a status.

### Fixed

- **Tray menu simplified** (W2). 12 items collapsed to 6: single
  live status line, clickable PIN row with `⌘C`, Show main window
  (`⌘O`), Open log file, Quit (`⌘Q`). Dropped version line,
  separate clients row, "Copy PIN to clipboard", "Show PIN + QR",
  "Restart bridge subprocess".
- **Camera-connected status reflects AVFoundation, not just libdev**
  (W2). On a hot-replug, libdev sometimes misses the plug event
  and `snap_.connected` sticks at false even though AVFoundation
  grabbed the camera. `cameraConnected` now returns
  `_cameraConnected || _videoRunning`; the `_videoRunning` flag
  is parsed from the bridge log's `video: capture session started`
  line. `detectedModel` falls back to the log's
  `using device '<name>'` string.
- **Em dashes (`—`) stripped repo-wide.** ~80 instances across
  Dart, Swift, C++, Markdown, shell. CLAUDE.md has had the
  "plain hyphen surrounded by spaces" rule since v1.1; v1.4.1
  finally enforces it.
- **Action-button padding bumped** from `ControlSize.small` to
  `ControlSize.regular` on the firewall row "Open Firewall
  Settings", camera permission row "Open Settings" + "Reset &
  retry", and pairing "Reset pairing" buttons.
- **Firewall deep-link targets Network pane on macOS Sonoma+.**
  Legacy URL `com.apple.preference.security?Firewall` silently
  dropped the `?Firewall` fragment on modern macOS and landed
  on Privacy & Security root. Now opens
  `com.apple.Network-Settings.extension` first, falls back to
  the legacy URL for older macOS.
- **Settings dialog About footer collapsed to one inline GitHub
  link.** The trio of link buttons overflowed past the
  AlertDialog's Close button. Replaced with `by Hark Singh with
  OBSBOT SDK + Flutter [↗ GitHub]`.
- **Firewall row moved to last position in Status group**, since
  it's a hint not a measurement.
- **Bridge log "Reveal" button says "Open"** (it opens the file in
  Console, not reveals a Finder folder).

## [1.4.0] - 2026-05-18

Big release. Skips v1.3 (the in-flight v1.3-polish PR was rolled
into v1.4). Driven by live-stream feedback from the prior weekend:
the preview was dropping mid-stream, the pairing screen was leaking
server protocol text into a red warning, the sequencer was eating
its own stay-time during long moves, and the phone app's advanced
mode was overdue for the OBSBOT Center-shaped redesign so it can
read as "production ready" rather than a developer console.

Shipped via 6 parallel worktree branches (W1–W6) merged into
`feat/v1.4-major`. Each branch was bisectable in isolation so any
regression can be reverted without unwinding the whole release.

### Added

- **Drive / Image / More tab structure (W6).** Phone app's advanced
  mode is now three top-level pages inspired by OBSBOT Center:
  - **Drive**  -  sticky `_QuickActions` row + collapsible sections:
    Presets (6 cards), View & Gimbal (joystick + zoom slider + FOV
    pills + Reset), Move pacing (duration chips), AI tracking
    (mode pills + sub-mode pills).
  - **Image**  -  every group (Tone / Exposure / Anti-flicker / WB /
    Color) wrapped in a `CollapsibleSection`, persisted open state
    via SharedPreferences key `section_<id>_open`.
  - **More**  -  Device info, Sequence library, Grid overlay toggles,
    Connection (URL + Disconnect + Reset cache), About panel.
  - Folds the previous Joystick + Buttons tabs into Drive with a
    "Control style" toggle (joystick vs 8-way pad).
- **AI sub-mode picker.** 5 pills (Normal / Upper-body / Close-up /
  Headless / Lower-body) on Drive's AI section, wired to the
  existing `client.aiSetMode(mode, subMode)`  -  bridge already
  accepted the sub-mode arg but the phone UI hardcoded `'normal'`.
- **`image.refresh`-style affordance per section.** `CollapsibleSection`
  has an optional `onRefresh` slot; ready for per-section refresh
  icons on Exposure / WB (visual parity with OBSBOT Center).
- **Preset long-press bottom sheet (W4).** Saved presets now open a
  4-item sheet on long-press: Update with current pose, Recall
  instantly (`Duration.zero` regardless of default), Rename, Delete.
  Empty slots keep the one-step save flow.
- **Sequencer step UI splits move and stay (W5).** Each step row now
  renders two labelled fields ("Move to P_X over [chip]" + "Stay
  for [N] seconds") plus a trailing "≈N s total" caption.
- **`sequence.phase` state-event field (W3).** Bridge reports
  `phase: "moving"` while the MotionPlanner is in flight and
  `"holding"` while the stay-timer counts. Defaults to `"holding"`
  for instant transitions + idle. Client surfaces ready for a
  per-phase progress affordance.
- **`MotionPlanner.motion_wait_idle(timeout_ms)` (W3).** Public
  blocking wait on the planner-completion condition variable.
  Required by the sequencer fix; useful elsewhere (tests, future
  chained commands).
- **Dev-only bundle identifier `com.harksingh.obsbotbridge.dev`.**
  Debug builds claim a distinct macOS TCC + Launch Services slot
  from prod, so the two coexist without clobbering each other's
  camera permission. `scripts/dev-resign.sh` re-signs the
  subprocess to match.
- **Tests.** New widget tests for `CollapsibleSection` (8),
  sequencer step UI (4), preset long-press sheet (5). New backend
  test `tests/sequence_timing.mjs` (4 cases) covers the W3 race +
  phase transitions + stop-mid-move. Totals: **125 across the
  three test surfaces** (64 backend + 45 widget + 16 protocol).

### Fixed

- **MJPEG preview "stops mid-stream" silent disconnect (W2).** Bridge
  accepted client sockets with no `SO_KEEPALIVE`, no `SO_SNDTIMEO`,
  no per-socket `SO_NOSIGPIPE`. When Wi-Fi roamed / phone
  backgrounded / NAT dropped state, the kernel send-queue filled,
  `send()` blocked indefinitely (macOS default TCP retransmit
  ~15 min), and the serving thread + its fd were stuck.
  Client saw a freeze with no browser error and no bridge crash.
  Log evidence: 145 `client connected` vs 104 `client disconnected`
  before the fix  -  41 missing disconnects. After the fix
  (`setsockopt SO_KEEPALIVE + SO_SNDTIMEO 5s + SO_NOSIGPIPE`),
  any wedged write fails fast → the existing loop-exit path logs
  the disconnect → thread + fd self-recycle. Suspects #3 and #4
  from the audit are still open but no longer mask #1.
- **Sequencer overlapped move-timer with stay-timer (W3).** v1.2's
  loop reset `step_started` immediately after dispatching the
  `motion_start` and only used `seconds` as the budget. User-
  observed: `seconds=40, transition_ms=30000` → only ~10 s of
  actual hold. Fix chains `trigger_step → motion_wait_idle(transition_ms + 500)
  → reset step_started`. Stay timer now starts AFTER the move
  completes. `cmd_sequence_stop` also calls `motion_cancel()`
  before joining so stopping mid-move releases the planner
  promptly.
- **Pairing screen leaked server protocol hint (W1 A2).** On
  `auth_required` the Dart side stored the server's developer-
  facing `j['msg']` ("send {action:'pair', pin:<6-digit>} or
  {action:'hello', token:...}") into `_lastAuthError`, which the
  pair screen rendered as a destructive-coloured label under the
  PIN field. Now sets `_lastAuthError = null`  -  entering the pair
  screen is a state transition, not an error.
- **Wrong PIN UX polish (W1 A3).** Field re-focuses after a clear
  (FocusNode added) so the mobile keyboard re-arms. Dropped the
  duplicate SnackBar (the inline red label already says it).
  Friendlier copy: "That PIN didn't match. Check the bridge
  window and try again."
- **Bridge permission-denied label wrapped + distorted UI (W1 D1).**
  Camera permission row, firewall row, and log path display all
  carry long strings. Added `maxLines: 1` + `TextOverflow.ellipsis`
  to each. Log path also wrapped in `Flexible` so ellipsis
  triggers before the Reveal button gets pushed off-row.
- **Preset bookmark overwrite-in-place undiscoverable (W4 B1).**
  Bridge always upserted by id; UI only said "Saved P1 at current
  position", same copy for first-save and overwrite. Long-press
  now opens an explicit "Update P1 with current pose" sheet item.
  Snackbar copy switches to "Updated P1 with current pose" when
  overwriting an existing entry. Simple Mode preset tiles share
  the same sheet (extracted to `widgets/preset_options_sheet.dart`).

### Changed

- **Phone app advanced-mode top tabs renamed.** Joystick / Buttons
  / Image → Drive / Image / More. Tests updated accordingly.
- **Auto-track section moves from Image to Drive.** It's a framing
  control, not an image control. AI mode + sub-mode pills live
  together.
- **FOV (Wide / Normal / Narrow) moves from Image to Drive's View
  & Gimbal section.** Same reasoning  -  framing not image.
- **CollapsibleSection persists per-section open state** via
  SharedPreferences key `section_<id>_open`. Defaults to open.
- **`_InlinePresetCard` label updated** from "tap recall  -  hold to
  save" to "tap recall  -  hold for options" to advertise the new
  bottom sheet.
- **Sequencer step row layout** now stacked: header → preset
  dropdown → Move-to row → Stay row → ≈ total caption. Wire
  format unchanged (`{preset_id, seconds, transition_ms}`).

### Removed

- **AI tracking section duplicated on Image tab.** It lived in both
  places during the redesign; consolidated to Drive only.

### Notes

- `IconToggleRow` and `LabeledSlider` widgets are built and tested
  but not yet wired into the Image tab body. v1.5 follow-up.
- Hue slider + Snapshot button  -  `WsClient.imageSnapshot()` stub
  exists; needs bridge action + UI button. v1.5 follow-up.

## [1.2.1] - 2026-05-13

Maintenance + polish release on top of v1.2.0. Highlights: replaced
the fragile `tray_manager` macOS plugin with a first-party
NSStatusItem implementation; brought the bridge UX in line with
Handy (cjpais/Handy)  -  dock icon follows the main window
automatically, tray carries the pairing PIN inline; smoothed out
preset-recall motion + zoom; made the camera permission grant
survive rebuilds.

### Added

- **First-party macOS NSStatusItem tray (`NativeTray.swift`).** Replaces
  `tray_manager` 0.5.2  -  its `popUpContextMenu` plumbing dropped
  NSMenu's target/action dispatch on macOS Sonoma+, so menu clicks
  rendered fine but never fired the Dart handler. Net effect: Quit /
  Show main window / Reveal PIN / Copy PIN were no-ops. New impl
  attaches the NSMenu permanently to the status item and routes
  clicks through `@objc menuItemClicked:` straight to the
  `obsbot.bridge/tray` channel  -  rock-solid.
- **Hybrid dock-visibility (Handy-style).** The dock icon now tracks
  the main window: closing the window flips activation policy to
  `.accessory` (no dock icon), showing it flips back to `.regular`.
  No persistent "hide dock" setting needed  -  the dock just goes
  where the user is looking. Pattern lifted from cjpais/Handy.
  Per-user toggle "Start hidden in menubar" persists across launches
  (replaces the old `bridge_menubar_only` key; migrated on first run).
  Onboarding override: even with start-hidden on, the bridge force-
  shows the window until at least one phone is paired, so the user
  can see the PIN.
- **Tray pairing PIN inline.** Tray now shows
  `Pairing PIN:  ######` directly, plus a `Copy PIN to clipboard`
  item  -  the most-used info is one click away (Tailscale / Dropbox
  pattern). Version line at the top of the tray menu too.
- **Stable subprocess code signature.** `build-bridge-mac.sh` now
  re-signs `obsbot-bridge` with the stable identifier
  `com.harksingh.obsbotbridge.helper` after the `--deep` parent sign
  (which otherwise stamps it as `obsbot-bridge-<contenthash>`  - 
  changes every rebuild, invalidates the camera TCC grant). One-time
  Allow click now persists across rebuilds.
- **Menubar-only mode (macOS).** Optional setting in the bridge's Settings
  dialog: "Start hidden in menubar". When enabled, the bridge
  launches without a dock icon and the main window stays hidden until
  the user picks "Show main window" from the tray. AppDelegate reads
  the persisted preference via NSUserDefaults before the Flutter
  engine boots so the dock icon never flickers on launch. Restart
  required to apply.
- **`image.refresh` action.** Bridge re-reads live exposure_mode,
  ev_bias, anti_flicker, wb_type+kelvin from the camera via the SDK
  getters and stamps its snapshot, which flows out to every connected
  phone as a normal state event. Useful when OBSBOT Center or another
  phone changed those values out-of-band  -  without it our cached state
  was stale and the user had no way to resync without reconnecting.
- **"Refresh from camera" button** on the Image tab (top-right). One
  tap, brief toast confirms the resync.
- **Narrow-width overflow regression test.** `tab_shell_test.dart`
  pumps the TabShell at 320 px (narrowest realistic phone) and asserts
  no `RenderFlex` overflow errors fire while the three quick-action
  buttons are visible. Locks in the fix; future regressions surface
  in CI.

### Changed

- **Exposure mode + EV bias no longer reported as "unsupported".**
  Empirical probe (`tests/exposure_probe.mjs`) on Tiny 2 Lite firmware
  6.2.8.1 showed every variant of `cameraSetExposureModeR` and
  `cameraSetAAEEvBiasR` returns r=0. The SDK header's "tail air" tag
  was misleading; the bridge no longer guards these calls behind the
  unsupported branch. UI disclaimer line on the Image tab is gone.
- **forui migration extended into tab content.** PR Q migrates two
  high-traffic surfaces from Material to forui:
  - `_QuickActions` (the Recenter / Sleep / Wake row at the top of
    the Joystick + Buttons tabs)  -  3-per-row `OutlinedButton` →
    `FButton.raw` with `variant: FButtonVariant.outline`. Each
    button's child is a Flexible+Text with `maxLines: 1` +
    `TextOverflow.ellipsis` to structurally prevent the 360 px
    overflow we shipped before the v1.2 fix.
  - `_toggleBtn` (HDR / Face exposure / Face focus / Flip / Auto WB
    pair-row toggles on the Image tab)  -  `FilledButton` with
    hand-rolled `colorScheme` overrides → `FButton.raw` with
    `variant: on ? FButtonVariant.primary : FButtonVariant.outline`.
    On-state now uses the brand red consistently from the forui
    theme instead of duplicating the color logic per call site.
- **Segmented controls + sliders** intentionally stay on Material for
  this PR; the migration is mechanical but high-volume and benefits
  from a separate PR with its own test pass.

### Fixed

- **Motion planner: jittery preset recall on any duration > 0.**
  v1.2 sent `gimbalSetSpeedPositionR(.., speed=90)` every 100 ms tick
   -  motor raced to each tick target inside the window, waited, raced
  again. Visible 100 ms-cadence stutter on every 1 s+ move. Live
  report: "anything starting from 1 second time difference to change
  preset is so shaky." Fix: rate-scale the SDK speed parameter to
  match the per-tick deg/s, headroom 2.0×, floor 15%. Motor now
  flows continuously through the eased curve.
- **Motion planner: zoom oscillation on preset recalls with zoom
  delta.** v1.2 ticked `cameraSetZoomAbsoluteR` every 100 ms, which
  re-armed the lens motor's internal plan on every call → visible
  in/out/in/out on any preset combining motion + zoom delta. Live
  report: "preset p4 has movement and zoom to 2x and if I switch
  from p3 to p4, the zoom gets in, out, in, out". Hybrid fix: short
  zooms (≤1 s) one-shot the target; longer zooms tick at ≥600 ms
  cadence so the lens converges per waypoint without re-arming.
  Duration_ms is now honoured for both branches.
- **Inline preset card: tap saved instead of recalled.** `_saved`
  required a non-empty preset name; unnamed saves fell through to
  the empty-slot branch and tap-to-recall silently became
  tap-to-save. Now `_saved` is true on any entry regardless of
  name. Live report: "if I tap or hold, it saves the preset  -  tap
  should be to change to that preset."
- **applicationShouldTerminateAfterLastWindowClosed now returns false.**
  Before, closing the window in any mode could trigger an
  auto-terminate. With the tray owning the bridge lifecycle (Quit
  via tray, red-dot just hides), false is the correct answer. Also
  required for menubar-only mode  -  the hidden launch window was being
  misread as "last window closed" and the app died instantly.
- **Camera permission lost on every rebuild.** Subprocess code
  signature was `obsbot-bridge-<contenthash>`  -  every build a new
  identifier, every build macOS TCC treated it as a new app and
  threw away the camera grant. Pinned to stable
  `com.harksingh.obsbotbridge.helper` in `build-bridge-mac.sh`.
- **`tests/exposure.mjs` had `allowUnsupported: true` masking real
  failures.** Now expects `ok=true` for exposure_mode + ev_bias and
  asserts the state-event reflects the requested value (with 1/3-stop
  snap tolerance). 4 new tests + 1 refresh test, 11/11 pass.

### Removed

- `velocityScale` field on `WsClient` (plus its `velocity_scale`
  SharedPreferences key and the v1.2 `PtzPad` multiplier). The
  user-facing speed slider was dropped during the v1.2 review pass.
  The field hung around defaulting to 1.0; removing it simplifies
  the PTZ math back to "joystick deflection magnitude = analog
  speed".

## [1.2.0] - 2026-05-12

Real-world livestream feedback drove this round. The big themes: redesign
the advanced UI around three consistent tabs, expose every camera-image
control inside the app (so the user never needs OBSBOT Center for daily
operation), and make the bridge a "set and forget" macOS app via a tray
menubar.

### Added

- **Advanced mode UI redesign.** Three tabs below a pinned live preview:
  Joystick, Buttons, Image. Same template on Joystick and Buttons so
  muscle memory carries between them: quick actions row (Recenter /
  Sleep / Wake), gimbal control + vertical zoom slider, inline preset
  cards P1 to P6, and a duration chip strip at the bottom. Sequence
  editor moves to an AppBar action (timeline icon).
- **Move-duration chips.** Replaces the v1.1 `MoveSpeed` enum
  (Instant / Slow / Medium / Fast / Cinema). The chip strip lets the
  user pick any of Instant / 1 sec / 5 sec / 15 sec / 30 sec /
  1 min / 3 min / 5 min for every preset recall and slow-pan move.
  Bridge motion planner runs an ease-in-out-sine waypoint loop to
  reach the target over the chosen wall-clock duration.
- **Inline P1 to P6 preset row** on Joystick and Buttons tabs. Tap
  recalls with the current move duration; long-press opens
  Save / Recall instantly / Rename. The separate Presets tab is gone.
- **Live preview overlay.** Four independently toggled layers via a
  grid menu in the AppBar:
  - Center crosshair (small `+` showing where the camera is pointing).
  - Attitude indicator (a moving cross + ring showing where the
    camera's home position is in the current view. Translates with
    yaw / pitch, rotates with roll, like an aircraft attitude
    indicator. To re-center, steer the moving cross onto the static
    crosshair.)
  - Rule of thirds (dashed lines).
  - Live Pan / Tilt readout in the top-left corner with `PAN <-> X deg`
    / `TILT up-down Y deg` glyphs.
- **Exposure / Anti-flicker / White balance section** on the Image tab:
  - Auto / Manual exposure segmented (best-effort on Tiny 2 Lite; the
    SDK tags this as "tail air" only, the bridge attempts the call
    and the UI greys it out if the firmware returns unsupported).
  - EV bias slider (-2.0 to +2.0 EV in 1/6-stop steps) when in auto.
  - Anti-flicker: Off / 50 Hz / 60 Hz segmented.
  - Auto white balance toggle plus a manual Temperature slider
    (2800 to 6500 K) when auto is off.
- **Per-section Reset buttons** on the Image tab (View / Exposure /
  Anti-flicker / White balance / Color) plus an inline reset icon on
  every color slider. Greyed out when already at default. Mirrors the
  OBSBOT Center workflow.
- **macOS menubar tray** via `tray_manager`. Tray title carries a live
  status glyph (Running with camera / no camera / Stopped / Error).
  Menu items: Reveal pairing PIN, Show main window, Open log file,
  Restart bridge subprocess, Quit. Closing the main window hides it
  instead of quitting, so the bridge keeps running during a stream.
- **OBSBOT-brand red accent** (`#FF3B30`) on a near-black neutral
  surface (`#0F1115`). Replaces the v1.1 default Material blue.
- **First forui design-system migration.** The Pair screen now uses
  `FScaffold`, `FHeader.nested`, and `FButton` from the `forui`
  package, themed `FThemes.zinc.dark.touch`. The rest of the app
  keeps Material widgets; the two coexist via a thin Material shim
  for inputs that need a Material ancestor.
- **New bridge actions** in `docs/PROTOCOL.md`:
  - `image.set_exposure_mode` (auto / manual)
  - `image.set_ev_bias` (float -3.0 to +3.0, snapped to SDK enum)
  - `image.set_anti_flicker` (off / 50 / 60 / auto)
  - `image.set_wb_auto` (boolean)
  - `image.set_wb_temp` (kelvin 2800 to 6500, also disables auto)
- **New state event fields** under `image`: `exposure_mode`,
  `ev_bias`, `anti_flicker`, `wb_auto`, `wb_kelvin`. Plus
  `sequence.steps` so the editor can hydrate from a state event after
  reconnecting.
- **New test batteries** run against real Tiny 2 Lite:
  - `tests/exposure.mjs` (8 tests for the v1.2 image controls).
  - `tests/zoom_smoothness.mjs` (samples zoom over 5-second and
    30-second slow plans, flags any lens stall).
- **Widget tests** under `apps/rc/test/` for the new tab shell and
  pair screen. 20+1 / 21 pass; runs offline (no bridge needed) via
  `SharedPreferences.setMockInitialValues({})`.

### Changed

- **Zoom planner switched to the float-API.** The bridge previously
  used `cameraSetZoomWithSpeedAbsoluteR(uint32_t, uint32_t)` which is
  effectively broken on Tiny 2 Lite (gets stuck around 1.33x
  regardless of the speed param). Empirical probing on a live camera
  confirmed `cameraSetZoomAbsoluteR(float, -1)` produces smooth
  continuous motion. Slow-zoom plans (5 sec, 30 sec, etc.) are now
  visibly fluid instead of stepping.
- **`Yaw` and `Pitch` jargon dropped** for plain Pan and Tilt in the
  preview readout. Operators do not need to know the difference.
- **AppBar duration popup removed in advanced mode.** The chip strip
  at the bottom of every advanced tab already covers it. Simple mode
  keeps its own AppBar popup (no chips there).
- **Status chip bar removed** above the preview (yaw / pitch / zoom /
  AI / FOV). Every field has a clear home now: Pan / Tilt in the
  preview overlay, zoom next to the slider, AI on the Image tab's
  Auto-track segmented, FOV on the Image tab's View segmented, run
  status on the tray icon glyph. Frees about 40 px of vertical space
  for the live preview.
- **Image tab labels shortened** for clean rendering at 360 to 390 px
  phone widths: "Auto-expose for face" -> "Face exposure",
  "Focus on face" -> "Face focus", "Flip horizontal" -> "Flip",
  "Auto white balance" -> "Auto WB".

### Fixed

- **Slow zoom motion was choppy.** Live-test feedback: "movement now
  happens in discrete sets, not in one slow continuous set." Caused
  by the uint-API's integer-percent quantization plus the SDK speed
  param being ignored on Tiny 2 Lite. Switching to the float-API
  resolves both. Verified live: 1.0x -> 2.0x over 8 seconds samples
  as a smooth ease-in-out curve (1.00 / 1.04 / 1.09 / 1.17 / 1.26 /
  1.38 / 1.50 / 1.57 / 1.70 / 1.80 / 1.89 / 1.95 / 1.98 / 2.00) with
  no integer-percent steps.
- **Up / Down hold buttons sometimes did nothing on web.** The pre-fix
  `HoldDirBtn` wrapped a `Listener` inside a `FilledButton.tonal`.
  The button's internal `TapGestureRecognizer` won the gesture arena
  on quick taps, so the inner `Listener.onPointerUp` never fired and
  the velocity ticker stayed running. The rewrite uses a raw
  `Listener` on a `Material` surface so press / release / cancel are
  first-class.
- **Zoom slider mid-drag fought the planner.** ZoomSlider was sending
  the current chip-chosen duration on every drag tick. The planner
  cancelled and restarted every 100 ms, so the lens never made
  progress. Mid-drag is now always instant (`duration: Duration.zero`)
  so the lens follows the finger; the chosen duration is applied
  only on release.
- **"Recenter" label wrapped** to two lines at 360 to 390 px phone
  widths because `OutlinedButton.icon` plus the icon plus the label
  exceeded the slot. Replaced with a plain `OutlinedButton` plus a
  Tooltip.
- **Sequencer dropdown crashed on legacy values.** The Move duration
  dropdown asserted "exactly one item with value: 2000" when
  hydrating an existing sequence whose `transition_ms` was not one
  of the chip presets (e.g. 2000 ms from v1.1 default, 22000 ms from
  the legacy `cinema` mapping). The editor now snaps any incoming
  value to the nearest chip preset for display; the bridge still
  honors the raw saved value.

### Removed

- The Presets tab (presets are inlined on Joystick and Buttons).
- The Sequence tab (moves to an AppBar action with the timeline icon).
- The status chip bar above the preview (every field has a clearer
  home elsewhere).
- The advanced-mode AppBar Move-duration popup (chip strip covers it).

### Protocol changes

- All move commands accept `duration_ms` (`ptz.angle`, `zoom.set`,
  `preset.recall`). `0` is instant; a positive integer runs the
  bridge's motion planner.
- `zoom.set` accepts an optional `final` flag (terminal release value;
  bypasses the mid-drag coalesce).
- Sequence steps use `transition_ms` instead of the v1.1 `speed`
  enum. Old `sequences.json` files continue to load via the
  `legacy_speed_to_ms()` migration helper.
- `ptz.velocity` no longer carries a `speed` param. Rate is implicit
  from `yaw_speed` and `pitch_speed`.

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
  - `tests/bridge_smoke.mjs`  -  Node + ws smoke harness, 27 tests against
    real Tiny 2 Lite, runs in ~28s. Tails bridge log for new errors.
  - `docs/V1.1_PLAN.md`  -  full v1.1 backlog with sequencing.
  - `docs/TOUCH_FINDINGS_2026-05-10.md`  -  touch-emulation reproduction
    recipe + diagnostics for any future gesture-arena bug.
- **PR-styled workflow** for every change going forward.
  `docs/CONTRIBUTING.md` documents branch model + PR template +
  release-branch process.
- **Bridge cache chain**  -  `index.html`, `flutter_bootstrap.js`, and
  `main.dart.js` all now have `?v=<mtime>` cache busters; service worker
  replaced with self-unregistering stub. New builds ship instantly.
- **Auto-HDR-off on connect**  -  Tiny 2 Lite ships HDR DOL2TO1 raw frames
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
  Pixel 360x800 and iPad 768x1024 (overflow ≥56px)  -  0 velocity messages
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
- **Developer-friendly docs refresh**  -  README, run guide, architecture, protocol, app READMEs, and security policy now match the current public-source plus macOS release ZIP flow.
- **macOS release packaging script**  -  `scripts/package-mac-release.sh` builds the app, verifies the bundle, optionally Developer ID signs/notarizes/staples it, creates an arm64 release ZIP, and writes a SHA-256 checksum.
- **Saved sequence library**  -  name + persist sequences, switch between them via dropdown. Bridge stores them at `~/Library/Application Support/Open OBSBOT Bridge/sequences.json`. New WS actions `sequence.save_as / sequence.load / sequence.delete`. State event ships `sequence.available` + `sequence.loaded`.
- **AGENTS.md** so AI coding tools find the same repo guidance.
- **CHANGELOG.md** (this file).
- **CONTRIBUTING.md**, **CODE_OF_CONDUCT.md**, GitHub issue + PR templates.
- **Footers** in both apps crediting the project, OBSBOT SDK, and Flutter.

### Changed
- Folder rename: `apps/bridge_mac → apps/bridge`, `apps/mobile → apps/rc`. Internal pubspec names unchanged.
- Repo renamed `obsbot-control → open-obsbot-remote`.

### Fixed
- **Auth gate**  -  unauthenticated WebSocket clients no longer receive `state` broadcasts or subscribe snapshots before pairing.
- **Zoom validation**  -  zoom commands now use the camera-reported range instead of accepting a hardcoded 1.0-4.0 range.
- **Preview exposure**  -  removed the stale unauthenticated Crow MJPEG route; preview is served only by the token-gated MJPEG server on `ws_port + 1`.
- **Static web assets**  -  bridge now serves five-segment Flutter asset paths such as `assets/packages/cupertino_icons/assets/CupertinoIcons.ttf`.
- **Bridge restarts**  -  reset-pairing and camera-permission retry now wait for the subprocess to exit before starting it again.
- **Control commands**  -  recenter, preset recall, and sequence steps release AI tracking before moving the gimbal; direct zoom uses the reliable speed-aware SDK call.
- **Auth persistence**  -  `auth.json` is chmodded to user-only permissions after writes.

## [0.3.1] - 2026-05-02

### Added
- **Move-speed presets** (Instant / Slow / Medium / Fast). Each `preset.recall` and each sequencer step honors a per-call speed via `gimbalSetSpeedPositionR`. Speed selector lives in the app bar of both Simple and Advanced modes; saved per-app in `shared_preferences`.
- **Three sequence loop modes**: `once`, `forward`, `ping_pong` (P1→P2→P3→P2→P1→…). Bridge tracks `seq_direction_` flag.
- **Mid-sequence edit** semantics  -  `sequence.set` while running clamps current index to new list bounds, applies at next step boundary; if the list becomes empty the sequence stops.
- **Cache-clear menu** in mobile/web (PinEntry + Simple + Advanced)  -  wipes shared_preferences, unregisters service worker, clears Cache Storage, hard-reloads.
- **Hide/Show PIN+QR** on bridge UI; auto-hides 60 s after Reveal.
- **URL printed under QR** + Copy URL button (in case scan is slow).
- **Single-instance enforcement** for the .app: `LSMultipleInstancesProhibited`, AppDelegate self-quit if a sibling exists, `applicationShouldHandleReopen` raises existing window.
- **SIGPIPE ignored** in bridge  -  phone disconnects no longer kill the bridge.
- **Auto-restart** in supervisor (5 attempts, quadratic backoff) for unexpected subprocess exit.
- **`_killStalePortsHolders`** in supervisor frees ports 8765/8766 before spawning a new subprocess.
- Bridge wraps MJPEG / WS startup in try/catch  -  port-busy or bind failure logs + continues instead of crashing.

### Fixed
- **Pair race**: `pair()` was cancelling + re-listening on the WebSocket stream and missing the ack. Now uses a Completer + msg-id matched in the always-on subscription.
- **Sequencer text field**: stable `TextEditingController` per step so cursor + focus aren't destroyed on parent rebuild.
- **Zoom range**: Tiny 2 Lite max is 2.0× not 4.0×; out-of-range commands silently clamped, looking broken. Bridge picks max per `productType()`, snaps `snap_.zoom` immediately on set so phone UI feels instant.
- **`cameraSetZoomWithSpeedAbsoluteR`** preferred over `cameraSetZoomAbsoluteR` (vendor sample path).

## [0.3.0] - 2026-05-02

### Added
- **PIN-paired auth**  -  6-digit PIN displayed in bridge UI; phone enters once, gets 32-byte hex bearer token. Token gates all WS actions and MJPEG GETs. Persisted in `~/Library/Application Support/Open OBSBOT Bridge/auth.json`.
- **Simple mode** UI on phone: preview big + 2×3 preset grid + active-preset highlight + sequencer overlay bar.
- **Sequencer** backend on bridge: dedicated thread, persisted at `sequence.json`, broadcast as `state.sequence.{running,step_index,elapsed_s,total_s,mode}`.
- **Sequencer UI** on phone: drag-reorder steps, +/- step, per-step duration + speed, Start/Stop, live progress.
- **Active-preset tracking**: `snap_.active_preset_id` set on `preset.recall`/save, cleared on any manual PTZ.
- **Preset list** fetched from camera via `aiGetGimbalPresetListR` on connect  -  UI shows actual saved names.
- **MJPEG quality bump** to 20 fps, q=0.55.

## [0.2.0] - 2026-05-01

### Added
- **Web client**  -  Flutter web bundle served by the bridge from `/`. Phones use any browser, no install. Auto-detects bridge host from `window.location` so user doesn't retype IP.
- **Static file serving** in bridge (Crow routes for nested asset paths).
- **MJPEG server** standalone on port 8766  -  Crow can't stream multipart, so we hand-rolled a BSD-socket server.
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
