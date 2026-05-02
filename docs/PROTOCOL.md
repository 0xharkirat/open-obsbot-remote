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
- Angles are degrees. Yaw positive is right, pitch positive is up.
- Zoom is a multiplier. Clients should use `state.zoom.min` and `state.zoom.max`.
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

The bridge broadcasts full snapshots after commands, on poll ticks, and after subscribe.

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
    "flip_h": false
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
    "loaded": "Main"
  }
}
```

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
  "roll": 0
}
```

Velocity move:

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
{ "action": "zoom.set", "id": "20", "value": 1.5 }
```

Set zoom with speed:

```json
{ "action": "zoom.set_smooth", "id": "21", "value": 1.8, "speed": 5 }
```

`speed` is `1..10`. `value` must be within the current `state.zoom.min` and `state.zoom.max`.

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

Supported FOV values: `86`, `78`, `65`.

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

Send any subset. Values are `0..100`.

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
{ "action": "preset.recall", "id": "61", "preset_id": 1, "speed": "medium" }
```

Delete:

```json
{ "action": "preset.delete", "id": "62", "preset_id": 1 }
```

`speed` is optional and may be:

- `instant`
- `slow`
- `medium`
- `fast`

Preset lists are delivered in the `state.presets` array. There is no separate `preset.list` action in the current bridge.

### Sequences

Set active sequence:

```json
{
  "action": "sequence.set",
  "id": "70",
  "mode": "ping_pong",
  "steps": [
    { "preset_id": 1, "seconds": 10, "speed": "slow" },
    { "preset_id": 2, "seconds": 15, "speed": "medium" }
  ]
}
```

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
    { "preset_id": 1, "seconds": 20, "speed": "medium" }
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

Minimum step duration is 3 seconds.

## Error Codes

| Code | Meaning |
| --- | --- |
| `auth_required` | The connection has not presented a valid token. |
| `auth_failed` | PIN pairing failed. |
| `not_connected` | No camera is attached or active. |
| `not_found` | Requested saved item does not exist. |
| `unsupported` | Unknown action or unsupported camera feature. |
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
- `image.set_white_balance`
- `image.set_anti_flicker`
- `image.set_focus`
- `system.set_sleep_timer`
- `system.factory_reset`
- Delta events such as `state.delta` or `ptz_pos`
- Async `device_changed`, `notify`, and `error` event types

Clients must ignore unknown fields in events and acks.
