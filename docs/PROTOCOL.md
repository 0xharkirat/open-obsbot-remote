# Protocol — obsbot-bridge ⇄ Flutter client

**Version:** 1
**Transport:** WebSocket (default `ws://<host>:8765/v1`), JSON UTF-8 text frames.
**Scope:** Tiny 2 Lite only. Other models to be added later.

---

## 1. Conventions

- All messages are JSON objects.
- **Client → Server** messages have `"action"`.
- **Server → Client** messages have either `"type"` (response/ack) or `"event"` (state push).
- Every client message MUST include a string `"id"` (echoed back in `ack`). Client picks any unique-per-connection id (monotonic counter is fine).
- Optional `"device_sn"` on commands. If only one camera is connected and `device_sn` is omitted, bridge picks it.
- Angles in **degrees**. Yaw +right, pitch +up, roll +clockwise from camera POV.
- Zoom in **multiplier** (`1.0` = 1×, `4.0` = 4×).
- All percentages 0–100 unless noted.
- Timestamps in `ts` are unix milliseconds.
- Numbers are JSON numbers; bridge clamps out-of-range values and returns `invalid_param` if it can't.

---

## 2. Connection lifecycle

### 2.1 hello (handshake)

**Client → Server**
```json
{
  "action": "hello",
  "id": "1",
  "client": { "name": "iPhone 17 Pro", "version": "1.0.0" }
}
```

**Server → Client**
```json
{
  "type": "ack", "id": "1", "ok": true,
  "server": { "version": "1.0.0", "protocol": 1, "host": "Hark-MacBook" },
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

If protocol version isn't supported: `{ "type": "ack", "id": "1", "ok": false, "err": "protocol_unsupported" }`.

### 2.2 subscribe

Subscribe for state pushes for one device.

**Client → Server**
```json
{ "action": "subscribe", "id": "2", "device_sn": "ABC12345678901" }
```

**Server → Client**
```json
{ "type": "ack", "id": "2", "ok": true }
```
…immediately followed by a full `state` event (see §4).

### 2.3 unsubscribe

```json
{ "action": "unsubscribe", "id": "3", "device_sn": "ABC12345678901" }
```

### 2.4 ping (optional, on top of WS-native ping)

```json
{ "action": "ping", "id": "4" }
```
Reply: `{ "type": "pong", "id": "4", "ts": 1746086400123 }`.

---

## 3. Commands (client → server)

All commands return an `ack`. Bridge applies the command, updates its state snapshot, and broadcasts a `state` event to all subscribed clients.

### 3.1 PTZ

#### `ptz.angle` — absolute target
SDK: `aiSetGimbalMotorAngleR(pitch, yaw, roll)`.
Implicitly switches camera to manual mode (AI off).

```json
{
  "action": "ptz.angle",
  "id": "10",
  "device_sn": "ABC12345678901",
  "yaw": 30.0,        // -180..180
  "pitch": -15.0,     // -90..90
  "roll": 0           // optional, default 0; usually unused on Tiny 2 Lite
}
```

#### `ptz.velocity` — speed control (joystick drag)
SDK: `aiSetGimbalSpeedCtrlR(pitch, pan, roll)`.
Send `0,0,0` to halt. Coalesced server-side (only latest per 50 ms applied).

```json
{
  "action": "ptz.velocity",
  "id": "11",
  "device_sn": "ABC12345678901",
  "yaw_speed": 60.0,    // -180..180  (deg/s, "pan" in SDK)
  "pitch_speed": -30.0, // -90..90
  "roll_speed": 0
}
```

#### `ptz.stop`
```json
{ "action": "ptz.stop", "id": "12" }
```

#### `ptz.recenter`
SDK: `gimbalRstPosR()`. Brings yaw=0, pitch=0.
```json
{ "action": "ptz.recenter", "id": "13" }
```

### 3.2 Zoom

#### `zoom.set` — absolute
SDK: `cameraSetZoomAbsoluteR(zoom)`.

```json
{ "action": "zoom.set", "id": "20", "value": 1.5 }   // 1.0..4.0
```

#### `zoom.set_smooth` — absolute with speed
SDK: `cameraSetZoomWithSpeedAbsoluteR(zoom*100, speed)`.

```json
{ "action": "zoom.set_smooth", "id": "21", "value": 2.0, "speed": 5 }   // speed 1..10
```

### 3.3 Presets

#### `preset.list`
```json
{ "action": "preset.list", "id": "30" }
```
**Reply** (extends ack):
```json
{
  "type": "ack", "id": "30", "ok": true,
  "presets": [
    { "id": 0, "name": "Wide stage", "yaw": 0, "pitch": -10, "roll": 0, "zoom": 1.0 },
    { "id": 1, "name": "Audience",   "yaw": 90, "pitch": 0,   "roll": 0, "zoom": 1.5 }
  ]
}
```

#### `preset.save` — save current PTZ+zoom under id (1..N) with optional name
SDK: `aiAddGimbalPresetR(&PresetPosInfo)` — bridge fills yaw/pitch/zoom from current state.

```json
{
  "action": "preset.save",
  "id": "31",
  "preset_id": 1,
  "name": "Audience"        // optional, max 60 UTF-8 bytes (SDK limit 64 - margin)
}
```

#### `preset.save_with` — save with explicit values
```json
{
  "action": "preset.save_with",
  "id": "32",
  "preset_id": 2,
  "name": "GGS",
  "yaw": -45, "pitch": -10, "roll": 0, "zoom": 1.8
}
```

#### `preset.recall`
SDK: `aiTrgGimbalPresetR(id)`.
```json
{ "action": "preset.recall", "id": "33", "preset_id": 1 }
```

#### `preset.delete`
SDK: `aiDelGimbalPresetR(id)`.
```json
{ "action": "preset.delete", "id": "34", "preset_id": 2 }
```

#### `preset.rename`
SDK: `aiSetGimbalPresetNameWithIdR(name, id)`.
```json
{ "action": "preset.rename", "id": "35", "preset_id": 1, "name": "Audience-wide" }
```

#### `preset.set_home`, `preset.recall_home`, `preset.reset_home`
SDK: `aiSetGimbalBootPosR / aiTrgGimbalBootPosR / aiRstGimbalBootPosR`.

```json
{ "action": "preset.set_home", "id": "36" }       // captures current pos as home
{ "action": "preset.recall_home", "id": "37" }
{ "action": "preset.reset_home", "id": "38" }
```

### 3.4 AI

#### `ai.set_mode`
SDK: `cameraSetAiModeU(mode, sub_mode)`.

`mode`: `"none" | "human" | "hand" | "group" | "whiteboard" | "desk"`
`sub_mode` (only when `mode=human`): `"normal" | "upper_body" | "close_up" | "head_hide" | "lower_body"` (default `"normal"`)

```json
{ "action": "ai.set_mode", "id": "40", "mode": "human", "sub_mode": "upper_body" }
{ "action": "ai.set_mode", "id": "41", "mode": "none" }
```

#### `ai.set_enabled`
SDK: `aiSetEnabledR(bool)`.
```json
{ "action": "ai.set_enabled", "id": "42", "enabled": true }
```

#### `ai.set_tracking_mode`
SDK: `aiSetTrackingModeR(AiVerticalTrackType)`.
`mode`: `"standard" | "headroom" | "motion"`.
```json
{ "action": "ai.set_tracking_mode", "id": "43", "mode": "standard" }
```

#### `ai.set_gesture`
SDK: `aiSetGestureCtrlIndividualR(gesture, enabled)`.
`gesture`: `"target" | "zoom" | "dyn_zoom" | "dyn_zoom_dir"`.
```json
{ "action": "ai.set_gesture", "id": "44", "gesture": "target", "enabled": true }
```

### 3.5 Image

#### `image.set_hdr` — debounced 3 s
SDK: `cameraSetWdrR(DevWdrModeNone | DevWdrModeDol2TO1)`.
```json
{ "action": "image.set_hdr", "id": "50", "enabled": true }
```

#### `image.set_fov` — 86 / 78 / 65 degrees
SDK: `cameraSetFovU(FovType)`.
```json
{ "action": "image.set_fov", "id": "51", "fov": 86 }
```

#### `image.set_color` — brightness/contrast/saturation/sharpness/hue (0..100)
SDK: `cameraSetImageBrightnessR / cameraSetImageContrastR / cameraSetImageSaturationR / cameraSetImageSharpR / cameraSetImageHueR`.
Send any subset.
```json
{
  "action": "image.set_color",
  "id": "52",
  "brightness": 55, "contrast": 50, "saturation": 60, "sharpness": 50, "hue": 50
}
```

#### `image.set_white_balance`
SDK: `cameraSetWhiteBalanceR(type, kelvin)`.
`type`: `"auto" | "manual" | "sunlight" | "fluorescent" | "tungsten" | "cloudy"`.
`kelvin`: 2000..10000, only used when `type="manual"`.
```json
{ "action": "image.set_white_balance", "id": "53", "type": "manual", "kelvin": 4500 }
```

#### `image.set_anti_flicker`
SDK: `cameraSetAntiFlickR(int)`.
`mode`: `"off" | "50" | "60" | "auto"`.
```json
{ "action": "image.set_anti_flicker", "id": "54", "mode": "auto" }
```

#### `image.set_face_ae` / `image.set_face_focus`
```json
{ "action": "image.set_face_ae", "id": "55", "enabled": true }
{ "action": "image.set_face_focus", "id": "56", "enabled": true }
```

#### `image.set_focus`
SDK: `cameraSetAutoFocusModeR + cameraSetFocusPosR`.
```json
{ "action": "image.set_focus", "id": "57", "auto": false, "value": 50 }   // value 0..100, only used when auto=false
{ "action": "image.set_focus", "id": "58", "auto": true }
```

#### `image.set_flip_h`
SDK: `cameraSetImageFlipHorizonU(int)`.
```json
{ "action": "image.set_flip_h", "id": "59", "enabled": true }
```

### 3.6 System

#### `system.run_status`
SDK: `cameraSetDevRunStatusR(DevStatusRun | DevStatusSleep)`.
`status`: `"run" | "sleep"`.
```json
{ "action": "system.run_status", "id": "60", "status": "sleep" }
```

#### `system.set_sleep_timer`
SDK: `cameraSetSuspendTimeU(int)`.
`seconds`: 0 means disable auto-sleep.
```json
{ "action": "system.set_sleep_timer", "id": "61", "seconds": 600 }
```

#### `system.factory_reset` (confirm in UI before sending)
SDK: `cameraSetRestoreFactorySettingsR()`.
```json
{ "action": "system.factory_reset", "id": "62" }
```

---

## 4. Server → client events

### 4.1 `event: state` — full snapshot
Pushed on every successful command, every SDK status callback, and on subscribe.

```json
{
  "event": "state",
  "ts": 1746086400123,
  "device": {
    "sn": "ABC12345678901",
    "model": "tiny2lite",
    "firmware": "1.2.3.4",
    "connected": true,
    "run_status": "run"
  },
  "ptz": { "yaw": 12.5, "pitch": -8.0, "roll": 0.0 },
  "zoom": { "value": 1.4, "min": 1.0, "max": 4.0 },
  "ai": {
    "mode": "human", "sub_mode": "upper_body",
    "enabled": true, "tracking_mode": "standard",
    "gestures": { "target": true, "zoom": true, "dyn_zoom": false, "dyn_zoom_dir": false }
  },
  "image": {
    "hdr": false, "fov": 86,
    "brightness": 50, "contrast": 50, "saturation": 50, "sharpness": 50, "hue": 50,
    "wb_type": "auto", "wb_kelvin": 4500,
    "anti_flicker": "auto",
    "face_ae": false, "face_focus": false,
    "auto_focus": true, "manual_focus": 50,
    "flip_h": false
  },
  "presets": [
    { "id": 0, "name": "Home", "yaw": 0, "pitch": 0, "roll": 0, "zoom": 1.0 }
  ],
  "latency_ms": 12
}
```

Bridge MAY send a delta event (`event: state.delta`) for high-frequency PTZ updates while velocity is active — TBD; v1 client should accept full snapshots only.

### 4.2 `event: device_changed`
Plug or unplug.
```json
{ "event": "device_changed", "ts": 1746086400123, "sn": "ABC12345678901", "connected": true }
```

### 4.3 `event: ptz_pos` — high-frequency PTZ position push
While the client is actively dragging the PTZ pad or velocity is non-zero, bridge polls `aiGetGimbalStateR` at 250 ms and pushes:
```json
{ "event": "ptz_pos", "ts": 1746086400123, "yaw": 13.1, "pitch": -8.2 }
```
Pause polling 1 s after last motion to save USB bandwidth.

### 4.4 `event: notify` — bridge-level info / warnings
```json
{ "event": "notify", "level": "warn", "code": "ai_disabled_for_manual",
  "msg": "AI was disabled because a manual gimbal command was received." }
```

### 4.5 `event: error`
Async errors not tied to a specific client request.
```json
{ "event": "error", "code": "device_busy", "msg": "Camera unresponsive for 5 s" }
```

---

## 5. Acks

Every command:
```json
{ "type": "ack", "id": "<echo>", "ok": true }
```

Failure:
```json
{ "type": "ack", "id": "<echo>", "ok": false, "err": "<code>", "msg": "human-readable" }
```

Error codes:
| code | meaning |
|---|---|
| `not_connected` | No device matching `device_sn`. |
| `unsupported` | Command isn't supported by Tiny 2 Lite. |
| `invalid_param` | Out-of-range or wrong-typed value. |
| `device_busy` | SDK returned `CommErrorBusy` / timeout. |
| `timeout` | SDK returned `CommErrorTimeout`. |
| `debounced` | Command rejected because too soon after a slow op. |
| `ai_conflict` | Manual gimbal cmd while AI on; bridge auto-handles, but if disabled in config returns this. |
| `protocol_unsupported` | `hello` rejected. |
| `internal` | Anything else; check bridge log. |

---

## 6. Versioning

- Path component `/v1` in the WS URL pins protocol version.
- `hello.server.protocol` echoes the integer.
- Breaking changes ship as `/v2`.
- New optional fields (additive) don't bump the version. Clients MUST ignore unknown fields.

---

## 7. Examples (full flow)

### 7.1 Phone connects, drags PTZ pad, recalls preset

```
→ { "action":"hello", "id":"1", "client":{"name":"iPhone","version":"1.0"} }
← { "type":"ack","id":"1","ok":true,"server":{"version":"1.0.0","protocol":1},
    "devices":[{"sn":"ABC...","model":"tiny2lite",...}] }

→ { "action":"subscribe","id":"2","device_sn":"ABC..." }
← { "type":"ack","id":"2","ok":true }
← { "event":"state", ... full snapshot ... }

→ { "action":"ptz.velocity","id":"3","yaw_speed":60,"pitch_speed":0 }
← { "type":"ack","id":"3","ok":true }
← { "event":"ptz_pos","yaw":2.3,"pitch":0 }   (250 ms tick)
← { "event":"ptz_pos","yaw":17.8,"pitch":0 }
...

→ { "action":"ptz.stop","id":"4" }
← { "type":"ack","id":"4","ok":true }
← { "event":"state", ... yaw≈45,pitch=0,zoom=1.0 ... }

→ { "action":"preset.recall","id":"5","preset_id":1 }
← { "type":"ack","id":"5","ok":true }
← { "event":"state", ... yaw=90,pitch=0,zoom=1.5,etc ... }
```

### 7.2 Two phones in sync
Both subscribed. Phone A sends `preset.recall id=1`. Bridge applies and broadcasts `state` to both A and B. B's UI updates without B sending anything.

---

## 8. Open extension points (not in v1)

- `recording.start / recording.stop` — Tail Air later.
- `multi_device` — `device_sn` already required, just need device list UI.
- `auth` — none in v1 (LAN only). Could add bearer-token in `hello.client.token`.
- `binary frames` — for live video preview in future. Reserve a separate channel `/v1/preview`.
