# Architecture

Open OBSBOT Remote has these runtime products:

- `Open OBSBOT Bridge`: a macOS Flutter app that supervises a bundled C++ subprocess.
- `Open OBSBOT Remote`: the Flutter controller UI, built for web, Android, and iOS.
- `Client shell`: a planned macOS app that presents the live camera to OBS as one virtual webcam. See `CLIENT_SHELL_DESIGN.md`.

The bridge host stays connected to one or more OBSBOT cameras over USB.
v2.0 supports N cameras on a single host at once.
Controller devices connect over the local network.

## System Overview

The bridge process owns a `DeviceManager` that holds one `DeviceSession` per attached camera.
Commands carry a `device_id` (the camera serial) and the manager routes each to the matching session.
Each session owns its camera's SDK calls and its own MotionPlanner worker thread, so cameras run fully independently.

```
Controller device (phone)           Client shell (macOS, planned)
  - Flutter UI                        - WebSocket JSON client
  - WebSocket JSON client             - consumes /preview/active.mjpg
  - MJPEG preview viewer              - re-publishes as a virtual webcam
        |                                   |
        |  ws://<host>:8765/v1              |  ws + http://<host>:8766/preview/active.mjpg
        |  http://<host>:8766/preview/...   |
        v                                   v
Bridge host: Open OBSBOT Bridge.app
  - Flutter supervisor UI + menubar tray
  - Bundled obsbot-bridge C++ subprocess
      - WebSocket + HTTP server (:8765)
      - MJPEG server (:8766): /preview/<sn>.mjpg + /preview/active.mjpg
      - DeviceManager
            |-- DeviceSession(RMOWLHH3281PMV) -- MotionPlanner thread
            |-- DeviceSession(RMOWLHHC233LOQ) -- MotionPlanner thread
  - Bundled Flutter web build
  - Bundled libdev.dylib

        USB (one connection per camera)

  Camera A            Camera B
  Tiny 2 Lite         Tiny 2 Lite
```

The client shell is a WebSocket client of the bridge, exactly like the phone.
It differs only in what it does with the feed: instead of showing preview to a human, it pulls `/preview/active.mjpg` and republishes those frames as a macOS virtual camera named "OBSBOT Bridge".
OBS then captures that one virtual device, and the live camera it shows follows `active_device_id` without any scene switching.

Default ports:

| Port | Purpose |
| --- | --- |
| `8765` | Crow HTTP/WebSocket server: `/v1`, `/health`, `/pair`, and static web remote assets. |
| `8766` | Hand-rolled BSD-socket MJPEG server for `/preview/<device_id>.mjpg` and `/preview/active.mjpg`. |

The MJPEG server lives on `ws_port + 1` because Crow buffers `response.write()` until the handler returns, which breaks multipart streaming.

## Components

### `apps/bridge/`

Flutter macOS shell for `Open OBSBOT Bridge.app`.

Responsibilities:

- Locate and launch the bundled `obsbot-bridge` subprocess.
- Pass `--port 8765` and `--web-root <bundle>/Contents/Resources/web`.
- Tail subprocess stdout/stderr into the UI and persistent log file.
- Show bridge status, camera permission status, detected camera, paired token count, PIN, QR code, and URL.
- Reset pairing state through the supervised process/UI flow.
- Auto-restart the subprocess after unexpected exits.
- Kill stale listeners on ports `8765` and `8766` before spawning.
- Enforce single-instance behavior.
- Run a macOS menubar tray icon (added in v1.2). Tray title carries a live status glyph (running / no camera / stopped / error). Tray menu items: Reveal pairing PIN, Show main window, Open log file, Restart bridge subprocess, Quit. Closing the main window hides it instead of quitting; the tray icon keeps the bridge subprocess alive so live streams do not get interrupted.

Important paths:

```text
~/Library/Logs/Open OBSBOT Bridge/bridge.log
~/Library/Application Support/Open OBSBOT Bridge/auth.json
~/Library/Application Support/Open OBSBOT Bridge/presets.json      (v2: keyed by camera serial)
~/Library/Application Support/Open OBSBOT Bridge/sequence.json     (v2: keyed by camera serial)
~/Library/Application Support/Open OBSBOT Bridge/sequences.json    (v2: keyed by camera serial)
~/Library/Application Support/Open OBSBOT Bridge/device_names.json (v2: friendly names by serial)
~/Library/Application Support/Open OBSBOT Bridge/active.json       (v2: which camera is live)
```

The per-camera files are keyed by camera serial in v2.
The bridge migrates a v1 single-camera file to the v2 keyed shape on first load, re-keyed under the first attaching camera's serial.
See `PROTOCOL.md` for the migration rules.

The `.app` is ad-hoc signed by `scripts/build-bridge-mac.sh`. Signing matters because macOS TCC camera permission must apply to the bundle and its subprocess.

### `apps/bridge_cpp/`

C++17 subprocess named `obsbot-bridge`.

Responsibilities:

- Load OBSBOT `libdev.dylib`.
- Detect every attached USB camera through the SDK.
- Own a `DeviceManager` that holds one `DeviceSession` per camera and routes commands by `device_id`.
- Own all SDK calls for a camera on that camera's `DeviceSession` worker thread.
- Track the live camera (`active_device_id`) and persist it to `active.json`.
- Expose JSON-over-WebSocket control API at `/v1`.
- Serve `/health` and `/pair`.
- Serve the Flutter web build as static files from `/`.
- Capture UVC preview frames with AVFoundation, one capture per camera.
- Stream per-camera MJPEG (`/preview/<sn>.mjpg`) and a follow-live stream (`/preview/active.mjpg`).
- Persist pairing auth, plus per-camera presets, sequences, and friendly names keyed by serial.

`DeviceManager` is the v2 addition.
v1 had a single implicit `DeviceSession` and no routing.
v2 keys sessions by serial, dispatches each action to the right session, applies the `device_id` resolution rules (0 cameras, 1 camera, 2+ cameras) documented in `PROTOCOL.md`, and rebuilds the `devices[]` array for every state broadcast.

Main libraries:

| Library | Use |
| --- | --- |
| OBSBOT `libdev` | Camera discovery and control. |
| Crow + standalone Asio | WebSocket and ordinary HTTP routes on `8765`. |
| nlohmann/json | Protocol encoding/decoding. |
| AVFoundation/CoreMedia/CoreVideo | UVC preview capture. |
| BSD sockets | True streaming MJPEG server on `8766`. |

### `apps/rc/`

Flutter controller app.

Targets:

- Web, served by the bridge at `http://<host>:8765/`.
- Android native.
- iOS native.

Responsibilities:

- Connect to `ws://<host>:8765/v1`.
- Send `hello` with a saved token when available.
- Pair with the bridge PIN when no valid token exists.
- Subscribe to state events.
- Render Simple mode (one-handed preset operation) and Advanced mode controls.
- In Advanced mode, render the v1.2 three-tab shell below the pinned live preview:
  - Joystick: analog `PtzPad` plus vertical zoom slider, inline P1 to P6 preset row, duration chips.
  - Buttons: 8-way hold-button pad plus vertical zoom slider, inline P1 to P6 preset row, duration chips.
  - Image: Auto-track / View / Tone / Exposure / Anti-flicker / White balance / Color sections with per-section Reset buttons.
- Render the live preview with an optional grid overlay (centre crosshair, attitude indicator that translates with pan/tilt and rotates with roll, rule of thirds, top-left Pan / Tilt readout). Toggles are persisted via SharedPreferences.
- Store the bridge address, token, selected move duration, grid toggles, and local UI preferences.
- Render MJPEG preview. Web uses an HTML `<img>` element because Flutter web image widgets do not decode multipart MJPEG streams.

The pair screen is built on the `forui` design system (`FScaffold` + `FHeader.nested` + `FButton`). The rest of the app is on Material widgets; the two coexist via a transparent `Material` shim where text inputs need a Material ancestor.

### Client shell (planned)

A macOS app that turns the live camera into one virtual webcam for OBS.
It is a WebSocket client of the bridge, the same as the phone, and it runs on the same Mac as the bridge.

Responsibilities:

- Connect to `ws://localhost:8765/v1`, authenticate with the token read from `auth.json`, and subscribe.
- Consume `http://localhost:8766/preview/active.mjpg?t=<token>`.
- Republish those frames as a macOS virtual camera named "OBSBOT Bridge".
- Re-point its frame source when `active_device_id` changes in a state event.
- Show a minimal status UI: connection state, live camera name, a start/stop toggle, and a link to the bridge window.

The shell is not built yet.
`CLIENT_SHELL_DESIGN.md` covers the two implementation paths (OBS Browser Source first, CoreMediaIO Camera Extension later) and the open questions around signing and notarization.
The control surface stays on the phone; the shell adds no camera controls of its own.

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

Only `pair` and `ping` are accepted before authentication. State broadcasts are sent only to authenticated WebSocket connections.

## Command Flow

```
WebSocket client
  -> JSON command (carries device_id)
  -> Crow WS handler
  -> protocol.cpp dispatch
  -> DeviceManager resolves device_id -> DeviceSession
  -> DeviceSession command queue
  -> that camera's SDK worker thread
  -> libdev synchronous call
  -> ack to requesting client
  -> state broadcast to authenticated clients
```

`DeviceManager` resolves `device_id` before dispatch.
An omitted `device_id` routes to the sole camera when exactly one is attached, and is rejected (`no_device` or `device_required`) otherwise, per `PROTOCOL.md`.
Bridge-scoped actions (`ping`, `hello`, `pair`, `subscribe`) skip resolution.

All SDK calls for a camera go through that camera's `DeviceSession`.
Each session's worker thread owns its own `Device` pointer, so SDK callbacks and WebSocket I/O never call into `libdev` directly, and two cameras never contend on one thread.

The bridge polls each connected camera's logical state every 500 ms.
It also pushes a full state broadcast after successful commands and on device plug/unplug.
A plug or unplug rebuilds the `devices[]` array; there is no targeted delta event.

## Preview Flow

```
AVFoundation capture session (one per camera)
  -> latest JPEG frame in memory, per camera
  -> MjpegServer on port 8766
  -> GET /preview/<sn>.mjpg?t=<token>      (one fixed camera)
     GET /preview/active.mjpg?t=<token>    (follows active_device_id)
  -> multipart/x-mixed-replace stream
  -> phone preview widget, or the client shell feeding OBS
```

The per-serial path streams one fixed camera and is what the phone shows when the operator has a camera selected.
The `active.mjpg` path streams whichever camera is live and re-points when `active_device_id` changes, which is what the client shell consumes so OBS sees a single stable device.
There is no Crow MJPEG route on `8765`; the working preview server is the BSD-socket server on `8766`.

## Sequence Flow

Sequences live in the bridge so they keep running if the phone disconnects.
In v2 each sequence is scoped to one camera, keyed by serial, and driven by that camera's `DeviceSession` and MotionPlanner.
Two cameras can run different sequences at the same time without interfering.

- `sequence.set` updates the active sequence for the target camera and persists it to `sequence.json` under that serial.
- `sequence.start` starts that camera's sequence thread.
- `sequence.stop` stops it.
- `sequence.save_as`, `sequence.load`, and `sequence.delete` manage that camera's saved library in `sequences.json`.

Cross-camera sequences (one sequence that drives more than one camera) are out of scope for v2.0 and noted as a future candidate in `PROTOCOL.md`.

Each step contains:

```json
{ "preset_id": 1, "seconds": 20, "transition_ms": 5000 }
```

`seconds` is how long the camera holds at the preset. `transition_ms` is how long the bridge takes to move from the previous preset to this one (`0` is instant). `transition_ms` replaced the v1.1 `speed: "instant" | "slow" | "medium" | "fast"` enum. The bridge still accepts the old `speed` field on disk via `legacy_speed_to_ms()` so existing `sequences.json` files keep working.

Loop modes:

- `once`
- `forward`
- `ping_pong`

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

The script builds C++, Flutter web, Flutter macOS, copies the required artifacts, then ad-hoc signs the final bundle.

`scripts/package-mac-release.sh` wraps that bundle in a GitHub Release ZIP and writes a SHA-256 checksum in `dist/`. The ZIP includes the SDK runtime dylib inside the `.app`; the full SDK package is not committed to git.

## Current Non-Goals

- Public internet access.
- TLS termination inside the bridge.
- Cross-camera sequences (a single sequence driving more than one camera). Per-camera sequences ship in v2.0; cross-camera is a v2.1+ candidate.
- A signed and notarized CoreMediaIO Camera Extension for the client shell. v2.0 ships the OBS Browser Source path first; see `CLIENT_SHELL_DESIGN.md`.
- Windows/Linux bridge packaging.
- Firmware updates.
- OBSBOT camera families that have not been validated on real hardware.
