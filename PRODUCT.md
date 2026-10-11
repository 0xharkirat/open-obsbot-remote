# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

The product is Flutter, not a website, but it has one design language of its own on every surface: the bridge window on macOS and Windows, the remote in a phone browser, and the same remote as Android, iOS and macOS apps. It does not take a native look per operating system (confirmed 2026-10-11). Native affordances still apply: tray or menu bar icon, window close that hides, firewall and camera permission flows.

## Users

**Primary: the volunteer operator at a gurdwara** (confirmed 2026-10-11).

- One volunteer runs the cameras for a service of 90 minutes to 3 hours.
- They hold a phone, and their eyes are mostly on the room, not the screen.
- They may also be doing seva at the same time.
- They may use the app once a month, and may not be technical.
- A wrong tap is visible to the whole congregation and to the live stream.

**Secondary: the person who sets up the bridge PC.** Often the same volunteer or a more technical sangat member. They install the bridge on a Mac or Windows PC beside OBS, plug in the cameras, pair phones, and give OBS one URL. After setup, they rarely open the bridge window. It sits in the tray or menu bar.

## Product Purpose

Open OBSBOT Remote lets one person control several OBSBOT PTZ cameras from a phone, a browser or a computer, on the local network, with no cloud and no account.

OBS becomes a passive display. It reads one Media Source, `active.mjpg`, that always shows the camera that is on air. The operator selects, frames and puts cameras on air (TAKE, as a cut or a crossfade) in the remote. Nobody builds per-camera scenes in OBS.

Success: a service is streamed and recorded with steady, well-framed shots, and the operator never has to think about the technology. The bridge stays up for the whole service, and a mistake is hard to make and easy to recover from.

## Positioning

- Free and open source (Apache-2.0). It replaces OBSBOT Center for daily control, and works on a phone.
- The camera switch happens in the bridge, not in OBS. One OBS source follows the on-air camera, with crossfades baked into the stream.
- Selection (the camera you control) and on air (the camera OBS shows) are separate. You stage and frame a shot off air, then TAKE it.
- It works with no internet. Everything runs on the venue LAN, from the bridge PC.

## Operating Context

- **Venue:** a gurdwara hall. The light is often dim. The room is quiet and the service is sacred, so the operator must be discreet.
- **Network:** LAN only, often no internet. Venue Wi-Fi is usually a public network to Windows. Plain `http://` and `ws://`, PIN pairing, then a stored token. No HTTPS, no service worker, no install as an app (ruled out, see `docs/wayfinder/mobile-ux/map.md`).
- **Bridge PC:** a Mac or a Windows PC beside OBS, cameras on USB. Often the same PC runs OBS, and sometimes other personal uses (for example gaming) on other days.
- **Session arc:** before the service (power on, check cameras, pair a phone), during (select, frame, TAKE, presets, sequences for hours), after (leave it running or quit).
- **Failure moments:** a phone loses Wi-Fi, a camera is unplugged or held by another app, OBS shows a frozen frame, the bridge restarts. The remote must degrade in place, not navigate away.

## Capabilities and Constraints

**Bridge window (first redesign surface, confirmed 2026-10-11):**

- It answers one question first: is everything OK for the service? Details show only when something needs the user.
- Its jobs are setup with pairing, and health monitoring during a service. Full camera control stays in the remote.
- A simple list of cameras, with which one is on air and an action to put a camera on air. No camera previews in this window (confirmed 2026-10-11).
- Must not feel like a gamer or tech tool, and must not show a wall of settings (confirmed 2026-10-11).
- Pairing: a 6-digit PIN and a QR code, hidden by default, revealed for 60 seconds. Paired-phone count. Reset pairing.
- The OBS output URL to copy, and how to set up the Media Source.
- The LAN address for phones, Wi-Fi or Ethernet first.
- Permissions and health: camera access, firewall, camera held by another app.
- Settings: start hidden, log file, app data, version, About.
- Lifecycle: closing the window hides it; the tray (Windows) or menu bar (macOS) keeps the bridge running; Quit is in the tray menu.

**Remote (later surface):** a Live screen with preview and program, TAKE (cut or crossfade), PTZ by tap, hold and joystick, zoom, 6 presets per camera, image controls, single-camera sequences, a cross-camera mix sequencer, and library export and import. Phone first; a desk layout for tablets and desktop browsers.

**Constraints:**

- Flutter. The bridge app is `apps/bridge` (macOS and Windows). The remote is `apps/rc` (web, Android, iOS, macOS). Shared wire types in `packages/obsbot_protocol`.
- The remote must render offline: fonts and CanvasKit are bundled (Roboto plus a symbol font). Gurmukhi text does not yet render offline.
- Terminology already in use: bridge, remote, camera, on air, selection, TAKE, cut, crossfade, preset, sequence, mix, source, pairing PIN, OBS output URL.
- Repo rule: never use em dashes in any file.
- Docs are written in about 80% ASD-STE100 Simplified Technical English.

**Undecided:**

- The full visual language (colour, type, components). Research named it "deliberately last"; this redesign now owns it.
- Whether a second operator on a second phone is a real scenario.
- The phone sequencer layout and the settings architecture (see `docs/wayfinder/mobile-ux/map.md`).

## Brand Commitments

- Names: **Open OBSBOT Bridge** (the computer app) and **Open OBSBOT Remote** (the controller). "OBSBOT" is the camera maker's name; the product is not affiliated with OBSBOT.
- An existing app icon: `apps/bridge/macos/Runner/Assets.xcassets/AppIcon.appiconset/` (also built into `apps/bridge/windows/runner/resources/app_icon.ico`).
- No other binding visual commitments. The current macOS-style bridge window (`macos_ui`) and the Material 3 remote are evidence, not a brand to keep.

## Evidence on Hand

- UX research: `docs/wayfinder/mobile-ux/map.md` and its tickets, `docs/wayfinder/ui-ux-research/` (Mobbin findings, flow research for pairing and first run, the live-session arc, authoring and failure, cross-device and settings).
- Real use: multi-hour services drove the 2.5.x fixes (see `CHANGELOG.md`).
- Tested hardware: OBSBOT Tiny 2 Lite. Other models are untested.
- Absent, do not invent: user testimonials, user counts, venue names other than as context, performance claims beyond those measured in the docs, any affiliation with OBSBOT.

## Product Principles

1. **Calm under pressure.** During a service, the screen must never surprise the operator. Show state plainly; never move a control the operator is about to tap.
2. **The room comes first.** The operator looks at the hall, not the phone. Every live action must work by position and feel, with large targets and few choices.
3. **On air is sacred.** Anything that changes what the congregation and the stream see is deliberate, clearly marked, and hard to do by accident.
4. **Set up once, then disappear.** The bridge is configured one time and then lives in the tray. It must tell you plainly when something needs you, and stay silent when nothing does.
5. **Offline and local by default.** Nothing may depend on the internet, an account or a cloud service.

## Accessibility & Inclusion

- A dim hall, an operator who may be older, a screen at arm's length: high contrast, large text and large touch targets are requirements, not options (research flagged this for a deliberate pass).
- Operators may be non-native English readers. Use short, plain words in the UI, consistent with the STE style of the docs.
- Punjabi (Gurmukhi) users are likely; Gurmukhi does not yet render offline, so do not rely on it in UI text until fonts are bundled.
