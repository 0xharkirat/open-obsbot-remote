# Architecture — OBSBOT Tiny 2 Lite Control App

**Scope:** Tiny 2 Lite only. Single camera over USB on a Mac. Phone controls over LAN.
Other camera families (Tail Air, Meet, Tiny SE, Tiny 3) are explicitly **out of scope** for v1.

---

## 1. System overview

```
┌────────────────────┐     local Wi-Fi      ┌─────────────────────┐    USB     ┌────────────────┐
│  iPhone 17 Pro     │  ◄── WebSocket ───►  │  MacBook Pro M5     │  ◄────►   │ Tiny 2 Lite    │
│  Flutter client    │   JSON over WS       │  obsbot-bridge      │           │                │
│  (control UI)      │                      │  (C++ + libdev)     │           │                │
└────────────────────┘                      └─────────────────────┘           └────────────────┘
        ▲                                            ▲
        └──────── mDNS _obsbot-bridge._tcp ──────────┘
```

Single bridge per Mac. One Tiny 2 Lite per bridge. Multiple phones may connect simultaneously and share state.

---

## 2. Components

### 2.1 Bridge app (`obsbot-bridge`)
- **Language:** C++17.
- **Links:** `libdev.dylib` (1.3.0, vendored from `obsbot-sdk/macos/arm64-release/`), `libc++`, system frameworks pulled transitively (AVFoundation, IOKit, CoreMediaIO).
- **WebSocket server:** [uWebSockets](https://github.com/uNetworking/uWebSockets) — header-only-ish, fast, low-dep. Single binary.
- **HTTP REST:** uWebSockets serves both on different listeners.
- **mDNS:** Apple `dnssd` API directly (no libavahi on Mac).
- **JSON:** [nlohmann/json](https://github.com/nlohmann/json) — single header.
- **Threads:**
  1. **Main:** signal handling, lifecycle.
  2. **SDK thread:** drains command queue → calls `dev->...R(...)` synchronously. Owns the `std::shared_ptr<Device>`.
  3. **WS I/O thread (uWS loop):** accept clients, parse JSON, enqueue commands, broadcast events.
  4. **Status broadcast thread:** receives SDK status callbacks, fans out to all connected clients.
- **Config file:** `~/.config/obsbot-bridge/config.json` — `{port_ws, port_http, mdns_name, log_level}`.
- **Logs:** `~/Library/Logs/obsbot-bridge/bridge.log`. Hook `dev_set_log_handler` so SDK logs land in the same file.

### 2.2 Flutter client
- **Flutter:** latest stable, null-safe.
- **State:** Riverpod (cleaner DI than BLoC for this scale; reactive rebuilds on status events).
- **WebSocket:** `web_socket_channel`.
- **Discovery:** `multicast_dns` for `_obsbot-bridge._tcp.local`.
- **Storage:** `shared_preferences` for last-server cache + saved preset names.
- **Targets:** iOS first (iPhone 17 Pro), then macOS desktop. Android/Web/Windows/Linux deferred.

---

## 3. Tiny 2 Lite SDK surface used

Only the methods that map to `tiny2 series` or `all`. Confirmed via SDK_EXPLORATION.md `@category` tags:

### Discovery / lifecycle
- `Devices::get().setDevChangedCallback(cb, ud)` — plug/unplug.
- `Devices::get().setEnableMdnsScan(false)` — Tiny 2 Lite is USB-only.
- `Devices::get().getDevList()` / `getDevBySn()` — enumerate.
- `Devices::get().close()` — shutdown.

### Status streaming
- `dev->setDevStatusCallbackFunc(cb, ud)` + `enableDevStatusCallback(true)` — periodic `CameraStatus` push every ~2-3 s. Read `status->tiny.*`.
- `dev->cameraStatus()` — last cached status, sync read.

### PTZ
- `aiSetGimbalMotorAngleR(pitch, yaw, roll=-1000)` — absolute target. Pitch -90~90, yaw -180~180.
- `aiSetGimbalSpeedCtrlR(pitch, pan, roll=0)` — velocity. Use 0 to stop. Pitch -90~90, pan -180~180.
- `aiSetGimbalStop()` — halt.
- `aiGetGimbalStateR(&AiGimbalStateInfo)` — read current motor angles + euler + velocity.
- `gimbalRstPosR()` — re-center.
- AI ownership rule: call `cameraSetAiModeU(AiWorkModeNone)` before manual gimbal velocity ctrl, restore prior mode after.

### Zoom
- `cameraSetZoomAbsoluteR(zoom, speed=-1)` — Tiny 2 Lite range 1.0–4.0.
- `cameraSetZoomWithSpeedAbsoluteR(zoom_x100, speed)` — smoothed.
- `cameraGetZoomAbsoluteR(&zoom)` — read.

### Presets (gimbal preset, not zone preset)
- `aiAddGimbalPresetR(&PresetPosInfo)` — id + name + yaw/pitch/roll/zoom.
- `aiTrgGimbalPresetR(id)` — recall.
- `aiDelGimbalPresetR(id)` — delete.
- `aiUpdGimbalPresetR(&PresetPosInfo)` — update.
- `aiGetGimbalPresetListR(&DevDataArray)` — id list.
- `aiGetGimbalPresetInfoWithIdR(&info, id)` — detail.
- `aiSetGimbalBootPosR(&info, false)` / `aiTrgGimbalBootPosR(false)` / `aiRstGimbalBootPosR()` — home.

### AI mode
- `cameraSetAiModeU(AiWorkModeType, sub_mode=0)` — modes: None / Group / Human / Hand / WhiteBoard / Desk. Sub-mode for Human: Normal / UpperBody / CloseUp / HeadHide / LowerBody.
- `aiSetEnabledR(bool)` — master AI on/off.
- `aiSetTrackingModeR(AiVerticalTrackType)` — Standard / Headroom / Motion.
- `aiSetGestureCtrlIndividualR(gesture, bool)` — toggle gesture target / zoom / dyn-zoom / dyn-zoom-direction.
- `aiGetAiStatusR(&AiStatus)` — full AI snapshot.

### Image
- `cameraSetWdrR(DevWdrModeNone | DevWdrModeDol2TO1)` — HDR off/on. Debounce ≥3 s.
- `cameraSetFovU(FovType86 | FovType78 | FovType65)` — wide / medium / narrow.
- `cameraSetImageBrightnessR / Contrast / Hue / Saturation / Sharp` + matching `Get`/`GetRange`.
- `cameraSetWhiteBalanceR(DevWhiteBalanceType, color_temp)`.
- `cameraSetAntiFlickR(50/60/auto/off)`.
- `cameraSetFaceFocusR(bool)` / `cameraSetFaceAER(int)`.
- `cameraSetAutoFocusModeR(DevAutoFocusType)` + `cameraSetFocusPosR(int 0..100)` for manual.
- `cameraSetImageFlipHorizonU(int)`.

### System
- `cameraSetDevRunStatusR(DevStatusRun | DevStatusSleep)` — wake/sleep.
- `cameraSetSuspendTimeU(int seconds)` — auto-sleep timer.
- `cameraSetRestoreFactorySettingsR()`.
- `cameraSetAudioCtrlStateU(AudioCtrlCmdType, state)` — voice control switches.
- `cameraSetAudioAutoGainU(bool)` — AGC.
- `cameraSetBootModeU(AiWorkModeType, AiSubModeType)` — boot AI mode.

### Explicitly NOT in v1
- Background image upload/download (requires file lifecycle + MTP — too much surface for performance use case).
- Voice control configuration UI (toggle from settings later).
- Zone tracking (TinySE only).
- Recording / NDI / RTSP / SRT (Tail Air only).

---

## 4. Concurrency model

```
                ┌──────────────────────────────┐
                │  WS I/O thread (uWS loop)    │
                │  - parse JSON                │
                │  - enqueue Command           │
                │  - send JSON to clients      │
                └──────────┬─────────────┬─────┘
                           │ enqueue     ▲ broadcast
                           ▼             │
                ┌──────────────────────────────┐
                │  Command queue (MPSC)        │
                └──────────┬───────────────────┘
                           │ dequeue
                           ▼
                ┌──────────────────────────────┐
                │  SDK thread                  │
                │  - call dev->...R(...)       │
                │  - publish result/error      │
                └──────────────────────────────┘

                ┌──────────────────────────────┐
                │  SDK status callback         │  (SDK-owned thread)
                │  - copy CameraStatus.tiny    │
                │  - push StateEvent           │
                └──────────┬───────────────────┘
                           │
                           ▼
                ┌──────────────────────────────┐
                │  Event queue (SPMC)          │
                │  - WS thread broadcasts      │
                └──────────────────────────────┘
```

**Rules:**
- All SDK calls happen on the SDK thread. Never from inside an SDK callback.
- SDK callbacks must do minimal work (memcpy, push to queue, return).
- Commands are processed FIFO. PTZ velocity commands coalesce: if a new `ptz_velocity` command arrives while one is queued, drop the old.
- HDR / media-mode debounce: bridge maintains last-applied timestamp; if <3 s ago, reject with error.
- AI ownership: when client sends a manual gimbal velocity, bridge implicitly disables AI (`cameraSetAiModeU(AiWorkModeNone)`) and remembers prior mode. After 1 s of no velocity command, optionally restore — but better: client must explicitly say "manual mode" vs "AI mode" so behavior is predictable.

---

## 5. State broadcast

Bridge maintains a snapshot of the camera's logical state. On every:
1. SDK status callback (`~2-3 s` cadence, from `tiny` struct).
2. Successful command apply.
3. Plug/unplug event.

It builds a JSON `state` object and pushes to all subscribed clients.

```json
{
  "event": "state",
  "ts": 1746086400123,
  "device": {
    "sn": "ABC12345678901",
    "model": "Tiny 2 Lite",
    "firmware": "1.2.3.4",
    "connected": true,
    "run_status": "run"
  },
  "ptz": {
    "yaw": 12.5, "pitch": -8.0, "roll": 0.0
  },
  "zoom": { "value": 1.4, "min": 1.0, "max": 4.0 },
  "ai": { "mode": "human", "sub_mode": "upper_body", "enabled": true, "tracking_mode": "standard" },
  "image": {
    "hdr": false, "fov": 86,
    "brightness": 50, "contrast": 50, "saturation": 50, "sharpness": 50,
    "wb_type": "auto", "wb_kelvin": 4500,
    "anti_flicker": "auto",
    "face_ae": false, "face_focus": false, "auto_focus": true, "manual_focus": 50,
    "flip_h": false
  }
}
```

PTZ angles come from `aiGetGimbalStateR` — bridge polls every 250 ms while the camera is awake, since `tiny.*` struct doesn't contain motor angles. (This is an extra USB cost; tunable.)

---

## 6. Error model

Every command response:
```json
// success
{ "type": "ack", "id": "<client_msg_id>", "ok": true }

// failure
{ "type": "ack", "id": "<client_msg_id>", "ok": false, "err": "device_busy", "msg": "..." }
```

Error codes:
- `not_connected` — no device handle.
- `unsupported` — command not for Tiny 2 Lite.
- `invalid_param` — out-of-range value.
- `device_busy` — SDK returned `CommErrorBusy`.
- `timeout` — `CommErrorTimeout`.
- `debounced` — too soon after a previous slow op (HDR/media-mode).
- `ai_conflict` — manual gimbal command rejected because AI is on; client should send `ai.set_mode none` first.
- `internal` — anything else.

---

## 7. Discovery (mDNS)

**Service type:** `_obsbot-bridge._tcp.local`
**Default port:** 8765 (WebSocket), 8766 (HTTP).
**TXT records:**
- `version=1` — protocol version.
- `name=<hostname>` — display name (e.g., "Hark's Mac").
- `models=tiny2lite` — comma-list of currently-attached camera families (drives client UI).
- `count=1` — number of cameras attached.

Client behavior:
1. Browse for `_obsbot-bridge._tcp.local`.
2. Show list with name + model count.
3. On tap, resolve hostname → connect WebSocket → handshake.
4. Cache last successfully-connected entry; auto-reconnect on app launch.

Manual fallback: free-form `host:port` field.

---

## 8. Connection lifecycle

```
1. Client opens WS: ws://<host>:8765/v1
2. Client sends:    { "action": "hello", "id": "1", "client": { "name": "iPhone 17 Pro", "version": "1.0.0" } }
3. Bridge replies:  { "type": "ack", "id": "1", "ok": true,
                      "server": { "version": "1.0.0", "protocol": 1 },
                      "devices": [{ "sn": "...", "model": "Tiny 2 Lite", ... }] }
4. Client sends:    { "action": "subscribe", "id": "2", "device_sn": "..." }
5. Bridge replies:  ack + immediate { "event": "state", ... } snapshot.
6. Bridge then pushes "state" events on every change.
```

**Heartbeats:** WS-native ping frame every 5 s. If no pong in 15 s, close.

**Reconnect:** Client backoff 1 s → 2 s → 4 s → 8 s → 8 s … capped. On reconnect, replay `hello` + `subscribe`.

---

## 9. File layout (proposed)

```
obsbot.workspace/
├── obsbot-sdk/                  # vendored SDK (already present)
├── SDK_EXPLORATION.md           # done
├── ARCHITECTURE.md              # this file
├── PROTOCOL.md                  # next
├── bridge/                      # C++ bridge app
│   ├── CMakeLists.txt
│   ├── src/
│   │   ├── main.cpp
│   │   ├── bridge.{h,cpp}       # uWS server, command dispatch
│   │   ├── device_session.{h,cpp}  # owns shared_ptr<Device>, state snapshot
│   │   ├── command_queue.{h,cpp}
│   │   ├── status_publisher.{h,cpp}
│   │   ├── mdns.{h,cpp}         # dnssd wrapper
│   │   ├── protocol.{h,cpp}     # JSON ↔ command structs
│   │   └── log.{h,cpp}
│   ├── third_party/
│   │   ├── uWebSockets/
│   │   └── nlohmann_json.hpp
│   └── README.md
├── client/                      # Flutter app
│   ├── pubspec.yaml
│   ├── lib/
│   │   ├── main.dart
│   │   ├── core/
│   │   │   ├── ws_client.dart
│   │   │   ├── mdns_discovery.dart
│   │   │   └── protocol/        # generated from PROTOCOL.md
│   │   ├── state/               # Riverpod providers
│   │   ├── ui/
│   │   │   ├── server_discovery_screen.dart
│   │   │   ├── control_screen.dart
│   │   │   ├── preset_editor_screen.dart
│   │   │   └── settings_screen.dart
│   │   └── widgets/
│   │       ├── ptz_pad.dart
│   │       ├── zoom_slider.dart
│   │       └── preset_button.dart
│   ├── ios/
│   └── macos/
└── docs/
    ├── INSTALL_BRIDGE.md
    └── INSTALL_CLIENT.md
```

---

## 10. Build pipeline

### Bridge
- **Prereq on dev Mac:** `brew install cmake`.
- Out-of-source: `cmake -S bridge -B bridge/build -DCMAKE_BUILD_TYPE=Release && cmake --build bridge/build`.
- Output: `bridge/build/obsbot-bridge` + bundled `libdev.dylib`.
- Install: `cmake --install bridge/build --prefix /usr/local`. Place a launchd plist at `~/Library/LaunchAgents/com.obsbot.bridge.plist` for auto-start.

### Flutter client
- `flutter pub get` then `flutter run -d ios` (with iPhone connected).
- For desktop: `flutter run -d macos`.

---

## 11. Risks & mitigations (Tiny 2 Lite specific)

| Risk | Mitigation |
|---|---|
| AI fights manual PTZ | Bridge auto-disables AI on first manual cmd; UI shows clear "AI off" indicator. |
| Wi-Fi latency spike | Show round-trip latency in UI; client uses optimistic updates. |
| USB unplug mid-session | `devChangedCallback` fires; bridge broadcasts `device_disconnected` event; client shows reconnect banner. |
| Multiple phones fighting over PTZ | Last-write-wins; broadcast each command to all clients so screens stay in sync. |
| HDR toggle spam | Bridge enforces 3 s debounce; returns `debounced` error. |
| Bridge crashes | launchd `KeepAlive=true`. SDK `Devices::get().close()` in `atexit`. |
| Camera in privacy mode | Status field `dev_status==4`; UI shows banner, all PTZ commands rejected. |
| Phone backgrounding drops WS | Reconnect with backoff. iOS may freeze socket; handle on resume. |

---

## 12. What's deferred to later phases

- **Phase 5+:** AI-mode tuning UI, image style presets, voice-control config, gesture toggles.
- **Phase 7:** OBS scene switching, multi-camera, watch app, voice commands, macros.
- **Future:** Tail Air support (BLE pairing flow + Wi-Fi config + recording controls), Tiny 3 (audio modes), Meet (virtual background).

Architecture is single-camera-Tiny-2-Lite for now. Multi-camera and other models can be added later by introducing a `device_sn` discriminator in the protocol (already present).
