# Protocol

Version: `2.0`

Transport: JSON UTF-8 text frames over WebSocket.

v2.0 is a multi-camera redesign.
One bridge now supervises N cameras attached to the same host over USB.
Every command and every state snapshot is addressed by `device_id`.
This is a major-version break: a v1 client will not read a v2 state event correctly.
See [Compatibility](#compatibility) for what breaks and why we accept it.

The Dart mirror of this wire format lives in `packages/obsbot_protocol/`:

- `lib/src/bridge_state.dart` - the `BridgeState` envelope (`devices[]`, `active_device_id`, `version`, `mix`).
- `lib/src/device_state.dart` - one `DeviceState` per camera.
- `lib/src/mix_state.dart` - the `MixState` block and its `MixCue` list.

If the wire and the Dart types ever disagree, the Dart types win on field names, because that is what ships in the app.

## Transport

Default URLs:

```text
ws://<bridge-host>:8765/v1
```

The bridge also exposes:

| HTTP endpoint | Purpose |
| --- | --- |
| `GET /health` | Returns `ok`. |
| `POST /pair` | Exchanges a PIN for a token. Used by web clients when convenient. |
| `GET /` | Serves the bundled Flutter web remote. |
| `GET :8766/preview/<device_id>.mjpg?t=<token>` | MJPEG preview for one camera. |
| `GET :8766/preview/active.mjpg?t=<token>` | MJPEG preview that follows the live camera. |

The MJPEG server is on `ws_port + 1` (`8766`) because Crow buffers `response.write()` until the handler returns, which breaks multipart streaming.
See [MJPEG preview](#mjpeg-preview) for the per-camera and follow-active paths.

## Authentication

Auth is bridge-wide, not per camera.
One PIN and one token set cover every attached camera.
Pairing once gives a client control of all cameras on that bridge.
There is no per-device authorization layer in v2.0.

Only these WebSocket actions are accepted before authentication:

- `pair`
- `ping`

All camera commands, `hello`, `subscribe`, the `device.*` / `mix.*` / `library.*` actions, and state broadcasts require a valid token.

### Pair With PIN

The bridge app displays a 6-digit PIN when the user clicks `Reveal`.

Client:

```json
{ "action": "pair", "id": "pair-1", "pin": "123456" }
```

Success:

```json
{
  "type": "ack",
  "id": "pair-1",
  "ok": true,
  "token": "32-byte-hex-token"
}
```

Failure:

```json
{
  "type": "ack",
  "id": "pair-1",
  "ok": false,
  "err": "auth_failed",
  "msg": "wrong PIN"
}
```

The token is long-lived until pairing is reset in the bridge app.
Resetting pairing invalidates every issued token, for every camera, at once.

### HTTP Pairing Endpoint

Request:

```http
POST /pair
Content-Type: application/json

{"pin":"123456"}
```

Success:

```json
{"ok":true,"token":"32-byte-hex-token"}
```

Failure:

```json
{"ok":false,"err":"wrong PIN"}
```

### Hello

Client:

```json
{
  "action": "hello",
  "id": "1",
  "token": "32-byte-hex-token",
  "client": { "name": "Open OBSBOT Remote", "version": "2.0.0" }
}
```

Success:

```json
{
  "type": "ack",
  "id": "1",
  "ok": true,
  "server": { "version": "2.0.0", "protocol": "2.0", "host": "obsbot-bridge" },
  "active_device_id": "RMOWLHH3281PMV",
  "devices": [
    {
      "device_id": "RMOWLHH3281PMV",
      "sn": "RMOWLHH3281PMV",
      "model_display": "Tiny 2 Lite",
      "firmware": "6.2.8.1",
      "friendly_name": "Vocal",
      "connected": true,
      "run_status": "run",
      "active": true
    }
  ]
}
```

`hello` is bridge-scoped.
It ignores any `device_id` on the message and returns `active_device_id` plus the full device summary list.
The `devices` array here is the same summary shape returned by [`device.list`](#devicelist).

Missing or invalid token:

```json
{
  "type": "ack",
  "id": "1",
  "ok": false,
  "err": "auth_required",
  "msg": "send {action:'pair', pin:<6-digit>} or {action:'hello', token:<token>} first"
}
```

### Subscribe

Client:

```json
{ "action": "subscribe", "id": "2" }
```

Response:

```json
{ "type": "ack", "id": "2", "ok": true }
```

The ack is immediately followed by a full `state` event covering every attached camera.
Subscription is implicit per authenticated connection and is bridge-wide.
A client subscribes once and receives state for all cameras, including cameras that attach later.

### Ping

Client:

```json
{ "action": "ping", "id": "3" }
```

Response:

```json
{ "type": "pong", "id": "3", "ts": 1746086400123 }
```

## `device_id`

`device_id` is the camera's serial number as reported by libdev, for example `RMOWLHH3281PMV`.
It is stable across unplug and replug, and across USB ports.
The same string is used as a key in several places:

- the addressing key on every action and every entry in the state event's `devices[]` array.
- the persistence key inside `sequence.json`, `sequences.json`, and `device_names.json`.
- the path component in the per-camera MJPEG URL, `:8766/preview/<device_id>.mjpg`.

Presets are not keyed by `device_id` on disk; they live on the camera hardware and are read back per camera.
Because `device_id` is the camera's own serial, a client can save a preset against a camera, unplug it, move it to another port or another day, plug it back in, and the bridge re-attaches the saved sequences to the same physical camera without any re-pairing.

## State Event

The bridge broadcasts full snapshots after commands, on poll ticks (about every 500 ms), and right after subscribe.
The payload is the `BridgeState` envelope.
It carries the protocol `version`, a `ts` millisecond timestamp, the `active_device_id`, a `devices` array, and a `mix` block for the cross-camera sequencer.
Each entry in `devices` is one camera's full snapshot, keyed by its `device_id`.
The `mix` block is documented under [The `mix` block](#the-mix-block).

The example below shows a host with two Tiny 2 Lite cameras attached, one named "Vocal" and one named "GGS".
The first is live (`active_device_id` matches its `device_id`).

```json
{
  "event": "state",
  "version": "2.0",
  "ts": 1746086400123,
  "active_device_id": "RMOWLHH3281PMV",
  "devices": [
    {
      "device_id": "RMOWLHH3281PMV",
      "device": {
        "sn": "RMOWLHH3281PMV",
        "model_display": "Tiny 2 Lite",
        "firmware": "6.2.8.1",
        "connected": true,
        "run_status": "run",
        "friendly_name": "Vocal"
      },
      "ptz":  { "yaw": 0.0, "pitch": -0.1, "roll": 0.0 },
      "zoom": { "value": 1.0, "min": 1.0, "max": 2.0 },
      "ai":   { "mode": "none", "sub_mode": "normal", "enabled": false },
      "image": {
        "hdr": false, "fov": 86,
        "brightness": 50, "contrast": 50, "saturation": 50, "sharpness": 50,
        "face_ae": true, "face_focus": true,
        "auto_focus": true, "manual_focus": 0,
        "flip_h": false,
        "exposure_mode": "auto", "ev_bias": 0.0,
        "anti_flicker": "off",
        "wb_auto": true, "wb_kelvin": 4700
      },
      "presets": [
        { "id": 2, "name": "", "yaw": 0.6, "pitch": 0.0, "roll": 0.0, "zoom": 1.7 }
      ],
      "active_preset_id": -1,
      "sequence": {
        "running": false, "step_index": -1,
        "elapsed_s": 0, "total_s": 0,
        "mode": "forward", "phase": "holding",
        "available": ["Main"], "loaded": "Main",
        "steps": [ { "preset_id": 0, "seconds": 30, "transition_ms": 5000 } ]
      }
    },
    {
      "device_id": "RMOWLHHC233LOQ",
      "device": {
        "sn": "RMOWLHHC233LOQ",
        "model_display": "Tiny 2 Lite",
        "firmware": "6.2.8.1",
        "connected": true,
        "run_status": "run",
        "friendly_name": "GGS"
      },
      "ptz":  { "yaw": 12.5, "pitch": -8.0, "roll": 0.0 },
      "zoom": { "value": 1.4, "min": 1.0, "max": 2.0 },
      "ai":   { "mode": "human", "sub_mode": "upper_body", "enabled": true },
      "image": {
        "hdr": false, "fov": 78,
        "brightness": 50, "contrast": 50, "saturation": 50, "sharpness": 50,
        "face_ae": false, "face_focus": false,
        "auto_focus": true, "manual_focus": 50,
        "flip_h": false,
        "exposure_mode": "auto", "ev_bias": 0.0,
        "anti_flicker": "off",
        "wb_auto": true, "wb_kelvin": 4700
      },
      "presets": [
        { "id": 0, "name": "Podium", "yaw": 0.0, "pitch": 0.0, "roll": 0.0, "zoom": 1.0 }
      ],
      "active_preset_id": 0,
      "sequence": {
        "running": false, "step_index": -1,
        "elapsed_s": 0, "total_s": 0,
        "mode": "forward", "phase": "holding",
        "available": [], "loaded": "",
        "steps": []
      }
    }
  ],
  "mix": {
    "running": false,
    "cue_index": -1,
    "cue_count": 2,
    "phase": "holding",
    "elapsed_s": 0,
    "total_s": 0,
    "mode": "forward",
    "loaded": "Sunday service",
    "available": ["Sunday service"],
    "cues": [
      { "camera_sn": "RMOWLHH3281PMV", "preset_id": 0, "move_ms": 0, "hold_s": 20, "transition": "cut" },
      {
        "camera_sn": "RMOWLHHC233LOQ", "preset_id": 1, "move_ms": 3000, "hold_s": 15, "transition": "fade",
        "meanwhile": { "camera_sn": "RMOWLHH3281PMV", "preset_id": 2, "move_ms": 2000 }
      }
    ]
  }
}
```

An empty device list (`"devices": []`) is legal and means no camera is attached.
`active_device_id` is an empty string when no camera is live.

### Per-device snapshot fields

Each entry in `devices[]` carries one camera's full state.

| Block | Field | Meaning |
| --- | --- | --- |
| (top) | `device_id` | The camera's serial. Canonical addressing key. Equal to `device.sn`. |
| `device` | `sn` | Same serial. Kept alongside `device_id` so existing UI reading `device.sn` keeps working. |
| `device` | `model_display` | Human label, e.g. `Tiny 2 Lite`. |
| `device` | `firmware` | Firmware version string. |
| `device` | `connected` | Whether libdev currently sees the camera. |
| `device` | `run_status` | `run`, `sleep`, `privacy`, or `unknown`. |
| `device` | `friendly_name` | Operator name set via `device.rename`. Empty when unset; UI falls back to model plus last-4 of SN. |
| `ptz` | `yaw` / `pitch` / `roll` | Degrees. Positive yaw pans right in the viewer frame, positive pitch tilts up, positive roll rotates clockwise from the operator's point of view. |
| `zoom` | `value` / `min` / `max` | Float multiplier and the camera's range. Tiny 2 Lite is `1.0` to `2.0`. |
| `ai` | `mode` / `sub_mode` / `enabled` | AI tracking mode, human sub-mode, and whether tracking is active. |
| `image` | (see below) | One snapshot of every image setting. |
| (top) | `presets` | This camera's saved P1 to P6 poses. Scoped to this `device_id`. |
| (top) | `active_preset_id` | The preset last recalled on this camera. `-1` after any manual PTZ. |
| (top) | `sequence` | The sequence state for this camera. Sequences are per-device in v2.0. |

The `image` block carries every camera-image setting in one snapshot: `hdr`, `fov`, `brightness`, `contrast`, `saturation`, `sharpness`, `face_ae`, `face_focus`, `auto_focus`, `manual_focus`, `flip_h`, `exposure_mode`, `ev_bias`, `anti_flicker`, `wb_auto`, `wb_kelvin`.

`sequence.phase` is `"moving"` while the bridge MotionPlanner is physically driving toward the current step's pose, and `"holding"` while the stay-timer (`step.seconds`) is counting down.
Idle and instant-transition steps (`transition_ms == 0`) report `"holding"`.
Clients can use this for UI affordances such as a "moving..." chip on the step card.

Because each camera owns its own MotionPlanner worker thread in the bridge, one camera's `phase` moves independently of another's.
A slow 30-second zoom on camera A does not stall a preset recall on camera B.

### The `mix` block

The `mix` block reports the cross-camera sequencer.
It is bridge-level, not per camera, so there is exactly one `mix` block per state event.
A v1 bridge and a v2 bridge that predates the mixer omit it; clients treat an absent block as an empty, idle mix.

| Field | Meaning |
| --- | --- |
| `running` | True while the mix engine is running. |
| `cue_index` | Index of the cue on air, or `-1` when idle. |
| `cue_count` | Number of cues in the authored list. |
| `phase` | `"moving"` while the live move is in flight, `"holding"` while dwelling on the shot. |
| `elapsed_s` | Seconds elapsed in the current cue's hold. |
| `total_s` | The current cue's `hold_s`. |
| `mode` | Loop mode: `once`, `forward`, or `ping_pong`. |
| `loaded` | Name of the loaded library entry, or `""` for unsaved scratch. |
| `cues` | The authored cue list. Each entry is a `MixCue`; see [`mix.set`](#mixset) for the shape. |
| `available` | Saved mix names in the library. |

### Changes vs v1

- `devices` is a new top-level array.
  Each entry is what v1 shipped at the top level, plus a `device_id` key and a `device.friendly_name`.
- `active_device_id` is new.
  It names the camera routed to the `active.mjpg` preview and, in later versions, to the virtual webcam.
  Empty string when no camera is live.
- `version` is new, always `"2.0"` from a v2 bridge.
- `ts` is new, a millisecond wall-clock timestamp stamped on every broadcast.
- `mix` is new. It carries the cross-camera sequencer state and is absent on bridges that predate the mixer.
- The v1 top-level `device`, `ptz`, `zoom`, `ai`, `image`, `presets`, `active_preset_id`, and `sequence` keys are gone from the top level.
  They now appear only inside each `devices[]` entry.
- `image.hue` is dropped. No client ever read it.
- `ai.tracking_mode` is dropped. No client ever read it.
- `sequence.loop`, the legacy boolean, is dropped. It was superseded by `sequence.mode`.

## Actions

Every camera command may carry an optional `device_id` naming the camera it targets:

```json
{ "action": "ptz.angle", "id": "7", "device_id": "RMOWLHH3281PMV", "yaw": 10.0, "pitch": 0.0, "roll": 0.0 }
```

### `device_id` resolution

When a camera command omits `device_id`, the bridge resolves the target by how many cameras are attached:

| Attached cameras | Behaviour |
| --- | --- |
| 0 | ack `ok:false`, `err:"no_device"`. |
| 1 | Route to that camera. This is what keeps a v1 single-camera client working unchanged. |
| 2+ | ack `ok:false`, `err:"device_required"`, `msg:"device_id is required when multiple cameras are attached"`. |

An unknown `device_id` (no attached camera has that serial) returns ack `ok:false`, `err:"not_found"`.

### Bridge-scoped actions

These actions act on the bridge itself, not on a single camera.
They ignore any `device_id` on the message:

- `ping`
- `hello`
- `pair`
- `subscribe`

The `device.*` actions below manage the device set rather than drive a gimbal; they are bridge-scoped but read the `device_id` argument as their subject.
The `mix.*` cross-camera sequencer and `library.export` / `library.import` are bridge-scoped as well. They name their subjects (a camera serial inside a cue, a saved entry's `name`) in the arguments rather than through a top-level `device_id`.

### Command ack shape

All camera commands return an ack:

```json
{ "type": "ack", "id": "<id>", "ok": true }
```

Failure:

```json
{ "type": "ack", "id": "<id>", "ok": false, "err": "<code>", "msg": "human-readable" }
```

### PTZ

Absolute move:

```json
{
  "action": "ptz.angle",
  "id": "10",
  "device_id": "RMOWLHH3281PMV",
  "yaw": 30.0,
  "pitch": -15.0,
  "roll": 0,
  "duration_ms": 5000
}
```

`duration_ms` is optional.
When omitted or `0`, the camera moves to the target as fast as the gimbal can.
When greater than zero, the bridge's motion planner eases the gimbal over that many milliseconds with an ease-in-out-sine curve.

Velocity move (joystick / hold buttons):

```json
{
  "action": "ptz.velocity",
  "id": "11",
  "device_id": "RMOWLHH3281PMV",
  "yaw_speed": 60.0,
  "pitch_speed": -30.0,
  "roll_speed": 0
}
```

Stop:

```json
{ "action": "ptz.stop", "id": "12", "device_id": "RMOWLHH3281PMV" }
```

Recenter:

```json
{ "action": "ptz.recenter", "id": "13", "device_id": "RMOWLHH3281PMV" }
```

Manual PTZ commands disable AI tracking on that camera before moving the gimbal.

### Zoom

Set zoom:

```json
{ "action": "zoom.set", "id": "20", "device_id": "RMOWLHH3281PMV", "value": 1.5, "duration_ms": 8000, "final": true }
```

`duration_ms` works the same as on `ptz.angle`.
`final: true` marks the value as the user's release-of-slider terminal value, bypassing the mid-drag coalesce.
Most callers send `final: false` (the default) during drag and `final: true` on release.

Zoom uses the float-API `cameraSetZoomAbsoluteR(value, -1)`.
On Tiny 2 Lite the uint-API `cameraSetZoomWithSpeedAbsoluteR` does not honor sub-percent targets and gets stuck around 1.33x, so the bridge avoids it.

Zoom at a fixed speed:

```json
{ "action": "zoom.set_smooth", "id": "21", "device_id": "RMOWLHH3281PMV", "value": 1.5, "speed": 5 }
```

`value` clamps to the camera's zoom range and `speed` is `1..10`.
This action calls `cameraSetZoomAbsoluteR(value, speed)` directly, with no motion planner.
The Tiny 2 Lite firmware ignores the speed argument, so the phone app drives smooth zoom through `zoom.set` with a `duration_ms` instead; `zoom.set_smooth` is kept for callers that want the SDK's own speed path.

### AI

Set mode:

```json
{ "action": "ai.set_mode", "id": "30", "device_id": "RMOWLHH3281PMV", "mode": "human", "sub_mode": "upper_body" }
```

Supported `mode` values:

- `none`
- `human`
- `hand`
- `group`
- `whiteboard`
- `desk`

Supported `sub_mode` values for `human`:

- `normal`
- `upper_body`
- `close_up`
- `head_hide`
- `lower_body`

Enable or disable tracking without changing the mode:

```json
{ "action": "ai.set_enabled", "id": "31", "device_id": "RMOWLHH3281PMV", "enabled": true }
```

This calls `aiSetEnabledR` on the current mode.
The phone app turns tracking off by setting `mode` to `none` via `ai.set_mode`, so `ai.set_enabled` is a lower-level toggle most clients do not need.

### Image

HDR:

```json
{ "action": "image.set_hdr", "id": "40", "device_id": "RMOWLHH3281PMV", "enabled": true }
```

HDR is debounced by the bridge for 3 seconds, per camera.

FOV:

```json
{ "action": "image.set_fov", "id": "41", "device_id": "RMOWLHH3281PMV", "fov": 86 }
```

Supported FOV values: `86` (Wide), `78` (Normal), `65` (Narrow).

Color controls:

```json
{
  "action": "image.set_color",
  "id": "42",
  "device_id": "RMOWLHH3281PMV",
  "brightness": 55,
  "contrast": 50,
  "saturation": 60,
  "sharpness": 50
}
```

Send any subset.
Values are `0..100`.
The Image tab's per-section Reset button writes `brightness=50, contrast=50, saturation=50, sharpness=50` in a single call.

Face AE:

```json
{ "action": "image.set_face_ae", "id": "43", "device_id": "RMOWLHH3281PMV", "enabled": true }
```

Face focus:

```json
{ "action": "image.set_face_focus", "id": "44", "device_id": "RMOWLHH3281PMV", "enabled": true }
```

Horizontal flip:

```json
{ "action": "image.set_flip_h", "id": "45", "device_id": "RMOWLHH3281PMV", "enabled": true }
```

#### Exposure

Auto or manual exposure:

```json
{ "action": "image.set_exposure_mode", "id": "46", "device_id": "RMOWLHH3281PMV", "mode": "auto" }
```

`mode` is `"auto"` or `"manual"`.
Verified working on Tiny 2 Lite firmware 6.2.8.1; the SDK header's "tail air" tag is misleading.

Exposure compensation (EV bias):

```json
{ "action": "image.set_ev_bias", "id": "47", "device_id": "RMOWLHH3281PMV", "bias": -0.7 }
```

`bias` is a float in the range `-3.0` to `+3.0`.
The bridge rounds to the nearest 1/3 stop and writes the SDK's `DevAEEvBiasType` enum.

Anti-flicker:

```json
{ "action": "image.set_anti_flicker", "id": "48", "device_id": "RMOWLHH3281PMV", "mode": "60" }
```

`mode` is `"off"`, `"50"` (50 Hz), `"60"` (60 Hz), or `"auto"`.
Maps to the SDK's `PowerLineFreqType`.

White balance:

```json
{ "action": "image.set_wb_auto", "id": "49", "device_id": "RMOWLHH3281PMV", "enabled": true }
{ "action": "image.set_wb_temp", "id": "4a", "device_id": "RMOWLHH3281PMV", "kelvin": 5500 }
```

`kelvin` clamps to `2800..6500`.
Setting a manual temperature also turns auto off, mirroring OBSBOT Center's behavior.

Re-read live exposure / anti-flicker / WB state from the camera and re-stamp the bridge's snapshot:

```json
{ "action": "image.refresh", "id": "4b", "device_id": "RMOWLHH3281PMV" }
```

Reads back `exposure_mode`, `ev_bias`, `anti_flicker`, and `wb_auto` plus `wb_kelvin` via the SDK getters and updates the snapshot.
A state event flows to all subscribers with the fresh values.
Use it when another control app (OBSBOT Center, a different phone) may have changed values on that camera while this client was disconnected.

### System

Sleep or wake:

```json
{ "action": "system.run_status", "id": "50", "device_id": "RMOWLHH3281PMV", "status": "sleep" }
{ "action": "system.run_status", "id": "51", "device_id": "RMOWLHH3281PMV", "status": "run" }
```

### Presets

Presets are scoped per camera.
Each camera owns its own P1 to P6 slots, stored on the camera hardware (`aiAddGimbalPresetR`) and read back per camera, so there is no preset file on disk.

Save current camera position:

```json
{ "action": "preset.save", "id": "60", "device_id": "RMOWLHH3281PMV", "preset_id": 1, "name": "Wide" }
```

Recall:

```json
{ "action": "preset.recall", "id": "61", "device_id": "RMOWLHH3281PMV", "preset_id": 1, "duration_ms": 5000 }
```

Delete:

```json
{ "action": "preset.delete", "id": "62", "device_id": "RMOWLHH3281PMV", "preset_id": 1 }
```

`duration_ms` is optional.
When omitted or `0`, the bridge uses the camera's hardware preset recall (fastest path).
When greater than zero, the bridge runs the motion planner from the current position to the saved preset position over that many milliseconds.

Preset lists arrive in each device's `presets` array in the state event.
There is no separate `preset.list` action.

### Sequences

Sequences are scoped per camera and run inside the bridge, so they keep going if the phone disconnects.
Each camera has its own active sequence and its own saved library, keyed by serial in `sequence.json` and `sequences.json`.

Set active sequence:

```json
{
  "action": "sequence.set",
  "id": "70",
  "device_id": "RMOWLHH3281PMV",
  "mode": "ping_pong",
  "steps": [
    { "preset_id": 1, "seconds": 10, "transition_ms": 2000 },
    { "preset_id": 2, "seconds": 15, "transition_ms": 5000 }
  ]
}
```

Each step holds at its preset for `seconds` and then transitions to the next preset over `transition_ms` milliseconds.
The bridge clamps `seconds` to a minimum of 3.

For back-compat the bridge also accepts the old `speed: "instant" / "slow" / "medium" / "fast" / "cinema"` field on sequence steps.
It is mapped to a roughly-equivalent `transition_ms` so existing `sequences.json` files keep working.
New writers should always emit `transition_ms`.

Start:

```json
{ "action": "sequence.start", "id": "71", "device_id": "RMOWLHH3281PMV" }
```

Stop:

```json
{ "action": "sequence.stop", "id": "72", "device_id": "RMOWLHH3281PMV" }
```

Save:

```json
{
  "action": "sequence.save_as",
  "id": "73",
  "device_id": "RMOWLHH3281PMV",
  "name": "Main",
  "mode": "forward",
  "steps": [
    { "preset_id": 1, "seconds": 20, "transition_ms": 5000 }
  ]
}
```

Load:

```json
{ "action": "sequence.load", "id": "74", "device_id": "RMOWLHH3281PMV", "name": "Main" }
```

Delete:

```json
{ "action": "sequence.delete", "id": "75", "device_id": "RMOWLHH3281PMV", "name": "Main" }
```

Supported sequence `mode` values:

- `once`
- `forward`
- `ping_pong`

Minimum step `seconds` is 3.

### Device management (new in v2.0)

The `device.*` actions manage the device set itself.

#### `device.list`

Returns a summary of every camera the bridge sees, plus which one is live.
Cheaper than a full `state` event when a client only needs the picker contents.

```json
{ "action": "device.list", "id": "1" }
```

Response:

```json
{
  "type": "ack",
  "id": "1",
  "ok": true,
  "devices": [
    {
      "device_id": "RMOWLHH3281PMV",
      "sn": "RMOWLHH3281PMV",
      "model_display": "Tiny 2 Lite",
      "firmware": "6.2.8.1",
      "friendly_name": "Vocal",
      "connected": true,
      "run_status": "run",
      "active": true
    }
  ],
  "active_device_id": "RMOWLHH3281PMV"
}
```

Each summary entry carries `active: true` for the live camera, and the top-level `active_device_id` names it as well.

#### `device.set_active`

Marks a camera live.
This sets which camera the MJPEG `active.mjpg` endpoint follows and which one `active_device_id` reports in the state event.
The bridge persists the choice to `active.json`, and wakes the target first if it is asleep so OBS does not pull a black stream.

```json
{ "action": "device.set_active", "id": "2", "device_id": "RMOWLHHC233LOQ", "fade_ms": 500 }
```

Response:

```json
{ "type": "ack", "id": "2", "ok": true }
```

The switch is a hard cut by default.
Pass `fade_ms` greater than zero to crossfade over that many milliseconds on the `active.mjpg` stream: the bridge freezes the outgoing camera's frame and dissolves it into the incoming camera's live frames.
The value is clamped to `0..5000`.
As a shorthand, `"transition": "fade"` with no `fade_ms` uses a 500 ms crossfade, and `"transition": "cut"` (the default) is an instant switch.
A disconnected or unknown `device_id` is rejected with `err:"not_found"`.
On success the bridge broadcasts a state event with the new `active_device_id` so every client, including the OBS Browser Source, re-points immediately.

#### `device.rename`

Sets the operator-facing friendly name for a camera.
Persisted to `device_names.json`, keyed by serial, so it survives reconnect.

```json
{ "action": "device.rename", "id": "3", "device_id": "RMOWLHH3281PMV", "name": "Vocal" }
```

Response:

```json
{ "type": "ack", "id": "3", "ok": true }
```

An empty `name` clears the friendly name, and the UI falls back to model plus last-4 of SN.
Names are trimmed of surrounding whitespace and capped at 60 characters.

### Mix sequencer (new in v2)

The mix sequencer runs a timeline of cross-camera cues on the bridge.
Unlike a per-camera `sequence`, a cue names which camera goes on air and can move that camera live while it is the program feed.
It is bridge-level: there is one mix, not one per camera, and the actions carry no `device_id`.
The live status and the authored cue list ride in the state event's [`mix` block](#the-mix-block).

A cue is a `MixCue`:

| Field | Meaning |
| --- | --- |
| `camera_sn` | Program camera for this cue. Its serial. |
| `preset_id` | Preset to recall on the program camera when the cue goes on air. `0..5` are P1..P6. A value `< 0` holds the current shot (cut to the camera without moving it). |
| `move_ms` | Live move duration for the recall, in milliseconds. `0` is an instant snap. The camera moves on air. |
| `hold_s` | Seconds to dwell on the shot after the move lands. Minimum `1`. |
| `transition` | How the program switches to this cue: `"cut"` (default, instant) or `"fade"` (crossfade over 500 ms). |
| `meanwhile` | Optional. Pre-positions a second camera while this cue holds, so it is framed before a later cue cuts to it. Shape: `{ "camera_sn": <sn>, "preset_id": <slot>, "move_ms": <ms> }`. |

There is no on-air movement lock by design.
When a cue recalls a preset on the program camera, that camera pans or zooms live on air, which is the point of the mixer.

#### `mix.set`

Replaces the active scratch cue list and loop mode.
The bridge persists the scratch to `mix.json` and broadcasts a fresh state event with the new `mix.cues`.

```json
{
  "action": "mix.set",
  "id": "80",
  "mode": "forward",
  "cues": [
    { "camera_sn": "RMOWLHH3281PMV", "preset_id": 0, "move_ms": 0, "hold_s": 20, "transition": "cut" },
    {
      "camera_sn": "RMOWLHHC233LOQ", "preset_id": 1, "move_ms": 3000, "hold_s": 15, "transition": "fade",
      "meanwhile": { "camera_sn": "RMOWLHH3281PMV", "preset_id": 2, "move_ms": 2000 }
    }
  ]
}
```

`mode` is `once`, `forward`, or `ping_pong`.

#### `mix.start` / `mix.stop`

```json
{ "action": "mix.start", "id": "81" }
{ "action": "mix.stop",  "id": "82" }
```

`mix.start` on an empty cue list acks `ok:false`, `err:"invalid_param"`.
While running, each cue switches the program to `camera_sn` (fading when `transition` is `"fade"`), recalls `preset_id` over `move_ms`, optionally drives the `meanwhile` camera, holds for `hold_s`, then advances by `mode`.
`mix.stop` ends the run and resets `cue_index` to `-1`.

#### `mix.save_as` / `mix.load` / `mix.delete`

The saved library lives in `mix_sequences.json`, keyed by name.

```json
{
  "action": "mix.save_as",
  "id": "83",
  "name": "Sunday service",
  "mode": "forward",
  "cues": [ { "camera_sn": "RMOWLHH3281PMV", "preset_id": 0, "move_ms": 0, "hold_s": 20, "transition": "cut" } ]
}
```

```json
{ "action": "mix.load",   "id": "84", "name": "Sunday service" }
{ "action": "mix.delete", "id": "85", "name": "Sunday service" }
```

`mix.save_as` writes the entry, marks it loaded, and copies its cues into the active scratch.
`mix.load` on a name that does not exist, and `mix.delete` on one that does not exist, both ack `ok:false`, `err:"not_found"`.
An empty `name` on `mix.save_as` acks `ok:false`, `err:"invalid_param"`.

### Library export and import (new in v2)

These two actions move the authored library between Macs.
The blob covers the per-camera saved sequences, the saved cross-camera mixes, and the friendly names.
Presets are not included, because they live on the camera hardware.

#### `library.export`

```json
{ "action": "library.export", "id": "90" }
```

Response:

```json
{
  "type": "ack",
  "id": "90",
  "ok": true,
  "library": {
    "sequences": { "RMOWLHH3281PMV": { "Main": { "mode": "forward", "steps": [] } } },
    "mix": { "Sunday service": { "mode": "forward", "cues": [] } },
    "names": { "RMOWLHH3281PMV": "Vocal" }
  }
}
```

`sequences` is the contents of `sequences.json`, `mix` is `mix_sequences.json`, and `names` is `device_names.json`.

#### `library.import`

```json
{ "action": "library.import", "id": "91", "library": { "sequences": {}, "mix": {}, "names": {} } }
```

The bridge merges each present key back into the matching file, with incoming entries winning per key.
Device names re-apply to live sessions right away; restored sequences hydrate on the next camera re-attach.
A missing or non-object `library` acks `ok:false`, `err:"invalid_param"`.

## MJPEG preview

Live preview is HTTP MJPEG (`multipart/x-mixed-replace`) on port `8766`, gated by the same token as the WebSocket.

| Path | Streams |
| --- | --- |
| `GET /preview/<device_id>.mjpg?t=<token>` | One specific camera, by serial. |
| `GET /preview/active.mjpg?t=<token>` | Whatever camera is currently live. |

The per-device path is what the phone remote uses when the operator has one camera selected.
It streams exactly that camera and never switches.

The `active.mjpg` path is what the OBS Browser Source consumes.
It streams whichever camera is currently marked live and re-resolves the source every frame, so when `active_device_id` changes the frame source swaps mid-stream without dropping the HTTP connection.
OBS keeps one stable capture running while the person on the phone changes which camera is on air.
During a crossfade switch (`device.set_active` with `fade_ms`), the bridge dissolves the outgoing camera's frozen frame into the incoming camera's live frames, so the transition is baked into the JPEG bytes OBS receives. The first take, when there is no outgoing frame, falls back to a fade from black.
A brief frozen frame across the swap is expected; see the open questions in [`CLIENT_SHELL_DESIGN.md`](CLIENT_SHELL_DESIGN.md#open-questions).

Request handling:

- A missing or invalid `?t=` token returns `401`.
- A path that is not a preview path, or a `/preview/<sn>.mjpg` for a serial no camera reports, returns `404`.
- A camera that has produced no frame yet (asleep, or still starting) returns `503` after a short wait.

A fixed per-serial stream ends when its camera detaches, so the client sees the stream close rather than a silent freeze.
The `active.mjpg` stream instead holds the connection open with the last frame when no camera is live, because OBS keeps that connection across cuts.

## Persistence

State lives under `~/Library/Application Support/Open OBSBOT Bridge/`.
v2 re-keys the per-camera files by serial so two cameras never share a sequence library.
The mix files are bridge-level, because a mix spans cameras.

| File | v1 shape | v2 shape |
| --- | --- | --- |
| `auth.json` | `{pin, tokens[]}` | unchanged, bridge-wide. |
| `sequence.json` | `{steps, mode}` | `{ "<sn>": {steps, mode} }` |
| `sequences.json` | `{ "<name>": {...} }` | `{ "<sn>": { "<name>": {...} } }` |
| `device_names.json` | (did not exist) | `{ "<sn>": "Vocal" }` |
| `active.json` | (did not exist) | `{ "active_device_sn": "RMOW..." }` |
| `mix.json` | (did not exist) | `{ mode, cues[] }` |
| `mix_sequences.json` | (did not exist) | `{ "<name>": { mode, cues[] } }` |

Presets are not on disk.
They live on the camera hardware (`aiAddGimbalPresetR`) and are read back per camera, so there is no preset file to key or migrate.

### Migration from v1

The v1 to v2 migration must never lose user data.

On load, the bridge detects a v1 file by structure, because v1 files carry no version field:

- `sequence.json` is v1 if it is a single sequence object with a top-level `steps` array rather than a per-serial map.
- `sequences.json` is v1 if its first value is a bare sequence rather than a per-serial map.

When a v1 file is detected, the bridge re-keys it under the serial of the first camera that attaches, then writes it back in v2 shape.
If zero cameras are attached at the moment a v1 file is read, the bridge holds the migration until the first camera attaches.
It does not discard the file and it does not guess a serial.

This means a user who ran v1 with one camera keeps every saved sequence when they upgrade, and those land under that camera's serial the first time it plugs in.
Presets need no migration; they were always on the camera hardware.

## Live camera lifecycle

`active_device_id` names the live camera.
Its lifecycle:

- It defaults to the first camera that attaches.
- It survives restarts via `active.json`.
- If the persisted active serial is not attached at boot, the bridge falls back to the first attached camera and rewrites `active.json`.
- If the live camera is unplugged while running, the bridge falls back to the first remaining camera, or to `""` if none remain, and broadcasts a state event.

## Error Codes

| Code | Meaning |
| --- | --- |
| `auth_required` | The connection has not presented a valid token. |
| `auth_failed` | PIN pairing failed. |
| `no_device` | A camera command omitted `device_id` and zero cameras are attached. |
| `device_required` | A camera command omitted `device_id` and two or more cameras are attached. |
| `not_found` | Unknown `device_id`, or a requested saved item (preset / sequence) does not exist. |
| `unsupported` | Unknown action, or the camera firmware rejected the SDK call. |
| `invalid_param` | Value is out of range or malformed. |
| `device_busy` | SDK command failed or the camera is held by another app. |
| `debounced` | Command was rejected by a timing debounce. |
| `internal` | Unexpected bridge or SDK failure. |

## Compatibility

v2.0 is a deliberate major-version break.

### v1 client against a v2 bridge

A v1 client breaks.
It reads camera state from the top-level `device`, `ptz`, `zoom`, and friends, and it reads the serial from `j.device.sn`.
In a v2 state event those top-level keys are gone; the data moved inside `devices[]`.
`j.device` is undefined, so the v1 client reads no camera and shows nothing.
This is accepted.
The web remote is served by the bridge, so a v2 bridge always serves a matching v2 web client; the only exposure is a stale native app build, which is expected to update.

### v2 client against a v1 bridge

A v2 client keeps working against a v1 bridge, by design.
`BridgeState.fromEvent` in `packages/obsbot_protocol/lib/src/bridge_state.dart` checks for the `devices` array.
When it is absent (a v1 state event has no `devices`), the parser treats the whole payload as one device, wraps it in a single-element `devices` list, and uses that device's serial as `active_device_id`.
The client then behaves as a normal single-camera controller.
This fallback exists so a v2 phone build can connect to a not-yet-upgraded bridge during a rollout without exploding.

Note one wire detail worth watching: the state event's discriminator is `"event": "state"`, consistent with v1 and with every other server push.
The doc comment in `bridge_state.dart` writes it as `"type": "state"`; that comment is illustrative and the wire uses `event`.
`BridgeState.fromEvent` keys off `devices` / `active_device_id` / `version`, not off the discriminator, so the mismatch is cosmetic.

## Not Implemented In The Current Bridge

These are plausible future protocol candidates but are not working commands today:

- `preset.list`, `preset.rename`, `preset.save_with`
- `preset.set_home`, `preset.recall_home`, `preset.reset_home`
- `ai.set_gesture`
- `image.set_focus`
- `system.set_sleep_timer`, `system.factory_reset`
- Delta events such as `state.delta` or `ptz_pos`.
- Async `device_changed`, `notify`, and `error` event types. Device attach and detach surface today as a fresh full `state` broadcast, not a targeted event.

Clients must ignore unknown fields in events and acks.
