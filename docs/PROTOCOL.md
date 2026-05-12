# Protocol

Version: `1`

Transport: JSON UTF-8 text frames over WebSocket.

Default URL:

```text
ws://<bridge-host>:8765/v1
```

The bridge also exposes:

| HTTP endpoint | Purpose |
| --- | --- |
| `GET /health` | Returns `ok`. |
| `POST /pair` | Exchanges a PIN for a token. Used by web clients when convenient. |
| `GET /` | Serves the bundled Flutter web remote. |
| `GET :8766/preview.mjpeg?t=<token>` | MJPEG preview stream on the next port up. |

## Conventions

- Client messages include `"action"`.
- Server responses include either `"type"` for direct responses or `"event"` for pushes.
- Every client message should include string `"id"`. The bridge echoes it in acks.
- Angles are in degrees. Positive yaw pans the camera right in the viewer frame. Positive pitch tilts the camera up. Positive roll rotates the gimbal clockwise from the operator's point of view.
- Zoom is a float multiplier. Clients should read `state.zoom.min` and `state.zoom.max`.
- Move durations use `duration_ms`. `0` means "instant" (camera hardware reaches the target as fast as it can). Any positive integer asks the bridge's motion planner to take that many milliseconds to reach the target, with an ease-in-out curve. This replaces the old `speed: "instant" / "slow" / "medium" / "fast" / "cinema"` enum from v1.1.
- Timestamps are Unix milliseconds.
- Unknown actions return `unsupported`.

## Authentication

Only these WebSocket actions are accepted before authentication:

- `pair`
- `ping`

All camera commands, `hello`, `subscribe`, and state broadcasts require a valid token.

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
  "client": { "name": "Open OBSBOT Remote", "version": "1.0.0" }
}
```

Success:

```json
{
  "type": "ack",
  "id": "1",
  "ok": true,
  "server": { "version": "1.0.0", "protocol": 1, "host": "obsbot-bridge" },
  "devices": [
    {
      "sn": "ABC12345678901",
      "model": "tiny2lite",
      "model_display": "Tiny 2 Lite",
      "firmware": "1.2.3.4",
      "connected": true
    }
  ]
}
```

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

The ack is immediately followed by a full `state` event. Subscription is implicit per authenticated connection.

### Ping

Client:

```json
{ "action": "ping", "id": "3" }
```

Response:

```json
{ "type": "pong", "id": "3", "ts": 1746086400123 }
```

## State Event

The bridge broadcasts full snapshots after commands, on poll ticks (about every 500 ms), and right after subscribe.

```json
{
  "event": "state",
  "ts": 1746086400123,
  "device": {
    "sn": "ABC12345678901",
    "model": "tiny2lite",
    "model_display": "Tiny 2 Lite",
    "firmware": "1.2.3.4",
    "connected": true,
    "run_status": "run"
  },
  "ptz": { "yaw": 12.5, "pitch": -8.0, "roll": 0.0 },
  "zoom": { "value": 1.4, "min": 1.0, "max": 2.0 },
  "ai": {
    "mode": "human",
    "sub_mode": "upper_body",
    "enabled": true,
    "tracking_mode": "standard"
  },
  "image": {
    "hdr": false,
    "fov": 86,
    "brightness": 50,
    "contrast": 50,
    "saturation": 50,
    "sharpness": 50,
    "hue": 50,
    "face_ae": false,
    "face_focus": false,
    "auto_focus": true,
    "manual_focus": 50,
    "flip_h": false,
    "exposure_mode": "auto",
    "ev_bias": 0.0,
    "anti_flicker": "off",
    "wb_auto": true,
    "wb_kelvin": 4700
  },
  "presets": [
    { "id": 0, "name": "Home", "yaw": 0, "pitch": 0, "roll": 0, "zoom": 1.0 }
  ],
  "active_preset_id": 0,
  "sequence": {
    "running": false,
    "step_index": -1,
    "elapsed_s": 0,
    "total_s": 0,
    "mode": "forward",
    "available": ["Main"],
    "loaded": "Main",
    "steps": [
      { "preset_id": 0, "seconds": 30, "transition_ms": 5000 }
    ]
  }
}
```

The `image` block carries every camera-image setting in one snapshot. The five fields at the bottom (`exposure_mode`, `ev_bias`, `anti_flicker`, `wb_auto`, `wb_kelvin`) were added in v1.2 to cover the exposure and white-balance section of the Image tab.

The `sequence.steps` array mirrors the active edit list so a returning client can hydrate the editor without re-fetching.

## Commands

All camera commands require authentication and return an ack:

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
  "yaw": 30.0,
  "pitch": -15.0,
  "roll": 0,
  "duration_ms": 5000
}
```

`duration_ms` is optional. When omitted or `0`, the camera moves to the target as fast as the gimbal can. When greater than zero, the bridge's motion planner eases the gimbal over that many milliseconds with an ease-in-out-sine curve.

Velocity move (joystick / hold buttons):

```json
{
  "action": "ptz.velocity",
  "id": "11",
  "yaw_speed": 60.0,
  "pitch_speed": -30.0,
  "roll_speed": 0
}
```

Stop:

```json
{ "action": "ptz.stop", "id": "12" }
```

Recenter:

```json
{ "action": "ptz.recenter", "id": "13" }
```

Manual PTZ commands disable AI tracking before moving the gimbal.

### Zoom

Set zoom:

```json
{ "action": "zoom.set", "id": "20", "value": 1.5, "duration_ms": 8000, "final": true }
```

`duration_ms` works the same as on `ptz.angle`. `final: true` marks the value as the user's release-of-slider terminal value, bypassing the mid-drag coalesce. Most callers send `final: false` (the default) during drag and `final: true` on release.

Zoom uses the float-API `cameraSetZoomAbsoluteR(value, -1)`. On Tiny 2 Lite the uint-API `cameraSetZoomWithSpeedAbsoluteR` does not honor sub-percent targets and gets stuck around 1.33x, so the bridge avoids it.

Set zoom with explicit SDK speed (back-compat with v1.1 clients):

```json
{ "action": "zoom.set_smooth", "id": "21", "value": 1.8, "speed": 5 }
```

`speed` is `1..10`. On Tiny 2 Lite the SDK ignores the speed param, so this is functionally the same as `zoom.set value=1.8`. Kept for protocol back-compat.

### AI

Set mode:

```json
{ "action": "ai.set_mode", "id": "30", "mode": "human", "sub_mode": "upper_body" }
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

Set enabled:

```json
{ "action": "ai.set_enabled", "id": "31", "enabled": true }
```

### Image

HDR:

```json
{ "action": "image.set_hdr", "id": "40", "enabled": true }
```

HDR is debounced by the bridge for 3 seconds.

FOV:

```json
{ "action": "image.set_fov", "id": "41", "fov": 86 }
```

Supported FOV values: `86` (Wide), `78` (Normal), `65` (Narrow).

Color controls:

```json
{
  "action": "image.set_color",
  "id": "42",
  "brightness": 55,
  "contrast": 50,
  "saturation": 60,
  "sharpness": 50
}
```

Send any subset. Values are `0..100`. The Image tab's per-section Reset button writes `brightness=50, contrast=50, saturation=50, sharpness=50` in a single call.

Face AE:

```json
{ "action": "image.set_face_ae", "id": "43", "enabled": true }
```

Face focus:

```json
{ "action": "image.set_face_focus", "id": "44", "enabled": true }
```

Horizontal flip:

```json
{ "action": "image.set_flip_h", "id": "45", "enabled": true }
```

#### Exposure (v1.2)

Auto or manual exposure:

```json
{ "action": "image.set_exposure_mode", "id": "46", "mode": "auto" }
```

`mode` is `"auto"` or `"manual"`. The SDK tags this as "tail air" only. The bridge attempts it on every camera and returns `ok=false err="unsupported"` if the firmware rejects, so the UI can grey out the control without crashing.

Exposure compensation (EV bias):

```json
{ "action": "image.set_ev_bias", "id": "47", "bias": -0.7 }
```

`bias` is a float in the range `-3.0` to `+3.0`. The bridge rounds to the nearest 1/3 stop and writes the SDK's `DevAEEvBiasType` enum (also tagged "tail air"). On unsupported cameras the bridge returns `unsupported` the same way.

Anti-flicker:

```json
{ "action": "image.set_anti_flicker", "id": "48", "mode": "60" }
```

`mode` is `"off"`, `"50"` (50 Hz), `"60"` (60 Hz), or `"auto"`. Maps to the SDK's `PowerLineFreqType`.

White balance:

```json
{ "action": "image.set_wb_auto", "id": "49", "enabled": true }
{ "action": "image.set_wb_temp", "id": "4a", "kelvin": 5500 }
```

`kelvin` clamps to `2800..6500`. Setting a manual temperature also turns auto off, mirroring OBSBOT Center's behavior.

### System

Sleep or wake:

```json
{ "action": "system.run_status", "id": "50", "status": "sleep" }
{ "action": "system.run_status", "id": "51", "status": "run" }
```

### Presets

Save current camera position:

```json
{ "action": "preset.save", "id": "60", "preset_id": 1, "name": "Wide" }
```

Recall:

```json
{ "action": "preset.recall", "id": "61", "preset_id": 1, "duration_ms": 5000 }
```

Delete:

```json
{ "action": "preset.delete", "id": "62", "preset_id": 1 }
```

`duration_ms` is optional. When omitted or `0`, the bridge uses the camera's hardware preset recall (fastest path). When greater than zero, the bridge runs the motion planner from the current position to the saved preset position over that many milliseconds.

Preset lists arrive in the `state.presets` array. There is no separate `preset.list` action in the current bridge.

### Sequences

Set active sequence:

```json
{
  "action": "sequence.set",
  "id": "70",
  "mode": "ping_pong",
  "steps": [
    { "preset_id": 1, "seconds": 10, "transition_ms": 2000 },
    { "preset_id": 2, "seconds": 15, "transition_ms": 5000 }
  ]
}
```

Each step holds at its preset for `seconds` and then transitions to the next preset over `transition_ms` milliseconds. The bridge clamps `seconds` to a minimum of 3.

For back-compat the bridge also accepts the old `speed: "instant" / "slow" / "medium" / "fast" / "cinema"` field on sequence steps. It is mapped to a roughly-equivalent `transition_ms` so existing `sequences.json` files keep working. New writers should always emit `transition_ms`.

Start:

```json
{ "action": "sequence.start", "id": "71" }
```

Stop:

```json
{ "action": "sequence.stop", "id": "72" }
```

Save:

```json
{
  "action": "sequence.save_as",
  "id": "73",
  "name": "Main",
  "mode": "forward",
  "steps": [
    { "preset_id": 1, "seconds": 20, "transition_ms": 5000 }
  ]
}
```

Load:

```json
{ "action": "sequence.load", "id": "74", "name": "Main" }
```

Delete:

```json
{ "action": "sequence.delete", "id": "75", "name": "Main" }
```

Supported sequence `mode` values:

- `once`
- `forward`
- `ping_pong`

Minimum step `seconds` is 3.

## Error Codes

| Code | Meaning |
| --- | --- |
| `auth_required` | The connection has not presented a valid token. |
| `auth_failed` | PIN pairing failed. |
| `not_connected` | No camera is attached or active. |
| `not_found` | Requested saved item does not exist. |
| `unsupported` | Unknown action, or the camera firmware rejected the SDK call (e.g. exposure mode on Tiny 2 Lite). |
| `invalid_param` | Value is out of range or malformed. |
| `device_busy` | SDK command failed or the camera is held by another app. |
| `debounced` | Command was rejected by a timing debounce. |
| `internal` | Unexpected bridge or SDK failure. |

## Not Implemented In The Current Bridge

These are useful future protocol candidates but should not be documented as working commands:

- `preset.list`, `preset.rename`, `preset.save_with`
- `preset.set_home`, `preset.recall_home`, `preset.reset_home`
- `ai.set_tracking_mode`
- `ai.set_gesture`
- `image.set_focus`
- `system.set_sleep_timer`
- `system.factory_reset`
- Delta events such as `state.delta` or `ptz_pos`
- Async `device_changed`, `notify`, and `error` event types

Clients must ignore unknown fields in events and acks.
