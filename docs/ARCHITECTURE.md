# Architecture

Open OBSBOT Remote has two runtime products:

- `Open OBSBOT Bridge`: a macOS Flutter app that supervises a bundled C++ subprocess.
- `Open OBSBOT Remote`: the Flutter controller UI, built for web, Android, and iOS.

The bridge host stays connected to the OBSBOT camera over USB. Controller devices connect over the local network.

## System Overview

```
Controller device
  - Browser, Android app, or iOS app
  - Flutter UI
  - WebSocket JSON client
  - MJPEG preview viewer

        local LAN
        ws://<host>:8765/v1
        http://<host>:8766/preview.mjpeg?t=<token>

Bridge host
  - Open OBSBOT Bridge.app
  - Flutter supervisor UI
  - Bundled obsbot-bridge C++ subprocess
  - Bundled Flutter web build
  - Bundled libdev.dylib

        USB

OBSBOT camera
```

Default ports:

| Port | Purpose |
| --- | --- |
| `8765` | Crow HTTP/WebSocket server: `/v1`, `/health`, `/pair`, and static web remote assets. |
| `8766` | Hand-rolled BSD-socket MJPEG server for `/preview.mjpeg?t=<token>`. |

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
~/Library/Application Support/Open OBSBOT Bridge/sequence.json
~/Library/Application Support/Open OBSBOT Bridge/sequences.json
```

The `.app` is ad-hoc signed by `scripts/build-bridge-mac.sh`. Signing matters because macOS TCC camera permission must apply to the bundle and its subprocess.

### `apps/bridge_cpp/`

C++17 subprocess named `obsbot-bridge`.

Responsibilities:

- Load OBSBOT `libdev.dylib`.
- Detect the USB camera through the SDK.
- Own all SDK calls on a worker thread.
- Expose JSON-over-WebSocket control API at `/v1`.
- Serve `/health` and `/pair`.
- Serve the Flutter web build as static files from `/`.
- Capture UVC preview frames with AVFoundation.
- Stream MJPEG preview from the separate port.
- Persist pairing auth and sequence library.

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
  -> JSON command
  -> Crow WS handler
  -> protocol.cpp dispatch
  -> DeviceSession command queue
  -> SDK worker thread
  -> libdev synchronous call
  -> ack to requesting client
  -> state broadcast to authenticated clients
```

All SDK calls go through `DeviceSession`. The worker thread owns the active `Device` pointer. This keeps SDK callbacks and WebSocket I/O from calling into `libdev` directly.

The bridge polls logical camera state every 500 ms while a camera is connected. It also pushes state after successful commands and device plug/unplug events.

## Preview Flow

```
AVFoundation capture session
  -> latest JPEG frame in memory
  -> MjpegServer on port 8766
  -> GET /preview.mjpeg?t=<token>
  -> multipart/x-mixed-replace stream
  -> browser/native preview widget
```

There is no Crow MJPEG preview route on `8765`. The working preview stream is the socket server on `8766`.

## Sequence Flow

Sequences live in the bridge so they keep running if the phone disconnects.

- `sequence.set` updates the active sequence and persists it to `sequence.json`.
- `sequence.start` starts the bridge sequence thread.
- `sequence.stop` stops it.
- `sequence.save_as`, `sequence.load`, and `sequence.delete` manage the saved library in `sequences.json`.

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
- Multi-camera UI.
- Windows/Linux bridge packaging.
- Firmware updates.
- OBSBOT camera families that have not been validated on real hardware.
