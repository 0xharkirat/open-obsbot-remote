# UI redesign spec — v1.2

Real-world feedback after the temple livestream + grid-overlay PR:

> "Now it's harder to scroll because the joystick keeps getting the UI."
>
> "What is yaw, pitch? Use simpler terms."
>
> "All of this would be solved via complete UI redesign."

This spec covers the redesign that lands as a sequence of PRs after the
slow-motion + grid-overlay work is merged. Reference: the official
OBSBOT mobile remote app, with our additions (live preview always
visible, sequencer, simple mode, hold-buttons, gimbal grid).

## Design principles

1. **Preview first.** The live MJPEG view is always visible, never
   hidden behind a tab. It's the single most important pixel real
   estate.
2. **One control surface at a time.** No more "five rows of stuff
   crammed onto one screen." Each control mode (joystick, buttons,
   presets, sequencer, image) gets its own tab below the preview.
3. **No gesture conflicts.** Joystick lives on its own tab. Scrolling
   action rows live on their own tab. The two never share a screen.
4. **Mobile-first.** Layout decisions driven by available window space
   (per `flutter-build-responsive-layout` skill), not by device class.
   Breakpoints at 480 / 768 / 1200.
5. **Plain language.** Replace camera-engineer jargon with operator
   words: "yaw → pan", "pitch → tilt", "AI" → "Auto-tracking",
   "FOV" → "Wide / Normal / Narrow".
6. **44 px touch targets.** Every interactive element passes iOS HIG.
7. **Accessibility AA.** Color contrast ≥4.5:1 for text, ≥3:1 for
   interactive surfaces.

## Information architecture — 5 tabs below the preview

```
┌────────────────────────────────────────────────────┐
│                 LIVE PREVIEW                       │
│           (always-visible, top-half)               │
│   • optional grid overlay (PR #4)                  │
│   • optional Pan/Tilt readout overlay              │
└────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────┐
│ ◉ Joystick   ◯ Buttons   ◯ Presets   ◯ Sequence ◯ Image │
└────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────┐
│                                                    │
│            [selected tab's content]                │
│                                                    │
└────────────────────────────────────────────────────┘
```

### Tab 1 — Joystick (default)

- Large round joystick pad, centered.
- Vertical zoom slider on the right (1.0x ↔ 2.0x for Tiny 2 Lite).
- Move-duration chips at the bottom: `Instant 1s 5s 15s 30s 1m 3m 5m`
- Recenter button (small, top-right of joystick).
- Sleep / Wake quick action.

### Tab 2 — Buttons (hold-to-move directional pad)

- 4-direction cross of large hold-buttons: ↑ ↓ ← →.
- Diagonal buttons for 8-way control.
- Speed factor slider underneath: "Slow ←→ Fast" (0.1x to 1.0x of
  normal velocity).
- Same recenter, sleep, wake row.

### Tab 3 — Presets

- 6 large preset cards (P1..P6) in a 2×3 grid.
- Each card shows preset thumbnail (small base64 jpeg, future), name,
  and a small "P1" + zoom badge.
- Tap = recall (with current move-duration).
- Long-press = save current position.
- "Rename" via long-press menu.

### Tab 4 — Sequencer

- Timeline view: vertical scroll of step cards.
- Each step card: preset thumb + name + duration (`Hold 60s`) +
  transition (`Move 30s`).
- Top toolbar: `▶ Start`, `■ Stop`, loop-mode selector
  (Once / Forward / Ping-pong), save-as / load / delete.
- Tap a step to edit its hold-time or transition-time.

### Tab 5 — Image

All camera image controls in one place:

- **Auto / Manual exposure** toggle (new, fixes "dim auto" feedback).
- **EV bias** slider (-2.0 to +2.0 EV) when in Auto.
- **HDR** toggle (3 s firmware debounce hint).
- **FOV** segmented: Wide (86°) / Normal (78°) / Narrow (65°).
- **Auto-track** (formerly AI): Off / Human / Group + sub-mode submenu
  (Normal / Upper body / Close-up / Head-hide / Lower body).
- **Brightness / Contrast / Saturation / Sharpness** sliders (0..100).
- **Face AE** + **Face focus** toggles, both off by default per the
  "dim" finding.
- **Flip horizontal** toggle.

## Persistent header (always visible above tabs)

```
┌──────────────────────────────────────────────────────┐
│  Tiny 2 Lite    1 ms    [duration:5s]  [grid] [≡]   │
└──────────────────────────────────────────────────────┘
```

- Model name + latency.
- Move-duration chip (current selection shown; tap = popup).
- Grid overlay menu (from PR #4).
- Overflow menu: Simple mode, Disconnect, Cache, About.

## Breakpoints

Per `flutter-build-responsive-layout` skill — decisions on
`LayoutBuilder` constraints.maxWidth, not device.

| Width | Layout |
|---|---|
| <480 (phone portrait) | preview on top (16:9), tabs below, tab content fills remaining height |
| 480–768 (phone landscape, small tablet portrait) | preview on left (50%), tabs+content on right (50%) |
| 768–1200 (tablet) | preview on left (60%), tabs as vertical rail on right (40%) |
| ≥1200 (desktop / large tablet) | preview top-left (60% × 60%), tabs bottom-left, presets always-visible side panel right |

## Plain-language copy

| Old | New |
|---|---|
| Yaw | Pan |
| Pitch | Tilt |
| Roll | Tilt-roll *(rarely needed)* |
| FOV | View *(Wide / Normal / Narrow)* |
| AI HUMAN | Track person |
| AI GROUP | Track group |
| Move speed | Move duration *(Instant / 1s / 5s / ...)* |
| HDR | Bright shadows *(toggle hint: "On in low light")* |
| Face AE | Auto-expose for face |
| Face focus | Focus on face |
| Cinema | (removed — replaced by `30 sec` / `1 min` / `3 min` etc.) |

UX copy review via `design:ux-copy` skill before each PR ships.

## Design tokens (proposed)

Picked via `design:design-system` skill — exact final values reviewed
before implementation.

- **Color:** Material 3 dark surface base. Primary blue accent for
  active states. Crosshair white at 60% opacity.
- **Spacing scale:** 4 / 8 / 12 / 16 / 24 / 32 px.
- **Type ramp:** 11 (caption) / 12 (small) / 14 (body) / 16 (subtitle)
  / 20 (title) / 28 (hero). Inter or system font.
- **Radius:** 8 (cards) / 12 (preview, tab content) / 999 (chips).
- **Elevation:** flat by default; subtle 2dp shadow on raised cards.

## PR sequence (after PR #4 + #5 merge)

Redesign first, then exposure inside the new Image tab.

| # | Branch | What |
|---|---|---|
| A | `feat/tab-bar-shell` | Pure layout: 5-tab shell, preview pinned, no behavior change |
| B | `feat/joystick-tab` | Move joystick into Tab 1; remove from main layout |
| C | `feat/buttons-tab` | Hold-button pad in Tab 2 |
| D | `feat/presets-tab` | Preset cards 2×3 |
| E | `feat/sequencer-tab` | Timeline cards |
| F | `feat/image-tab` | Image tab shell — HDR / FOV / Face AE / Face focus / Flip / Color sliders |
| G | `feat/exposure-controls` | Exposure mode, EV-bias, anti-flicker, WB inside Image tab. **See `docs/EXPOSURE_REFERENCE.md`.** |
| H | `feat/bridge-tray` | macOS menubar (tray) for the Open OBSBOT Bridge.app: status / Reveal PIN / Show window / Quit. Window can close while bridge keeps running. |
| I | `feat/forui-shell` | First forui screen migration (pair + header) |
| J | `feat/forui-tabs` | forui for all tab content |
| K | `chore/release-v1.2.0` | Bump versions, CHANGELOG, GH release |

Each PR ships smoke 27/27 + touch regression at 360 / 390 / 768.

## Tools / skills checklist per PR

- **`flutter-build-responsive-layout`** — every layout PR (A–E).
- **`flutter-add-widget-preview`** — preview tabs at all breakpoints
  without launching app.
- **`design:design-system`** — token review before A; deep review
  before G/H.
- **`design:ux-copy`** — string sweep before merge of each PR.
- **`design:design-critique`** — review screenshot before each tab PR
  merge.
- **`design:accessibility-review`** — color + tap-target audit on G/H.
- **`design:design-handoff`** — generate exact spec sheet to drop into
  PR description.

## Bridge tray (PR H)

The Open OBSBOT Bridge.app currently opens a full window every launch
and exits when the window closes. Real-world use is "set + forget" —
the user wants the bridge running quietly in the background and the
window only when they need to reveal the PIN or check status.

Tray pattern (macOS menubar, Windows system tray, Linux indicator):

- Always-visible status icon in the system tray
- Click the icon → small menu:
  - **Status: Connected / Idle** (header line)
  - Reveal PIN (60-second show, same as window UI)
  - Show main window
  - Open log file (Console.app)
  - Restart bridge subprocess
  - Quit
- Closing the main window hides the window instead of quitting — the
  tray icon keeps the bridge subprocess alive

Implementation: `tray_manager` Flutter package (cross-platform). On
macOS we also gain `LSUIElement = true` consideration so the dock icon
disappears in tray-only mode (offer as a setting; default keeps dock
icon for discoverability).

## Out of scope (v1.3+)

- Per-preset thumbnail capture (requires bridge `preset.thumbnail`
  endpoint that snaps current frame).
- Multi-camera support (single bridge, two USB cameras).
- Native iOS/Android packaging (TestFlight, Play Store).
- forui migration of every dialog / snackbar (low priority).
- Linux + Windows native builds (separate platform-port branch).
