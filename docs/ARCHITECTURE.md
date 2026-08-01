# Architecture

Open OBSBOT Remote has these runtime products:

- `Open OBSBOT Bridge`: a macOS Flutter app that supervises a bundled C++ subprocess.
- `Open OBSBOT Remote`: the Flutter controller UI, built for web, Android, and iOS.
- `Client shell`: a planned macOS app that republishes the live camera as one virtual webcam. See `CLIENT_SHELL_DESIGN.md`.

The bridge host stays connected to one or more OBSBOT cameras over USB.
v2 runs N cameras on a single host at once.
Controller devices connect over the local network.
OBS consumes one Media Source pointed at `/preview/active.mjpg`, so a camera switch happens inside the bridge rather than as an OBS scene change.
A Media Source decodes the stream with ffmpeg and retries a dead source indefinitely; a Browser Source runs a whole Chromium instance for the same job, drops frames under load, and never reconnects when a stream ends.

## System Overview

The bridge process owns a `DeviceManager` that holds one `DeviceSession` per attached camera.
Each session is keyed by the camera's 14-char serial number and owns that camera's SDK calls on its own worker thread, plus a `MotionPlanner` thread for eased moves.
libdev's device-changed callback is the single source of truth for attach and detach; mDNS scanning is disabled, and on macOS the cameras enumerate several seconds after launch, so the callback (not a boot-time scan) is what populates the manager.

Two things sit above the per-camera sessions, both on the `DeviceManager`:

- The active (on-air) camera. `active_device_id` names the camera that `/preview/active.mjpg` follows. `device.set_active` changes it, with an optional crossfade.
- The mix engine. A single thread runs a timeline of cross-camera cues, switching the program camera and recalling presets across sessions.

```
Controller device (phone)              OBS (on the bridge host or another machine)
  - Flutter UI                           - Media Source -> /preview/active.mjpg
  - WebSocket JSON client                - one capture, follows the active camera
  - MJPEG preview viewer
        |                                      |
        |  ws://<host>:8765/v1                  |  http://<host>:8766/preview/active.mjpg?t=<token>
        |  http://<host>:8766/preview/...       |
        v                                      v
Bridge host: Open OBSBOT Bridge.app
  - Flutter supervisor UI + menubar tray
  - Bundled obsbot-bridge C++ subprocess
      - WebSocket + HTTP server (:8765)
      - MJPEG server (:8766): /preview/<sn>.mjpg + /preview/active.mjpg (fade-aware)
      - DeviceManager
            |-- active_device_id + fade window
            |-- mix engine thread (cross-camera cues)
            |-- DeviceSession(RMOWLHH3281PMV) -- worker + MotionPlanner threads
            |-- DeviceSession(RMOWLHHC233LOQ) -- worker + MotionPlanner threads
            |-- VideoCapture(RMOWLHH3281PMV), VideoCapture(RMOWLHHC233LOQ)
  - Bundled Flutter web build
  - Bundled libdev.dylib

        USB (one connection per camera)

  Camera A            Camera B
  Tiny 2 Lite         Tiny 2 Lite
```

Two roles are deliberately kept apart.
Selection is which camera a phone is controlling, and it is local to that phone, so two phones can drive two cameras at once.
Active (on-air) is which camera `/preview/active.mjpg` follows, and it is bridge-global.
An operator lines up a shot on a camera that is not live, then cuts it to air with `device.set_active`.

Default ports:

| Port | Purpose |
| --- | --- |
| `8765` | Crow HTTP/WebSocket server: `/v1`, `/health`, `/pair`, and static web remote assets. |
| `8766` | Hand-rolled BSD-socket MJPEG server for `/preview/<sn>.mjpg` and `/preview/active.mjpg`. |

The MJPEG server lives on `ws_port + 1` because Crow buffers `response.write()` until the handler returns, which breaks multipart streaming.

## Components

### `apps/bridge/`

Flutter macOS shell for `Open OBSBOT Bridge.app`.

Responsibilities:

- Locate and launch the bundled `obsbot-bridge` subprocess.
- Pass `--port 8765` and `--web-root <bundle>/Contents/Resources/web`.
- Tail subprocess stdout/stderr into the UI and persistent log file.
- Show bridge status, camera permission status, detected cameras, paired token count, PIN, QR code, and URL.
- Reset pairing state through the supervised process/UI flow.
- Auto-restart the subprocess after unexpected exits.
- Kill stale listeners on ports `8765` and `8766` before spawning.
- Enforce single-instance behavior.
- Run a macOS menubar tray icon. The tray title carries a live status glyph. Closing the main window hides it instead of quitting; the tray keeps the subprocess alive so live streams are not interrupted.

The subprocess dies with this app, deliberately.
It blocks on `read(STDIN_FILENO)` and exits the moment that pipe closes, which the kernel does whenever the supervisor goes away - a clean quit, a crash, or a force quit alike.
Parent-side cleanup cannot cover the last two, since a killed process runs no code, and macOS has no parent-death signal to fall back on.
So **quitting the bridge app ends the stream**, where closing its window does not.
An OBS Media Source reconnects on its own once the bridge is running again; this is one of the reasons to prefer it over a Browser Source, which does not.
Without this the subprocess was orphaned to launchd and went on holding the camera and both ports, and `tests/lifecycle.mjs` now pins the behaviour in both directions.

Important paths:

```text
~/Library/Logs/Open OBSBOT Bridge/bridge.log
~/Library/Application Support/Open OBSBOT Bridge/auth.json            PIN + issued tokens, bridge-wide
~/Library/Application Support/Open OBSBOT Bridge/active.json          which camera is live
~/Library/Application Support/Open OBSBOT Bridge/device_names.json    friendly names by serial
~/Library/Application Support/Open OBSBOT Bridge/sequence.json        per-camera active sequence, keyed by serial
~/Library/Application Support/Open OBSBOT Bridge/sequences.json       per-camera saved sequences, keyed by serial
~/Library/Application Support/Open OBSBOT Bridge/mix.json             active cross-camera mix, bridge-level
~/Library/Application Support/Open OBSBOT Bridge/mix_sequences.json   saved cross-camera mixes, bridge-level
```

Presets are not on disk.
They live on the camera hardware (`aiAddGimbalPresetR`) and are read back per camera, so multi-camera preset isolation is free and there is nothing to migrate.

The `.app` is ad-hoc signed by `scripts/build-bridge-mac.sh`. Signing matters because macOS TCC camera permission must apply to the bundle and its subprocess.

### `apps/bridge_cpp/`

C++17 subprocess named `obsbot-bridge`.

It takes two flags: `--port <n>` (default `8765`) and `--web-root <dir>` (also read from `OBSBOT_WEB_ROOT`).
`main.cpp` ignores `SIGPIPE` so a phone dropping its socket mid-write never kills the process, and it exits through `_Exit(0)` on `SIGINT`/`SIGTERM` to skip libdev's crash-on-teardown destructors.

Responsibilities:

- Load OBSBOT `libdev.dylib`.
- Own a `DeviceManager` that holds one `DeviceSession` per camera and routes commands by `device_id`.
- Own all SDK calls for a camera on that camera's `DeviceSession` worker thread.
- Track the live camera (`active_device_id`), persist it to `active.json`, and run the crossfade (dissolve) on a switch.
- Run the cross-camera mix engine.
- Expose the JSON-over-WebSocket control API at `/v1`.
- Serve `/health`, `/pair`, and the Flutter web build as static files from `/`.
- Capture UVC preview frames with AVFoundation, one capture per camera, and encode JPEG in software.
- Stream per-camera MJPEG (`/preview/<sn>.mjpg`) and a follow-live stream (`/preview/active.mjpg`).
- Persist pairing auth, per-camera sequences, mix scratch and library, and friendly names.

`DeviceManager` is the center of the multi-camera model.
It keys sessions by serial, dispatches each action to the right session, applies the `device_id` resolution rules (0 cameras, 1 camera, 2 or more cameras) documented in `PROTOCOL.md`, and rebuilds the `devices[]` array for every state broadcast.
It also owns the per-serial AVFoundation `VideoCapture` objects: they are created or restarted on attach and stopped (never destroyed) on detach, so a serving MJPEG thread that holds a `VideoCapture*` never dangles when a camera unplugs mid-stream.

Main libraries:

| Library | Use |
| --- | --- |
| OBSBOT `libdev` | Camera discovery and control. |
| Crow + standalone Asio | WebSocket and ordinary HTTP routes on `8765`. |
| nlohmann/json | Protocol encoding/decoding. |
| AVFoundation/CoreMedia/CoreVideo | UVC preview capture. |
| BSD sockets | Streaming MJPEG server on `8766`. |

### `apps/rc/`

Flutter controller app, built for web (served by the bridge at `http://<host>:8765/`), Android, and iOS.

The UI is one screen, `LiveScreen`, the v3 studio surface.
It replaces the v1.2 Simple/Advanced split and its tabbed control screen; forui is retired and the app is on Material widgets throughout.

`LiveScreen` lays out:

- A staging preview of the camera this phone is lining up, filling the top, with the on-air camera in a red picture-in-picture.
- A camera bus for selecting and switching cameras, shown when more than one camera is attached.
- Either the staged camera's preset grid, or, when Frame is tapped, the manual PTZ and zoom controls in its place.
- A TAKE button that cuts the staged camera on air, optionally crossfading.
- A gear that opens image controls, sequences, connection, and settings.

Red marks the on-air camera; green marks the staged one.
The live preview draws an optional grid overlay (center crosshair, an attitude indicator that translates with pan/tilt and rotates with roll, rule-of-thirds lines, a top-left Pan / Tilt readout), and the toggles persist via SharedPreferences.
Web renders MJPEG through an HTML `<img>` element because Flutter web image widgets do not decode multipart streams.

The controller is layered into packages; see [Client architecture](#client-architecture).

### Client shell (planned)

A macOS app that republishes the live camera as one virtual webcam, for tools that cannot consume an MJPEG URL at all: Zoom, Meet, and anything else that only accepts a system camera.
It would be a WebSocket client of the bridge, the same as the phone, running on the same Mac.

Responsibilities:

- Connect to `ws://localhost:8765/v1`, authenticate with the token read from `auth.json`, and subscribe.
- Consume `http://localhost:8766/preview/active.mjpg?t=<token>`.
- Republish those frames as a macOS virtual camera named "OBSBOT Bridge".
- Re-point its frame source when `active_device_id` changes in a state event.
- Show a small status UI with connection state, the live camera name, a start/stop toggle, and a link to the bridge window.

The shell is not built yet.
`CLIENT_SHELL_DESIGN.md` covers the two implementation paths (an OBS source first, a CoreMediaIO Camera Extension later) and the open questions around signing and notarization.
The control surface stays on the phone; the shell would add no camera controls of its own.

## Client architecture

The controller is split into packages so each concern is testable on its own.
Data flows up through the layers; each layer knows only the one below it.

| Layer | Package | Responsibility |
| --- | --- | --- |
| Transport | `packages/obsbot_api_client` | Opens the WebSocket, assigns an integer `id` to each request, correlates acks back to their futures, and republishes unsolicited frames on an `events` stream. Knows nothing about cameras or actions. |
| Auth | `packages/auth_repository` | Runs the `hello` / `pair` handshake, stores the per-bridge token under `token::<host:port>`, and publishes an `AuthStatus` stream. |
| Bridge state | `packages/bridge_repository` | Decodes `event == "state"` frames into a `BridgeState`, replays the latest to every new listener, wraps the bridge-scoped actions (`device.set_active` with optional `fade_ms`, `device.rename`, the `mix.*` family, `library.export`/`library.import`), and builds the MJPEG preview URL. |
| Per-device state | `packages/device_repository` | Holds the per-device optimistic overlay and the gimbal, image, preset, and sequence commands. Each mutating call writes a local overlay keyed by (device, field), emits at once, then settles it against the bridge's echo after the ack. |
| Presentation | `apps/rc/lib/ws_client.dart` | `WsClient`, a `ChangeNotifier` facade. Owns connection lifecycle, the phone-local camera selection, UI preferences, and fan-out to the widget tree. |

`packages/obsbot_protocol` holds the shared wire types (`BridgeState`, `DeviceState`, `MixState`, `MixCue`, `SequenceStep`, `PresetEntry`, `LoopMode`) as the Dart mirror of the C++ JSON.

The optimistic overlay is per field and per device.
A tap on HDR flips the button on the same frame, then the overlay is held until its write is acked and dropped only on the first real state event after that ack, which avoids a one-frame flicker back to a stale polled value.
An HDR overlay on camera A never touches camera B, and a slow zoom overlay on A never masks a concurrent AI-mode overlay on the same camera.

`WsClient` keeps `selectedDeviceId` (this phone's camera) separate from `activeDeviceId` (the bridge-global live camera).
`makeLive(deviceId, fadeMs)` calls `device.set_active`; selecting a camera only re-points this phone's controls.

## Auth Flow

1. Bridge creates or loads a 6-digit PIN and stores it in `auth.json`.
2. User reveals the PIN in the bridge app.
3. Client opens the WebSocket and sends `hello` with a saved token, if it has one.
4. If the token is valid, the connection becomes authenticated.
5. If the token is missing or invalid, the bridge replies `auth_required`.
6. Client sends `pair` with the PIN.
7. Bridge issues a random 32-byte hex token and stores it in `auth.json`.
8. Client saves the token and resubscribes.
9. MJPEG preview requests include the token as `?t=<token>`.

Only `pair` and `ping` are accepted before authentication. State broadcasts go only to authenticated WebSocket connections.

## Command Flow

```
WebSocket client
  -> JSON command (may carry device_id)
  -> Crow WS handler
  -> protocol.cpp dispatch
  -> bridge-scoped action, OR DeviceManager resolves device_id -> DeviceSession
  -> that camera's command queue -> SDK worker thread -> libdev synchronous call
  -> ack to requesting client
  -> state broadcast to authenticated clients
```

`protocol.cpp` splits actions into two groups.
Bridge-scoped actions run on the manager: `hello`, `subscribe`, `ping`, `device.list`, `device.set_active`, `device.rename`, the `mix.*` family, and `library.export` / `library.import`.
Everything else is device-scoped and goes through `route_target`, which resolves `device_id` before dispatch.
An omitted `device_id` routes to the sole camera when exactly one is attached, and is rejected (`no_device` or `device_required`) otherwise, per `PROTOCOL.md`.

Each session's worker thread owns its own `Device` pointer, so libdev is never called from a WebSocket thread or an SDK callback directly, and two cameras never contend on one thread.
The bridge polls each connected camera's logical state about every 500 ms and also pushes a full state broadcast after a successful command and on plug or unplug.
A plug or unplug rebuilds the `devices[]` array; there is no targeted delta event.

## Preview Flow

```
AVFoundation capture session (one per camera)
  -> latest JPEG frame in memory, per camera
  -> MjpegServer on port 8766
  -> GET /preview/<sn>.mjpg?t=<token>      (one fixed camera)
     GET /preview/active.mjpg?t=<token>    (follows active_device_id)
  -> multipart/x-mixed-replace stream
  -> phone preview widget, or the OBS Media Source
```

The per-serial path streams one fixed camera and never switches; it is what the phone shows for the camera the operator has selected.
The `active.mjpg` path re-resolves the source every frame from `active_device_id`, so when the active camera changes the source swaps mid-stream while the HTTP connection stays open.
OBS holds that one connection across cuts and sees a single stable device.
A missing or invalid token returns 401, an unknown serial returns 404, and a camera with no frames yet (asleep or still starting) returns 503 after a short wait.

The transition on the active stream is a crossfade (dissolve), and it rides on the active stream only.
When `device.set_active` starts a fade, `DeviceManager` freezes the outgoing camera's last frame, then `DeviceManager::active_fade(std::vector<uint8_t>& outgoing)` ramps a mix factor from 0 to 1 over the fade window.
The MJPEG server dissolves that frozen outgoing frame into the incoming camera's live frames via `jpeg_crossfade`, so OBS sees the crossfade baked into the pixels.
On the first take, when no outgoing frame has been captured yet, it falls back to a fade from black via `jpeg_darken`.
A hard cut (`fade_ms` 0) clears any fade still in progress so the program does not inherit a leftover ramp.

## Sequencing

There are two independent sequencers, at two scopes.

Per-camera sequences live on each `DeviceSession` and drive that one camera's gimbal.
They keep running if the phone disconnects, are keyed by serial in `sequence.json` and `sequences.json`, and two cameras can run different sequences at once without interfering.
Each step is `{ "preset_id": 1, "seconds": 20, "transition_ms": 5000 }`: `seconds` is the hold at the preset, and `transition_ms` is how long the move into it takes (`0` is instant, non-zero routes through the MotionPlanner).
`sequence.set` / `sequence.start` / `sequence.stop` drive the active sequence; `sequence.save_as` / `sequence.load` / `sequence.delete` manage that camera's library.

The mix sequencer lives on the `DeviceManager` because a cue spans cameras.
Its thread walks a list of `MixCue`s.
For each cue it switches the program camera with `set_active` (fading if the cue asks), recalls the cue's preset on that camera over `move_ms` so the camera moves live on air, optionally pre-positions a second camera through the cue's `meanwhile`, holds for `hold_s`, then advances by the loop mode.
A cue with a negative `preset_id` cuts to its camera without moving it.
`mix.set` edits the scratch cue list, `mix.start` / `mix.stop` run it, and `mix.save_as` / `mix.load` / `mix.delete` manage the saved mixes in `mix_sequences.json`.
The engine reuses `set_active` and each session's `cmd_preset_recall`, so it holds no locks that the per-camera sessions need and never blocks one camera's motion on another's.

Loop modes for both sequencers:

- `once`
- `forward`
- `ping_pong`

## Persistence

State lives under `~/Library/Application Support/Open OBSBOT Bridge/`.
The per-camera files are keyed by serial so two cameras never share a sequence bank.
The mix files are bridge-level, because a mix spans cameras.

| File | Shape |
| --- | --- |
| `auth.json` | `{ pin, tokens[] }`, bridge-wide. |
| `active.json` | `{ "active_device_sn": "RMOW..." }`. |
| `device_names.json` | `{ "<sn>": "Vocal" }`. |
| `sequence.json` | `{ "<sn>": { mode, steps } }`, the active per-camera sequence. |
| `sequences.json` | `{ "<sn>": { "<name>": { mode, steps } } }`, the per-camera library. |
| `mix.json` | `{ mode, cues[] }`, the active cross-camera mix. |
| `mix_sequences.json` | `{ "<name>": { mode, cues[] } }`, the saved cross-camera mixes. |

On first attach the bridge detects a v1-shaped `sequence.json` or `sequences.json` structurally (v1 files carry no version marker) and re-keys it under the attaching camera's serial, so an upgrade from a single-camera v1 install keeps every saved sequence.
Presets are not migrated because they were never on disk.

`library.export` returns the per-camera sequences, the mix library, and the device names as one blob for moving to a new Mac; `library.import` merges that blob back in, with incoming entries winning per key.

## Build Bundle Layout

`scripts/build-bridge-mac.sh` produces:

```text
Open OBSBOT Bridge.app/
  Contents/
    MacOS/
      obsbot_bridge_mac
      obsbot-bridge
      libdev.dylib
    Resources/
      web/
        index.html
        ...
```

The script builds C++, the Flutter web remote, and the Flutter macOS shell, copies the required artifacts, then ad-hoc signs the final bundle.

`scripts/package-mac-release.sh` wraps that bundle in a GitHub Release ZIP and writes a SHA-256 checksum in `dist/`. The ZIP includes the SDK runtime dylib inside the `.app`; the full SDK package is not committed to git.

## Current Non-Goals

- Public internet access.
- TLS termination inside the bridge.
- A signed and notarized CoreMediaIO Camera Extension for the client shell, which needs a paid Apple Developer account. Consuming the MJPEG stream in OBS ships first; see `CLIENT_SHELL_DESIGN.md`.
- Windows and Linux bridge packaging.
- Firmware updates.
- OBSBOT camera families that have not been validated on real hardware.
