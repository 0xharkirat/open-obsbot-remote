# OBSBOT SDK Exploration Report

**SDK location:** `obsbot-sdk/`
**SDK version:** `LIB_MAJOR_VER 1.3.0` (from `include/util/comm.hpp`)
**Date explored:** 2026-05-01
**Target host for bridge app:** macOS arm64 (MacBook Pro M5)
**Test camera:** OBSBOT Tiny 2 Lite

---

## 1. SDK Structure Overview

```
obsbot-sdk/
├── include/
│   ├── util/comm.hpp          # logging, version macros, DEV_EXPORT
│   └── dev/
│       ├── dev.hpp            # Device class — main API surface (~5338 lines)
│       └── devs.hpp           # Devices singleton — discovery + lifecycle
├── OBSBOT_Sample/
│   ├── CMakeLists.txt         # CMake 3.16, C++11
│   └── main.cpp               # Reference console app demonstrating PTZ, AI, image
├── macos/
│   ├── arm64-release/         # libdev.dylib (1.6 MB, arm64), prebuilt OBSBOT_Sample
│   └── x86_64-release/        # libdev.dylib (Intel)
├── linux/
│   ├── arm64-release/         # libdev.so / libdev.so.1 / libdev.so.1.0.3 (24 MB)
│   └── x86_64-release/
└── windows/
    ├── win64-release/         # libdev.dll, libdev.lib, libdev.pdb, w32-pthreads
    └── win64-debug/
```

**No README, license, or external docs in SDK** — all knowledge is in headers + sample. Documentation is via Doxygen-style `@brief` + `@category` comments inline in `dev.hpp`.

---

## 2. Core Architecture

Two C++ classes, both `DEV_EXPORT`:

### `Devices` singleton (devs.hpp)
Discovery + lifecycle. One instance globally, accessed via `Devices::get()`.

| API | Purpose |
|---|---|
| `Devices::get()` | Get singleton |
| `setDevChangedCallback(cb, ud)` | Plug/unplug events. `cb(sn, in_out, ud)` |
| `setDevConnectFailedCallback(cb, ud)` | Connection failure (auth, net, etc.) |
| `setEnableMdnsScan(bool)` | Toggle mDNS net scan |
| `setNetDevHeartbeatInterval(ms)` | Net device keepalive (default 3s) |
| `getDevNum()`, `getDevList()` | Enumerate |
| `getDevByName / getDevBySn / getDevByUuid` | Lookup |
| `containDev(uuid)` | Existence check |
| `setTailAirWhiteList(list<bt_mac>)` | Net scan filter for Tail Air |
| `startNetworkScanImmediately()` | Force net scan now |
| `close()` | Tear down singleton |
| **(BLE-only build)** | Bluetooth pairing + Wi-Fi config flow for Tail Air/Tail2 — gated on `ENABLE_BLE_FUNC` |

### `Device` (dev.hpp)
Per-camera handle, returned as `std::shared_ptr<Device>`. ~208 R/U-suffixed methods.

**Suffix convention discovered:**
- `*R` → Remo Protocol command (vendor's own protocol over UVC control transport or net)
- `*U` → UVC extension unit command (faster, fewer bytes, but a subset of features)
- No suffix on getters like `productType()`, `devSn()`, `cameraStatus()` — local cache reads

**Sync vs async:** Get-style methods take `GetMethod method = Block | NonBlock` plus `RxDataCallback callback` for async dispatch.

---

## 3. Device Discovery & Connection Flow

From `OBSBOT_Sample/main.cpp` (canonical pattern):

```cpp
// 1) Register plug/unplug callback
Devices::get().setDevChangedCallback(onDevChanged, nullptr);

// 2) Optional: enable mDNS net scan (for Tail Air / Tail2 over Wi-Fi)
Devices::get().setEnableMdnsScan(false);

// 3) Wait. SDK auto-detects USB/UVC devices in the background.
std::this_thread::sleep_for(3s);

// 4) Pick a device by SN or by index in getDevList()
auto dev = Devices::get().getDevBySn(sn);

// 5) Subscribe to status updates
dev->setDevStatusCallbackFunc(onDevStatusUpdated, nullptr);
dev->enableDevStatusCallback(true);

// 6) For Tail Air specifically, subscribe to event notifications
if (dev->productType() == ObsbotProdTailAir) {
    dev->setDevEventNotifyCallbackFunc(onDevEventNotify, nullptr);
}

// 7) Issue commands
dev->aiSetGimbalMotorAngleR(0.0f, -45.0f, 90.0f);  // pitch, yaw, roll
dev->cameraSetZoomAbsoluteR(1.5f);

// 8) Cleanup at exit
Devices::get().close();
```

**Key insight:** No explicit `connect()` per device. SDK detects via macOS IOKit/AVFoundation, exposes plug/unplug events, and the `Device` shared_ptr stays valid until unplug.

---

## 4. Supported Cameras (`ObsbotProductType`)

| Enum | Product | Notes |
|---|---|---|
| `ObsbotProdTiny` | Tiny | 1st gen (no PTZ gimbal — image-only crop) |
| `ObsbotProdTiny4k` | Tiny 4K | 1st gen 4K |
| `ObsbotProdTiny2` | Tiny 2 | Full PTZ gimbal |
| `ObsbotProdTiny2Lite` | **Tiny 2 Lite** ← user's camera | Same protocol as Tiny 2 (uses tiny.* status struct) |
| `ObsbotProdTinySE` | Tiny SE | Adds zone tracking |
| `ObsbotProdTiny3` (=18) | Tiny 3 | Adds speech-track AI mode + audio modes |
| `ObsbotProdTiny3Lite` (=19) | Tiny 3 Lite | |
| `ObsbotProdMeet` | Meet | Virtual background |
| `ObsbotProdMeet4k` | Meet 4K | |
| `ObsbotProdMeet2` | Meet 2 | |
| `ObsbotProdMeetSE` | Meet SE | |
| `ObsbotProdTailAir` | Tail Air | Full broadcast cam, NDI/RTSP/SRT, recording, BLE pairing |
| `ObsbotProdTail2` | Tail 2 | Adds remo protocol v3, advanced ROI |
| `ObsbotProdTail2S` (=16) | Tail 2 S | |
| `ObsbotProdMe` | Me | Limited |
| `ObsbotProdHDMIBox` | HDMI Box | UVC→HDMI converter |
| `ObsbotProdNDIBox` | NDI Box | |

User's **Tiny 2 Lite** maps onto the `tiny` status struct and uses the Tiny 2 command set (covered in compatibility matrix below).

---

## 5. API Surface — Categorized

Total: **208 `*R` / `*U`** methods + getters. Grouped below.

### 5.1 PTZ / Gimbal control
| Method | Cameras | Use |
|---|---|---|
| `aiSetGimbalMotorAngleR(pitch, yaw, roll)` | tiny2 series, tail air | Absolute angle. Pitch -90~90, yaw -180~180. **PRIMARY for performer's pan/tilt.** |
| `aiSetGimbalSpeedCtrlR(pitch, pan, roll)` | tiny, tiny4k, tiny2 series, tail air | Velocity ctrl. 0 stops. Use this for joystick drag. |
| `aiSetGimbalStop()` | tiny2 series, tail air | Halt motion |
| `aiGetGimbalStateR(AiGimbalStateInfo*)` | tiny2 series, tail air | Current angles + velocities |
| `gimbalRstPosR()` | tiny, tiny4k, tiny2 series, tail air | Re-center to zero |
| `gimbalSpeedCtrlR(pitch, pan, roll)` | same | Older speed cmd (use aiSet* instead on new fw) |
| `gimbalSetSpeedPositionR(roll, pitch, yaw, s_*)` | same | Move-to with speed |
| `gimbalGetAttitudeInfoR(xyz[3])` | same | Sync angle read |
| `cameraSetPanTiltAbsolute(pan, tilt)` | meet, meet4k, meet2, meetSE | Image crop pan/tilt. Range `-1.0~1.0`. **For Meet (no physical gimbal).** |
| `cameraSetPanTiltRelative(p_speed, t_speed)` | meet series | Same |

**Note:** Meet series has *digital* pan/tilt over the wide image, no motorized gimbal. Tiny 2/2Lite/SE/3 + Tail Air/Tail2 have real motors.

### 5.2 Zoom
| Method | Cameras | Use |
|---|---|---|
| `cameraSetZoomAbsoluteR(zoom, speed=-1)` | all main | 1.0~2.0 (some 1.0~4.0). Plus optional speed for tail2/tail2s |
| `cameraGetZoomAbsoluteR(zoom&)` | all main | Read current |
| `cameraGetRangeZoomAbsoluteR(UvcParamRange&)` | all main | Range/min/max |
| `cameraSetZoomWithSpeedAbsoluteR(ratio_x100, speed)` | tiny2, tail air | Speed-controlled zoom |
| `cameraSetZoomWithSpeedRelativeR(step, speed, step_mode, in_out)` | tail air | Smooth zoom in/out |
| `cameraSetZoomStopR()` | tail air | Halt zoom |

### 5.3 Presets
**Two preset systems:** "gimbal preset" (regular) and "zone preset" (Tiny SE only).

| Method | Cameras | Use |
|---|---|---|
| `aiAddGimbalPresetR(PresetPosInfo*)` | tiny, tiny4k, tiny2 series, tail air | Save with name + yaw/pitch/roll/zoom |
| `aiTrgGimbalPresetR(id)` | tiny, tiny4k, tiny2 series, tail air | **Recall preset by id** |
| `aiDelGimbalPresetR(id)` | tiny, tiny4k, tiny2 series, tail air | Delete |
| `aiUpdGimbalPresetR(PresetPosInfo*)` | tiny2 series, tail air | Update existing |
| `aiGetGimbalPresetListR(DevDataArray*)` | tiny2 series, tail air | Enumerate ids |
| `aiGetGimbalPresetInfoWithIdR(...)` | tiny2 series, tail air | Get preset detail |
| `aiSet/GetGimbalPresetNameWithIdR(...)` | tiny2 series, tail air | Rename |
| `aiSetGimbalBootPosR(PresetPosInfo&, presets_flag)` | tiny, tiny4k, tiny2 series, tail air | Save boot/home position |
| `aiTrgGimbalBootPosR(reset_mode=false)` | tiny2 series, tail air | Recall home |
| `aiRstGimbalBootPosR()` | tiny2 series, tail air | Reset home to default |
| **Zone presets (TinySE only)** | | `aiAddZonePresetR / aiTrgZonePresetR / aiDelZonePresetR / aiGetZonePresetListR / aiGetZonePresetInfoWithIdR` |

`PresetPosInfo`:
```c
struct {
    int32_t id;
    float roll, pitch, yaw;
    float zoom;            // 1.0~2.0 or 1.0~4.0
    float b_pitch;         // tiny2/tinySE, reserved
    int32_t name_len;
    char name[64];
    float roi_cx, roi_cy, roi_alpha;  // tail air only
};
```
Plus a `PresetsAction` struct for advanced "do these settings when preset reached" (AI mode, focus, exposure, WB, image params) — useful for scene-aware presets.

### 5.4 AI tracking
Cameras vary widely.

| Method | Cameras | Use |
|---|---|---|
| `aiSetTargetSelectR(bool)` | tiny, tiny4k | Old-style on/off |
| `cameraSetAiModeU(AiWorkModeType, sub)` | tiny2 (only) | Tiny 2 family AI work mode (Human, Hand, Group, Whiteboard, Desk, Speech) |
| `aiSetAiTrackModeEnabledR(AiTrackModeType, bool)` | tiny2 series, tinySE, tail air, tail2+ | Enable/disable mode |
| `aiSetTrackingModeR(AiVerticalTrackType)` | tiny, tiny4k, tiny2 series | Standard / Headroom / Motion |
| `aiSetTrackSpeedTypeR(AiTrackSpeedType)` | tail air | Lazy/Slow/Standard/Fast/Crazy/Auto |
| `aiSetGestureCtrlIndividualR(gesture, bool)` | tiny, tiny4k, tiny2 series, tail air | Toggle gesture: target/zoom/dyn-zoom/record |
| `aiGetAiStatusR(AiStatus*)` | tiny, tiny4k, tiny2 series, tail air | Full AI status snapshot |
| `aiSetEnabledR(bool)` | tiny, tiny4k, tiny2 series, tail air | Master AI on/off (turn off before manual gimbal speed control) |
| `aiSetSelectTargetByBox(x_min,y_min,x_max,y_max)` | tail air | Tap-to-track in normalized coords |
| `aiSetSelectBiggestTarget / aiSetSelectCentralTarget` | tail air | Auto pick |
| `aiDelSelectedTargetR / aiDelAutoGroupModeR` | tail air | Cancel |
| `aiSetVideoCenter(x, y)` | tail air | Re-center frame |
| `aiSetHorizontalOffset / aiSetVerticalOffset` | tail air | Composition offset for tracking |
| **Zone tracking (TinySE)** | | `aiSetLimitedZoneTrack*R` for yaw/pitch min/max + auto-select-target + init pos |

### 5.5 Image / Color / Exposure / Focus
All `tiny, tiny4k, tiny2, tail air, meet, meet4k`:

`cameraSetImageBrightnessR / cameraSetImageContrastR / cameraSetImageHueR / cameraSetImageSaturationR / cameraSetImageSharpR` + matching Get + Get-Range.

Style: `cameraSetImageStyleR(DevImageStyle)` (tail air).

White balance: `cameraSetWhiteBalanceR(DevWhiteBalanceType, color_temp)` (tiny + tail + meet); `cameraGetWhiteBalanceListR` for supported types.

Auto / manual exposure (tail air):
- `cameraSetExposureModeR(int)` — auto/PAE/SAE/AAE/MAE
- `cameraSetSAEShutterR / cameraSetMAEShutterR / cameraSetMAEIsoR / cameraSetISOLimitR / cameraSetAELockR / cameraSetPAEEvBiasR / cameraSetSAEEvBiasR / cameraSetAAEEvBiasR / cameraSetMAEApertureR`
- `cameraSetFaceAER(int)` (all)
- `cameraSetAntiFlickR(50/60/auto/off)` (tiny+tail+meet)

Focus (tail air, tail2):
- `cameraSetAutoFocusModeR(DevAutoFocusType)` — afc/afs/manual
- `cameraSetFocusPosR(int)` / `cameraGetFocusPosR(&)` — manual focus (Tiny 2 Lite uses simpler `cameraSetFocusAbsolute(50, false)` shown in sample line 605)
- `cameraSetAFCTrackModeR(DevAFCType)` (tail air, tail2)
- `cameraSetFaceFocusR(bool)` (all)

HDR / WDR: `cameraSetWdrR(DevWdrModeNone | Dol2TO1 | …)` (tiny4k, tiny2, meet, tail air).

FOV: `cameraSetFovU(FovType86 | 78 | 65)` (tiny + meet) — wide/medium/narrow.

Mirror/flip (tail air): `cameraSetMirrorFlipR(DevImageMirrorFlipType)`.

### 5.6 Meet-only (virtual background)
`cameraSetMediaModeU(MediaMode Normal/Background/AutoFrame)`, `cameraSetBgModeU(MediaBgMode Disable/Color/Replace/Blur)`, `cameraSetBgColorU`, `cameraSetMaskLevelU(0~100)`, `cameraSetBgEnableU`, `cameraSetButtonModeU`, `cameraSetAutoFramingModeU(group_or_single, close_or_upper)`.

Image transfer: `setLocalResourcePath` + `startFileUploadAsync(UploadImage0..3)` to put a custom background; `startFileDownloadAsync(DownloadImage*)` to pull thumbnails.

### 5.7 Tail Air recording / live stream / NDI / RTSP / SRT
| Method | Use |
|---|---|
| `cameraSetTakePhotosR(op, param)` | 0=stop, 1=normal, 2=burst |
| `cameraSetVideoRecordR(op)` | 0=stop, 1=start |
| `cameraSetRecordResolutionR(DevVideoResType)` | 4K/1080p/720p × multiple framerates |
| `cameraSetMainVideoEncoderFormatR(H264/H265/MJPEG/AV1/NDI-full)` | |
| `cameraSetMainVideoBitrateLevelR(Default/Low/Med/High)` | |
| `cameraSetSelectNdiOrRtspR / cameraSetBootNdiEnabledR / cameraSetNdiRtspResolutionR / ...EncoderFormatR / ...BitrateLevelR` | NDI or RTSP |
| `cameraSetHdmiInfoR(HdmiInfo)` | HDMI OSD lang, content, vol, res |
| `cameraSetWatermarkAttributeR(bool)` | |
| `DevMediaParamSrt` + `cameraSetMediaOperateParamR(stream_id, action)` | SRT + stream lifecycle (tail2) |

### 5.8 System & device
- `cameraSetDevRunStatusR(DevStatus Run/Sleep/Privacy)` — wake/sleep
- `cameraSetRestoreFactorySettingsR()` — factory reset
- `cameraSetSuspendTimeU(int)` — auto-sleep timer
- `cameraSetMicrophoneDuringSleepU(int)`
- `cameraSetImageFlipHorizonU(int)`
- `cameraSetVerticalModeU(int)` — portrait orientation (tiny4k)
- `cameraSetLedCtrlU(bool)` — special LED pattern (tinySE, used while configuring zone tracking)
- `cameraSetAudioCtrlStateU(AudioCtrlCmdType, state)` — voice control (tiny2)
- `cameraSetAudioAutoGainU(bool)` — AGC (tiny2)
- `cameraSetBootModeU(AiWorkModeType, AiSubModeType)` — boot AI mode (tiny2)
- `sysMgSetDeviceNameR / sysMgGetDeviceNameR` (tail air)
- `sysMgSetIndicatorStateR / sysMgClearIndicatorStateR` (tail air, tail2)
- `sysMgSetBuzzerEnabledR / sysMgGetBuzzerEnabledR` (tail air)
- `cameraSetPowerCtrlActionR(Resume/Suspend/Reboot/PowerOff/MediaExit)` (tail air)

### 5.9 Status streaming
- `setDevStatusCallbackFunc(cb, ud)` + `enableDevStatusCallback(true)` — periodic push every ~2-3s
- `setFastDevStatusCallbackFunc(cb, ud)` — faster cadence variant
- `setDevEventNotifyCallbackFunc(cb, ud)` — event-driven (Tail Air): >120 event types in `RmEventType` (sd card, battery, mic plug/unplug, target loss, new media file, etc.)
- `nextRefreshDevStatus(period)` / `fastNextRefreshDevStatus(period)` — control polling rate
- `cameraStatus()` — read last cached `CameraStatus` (a tagged union by product family: `tiny`, `meet`, `tail_air`)
- `cameraGetCameraStatusU(CameraStatus&)` — sync force-refresh

`CameraStatus` has 60+ fields per family. Useful ones:
- **tiny** struct: `zoom_ratio`, `hdr`, `face_ae`, `dev_status`, `auto_sleep_time`, `vertical`, `face_auto_focus`, `auto_focus`, `manual_focus_value`, `fov`, `ai_mode`, `ai_sub_mode`, `voice_ctrl`, `voice_ctrl_zoom`, `audio_auto_gain`, `bg_img_idx`, `fps`, `boot_mode`, `led_brightness_level`, `ble_status`, `ai_tracker_speed`, ...
- **meet** struct: `media_mode`, `hdr`, `face_ae`, `fov`, `bg_mode`, `blur_level`, `zoom_ratio`, ...
- **tail_air** struct: full media_running flags (record_status, capture_status), `digi_zoom_ratio`, `battery.{capacity,charging}`, `online_status` (sd_insert, mic_attached, swivel_base, ...), `sd_size`, `color_temp`, `ai_type`, `brightness/contrast/hue/saturation/sharpness`, `style`, ...

---

## 6. Camera-to-Feature Compatibility Matrix

Derived from `@category` annotations on every method.

| Feature | Tiny | Tiny4K | **Tiny2 / 2Lite** | TinySE | Tiny3/3Lite | Meet/4K | Meet2/SE | TailAir | Tail2/2S |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Motorized PTZ (gimbal) | ✗ (digital) | ✗ | **✓** | ✓ | ✓ | ✗ | ✗ | ✓ | ✓ |
| Pan/Tilt absolute | (image crop) | — | **✓** | ✓ | ✓ | ✓ (-1..1 image) | ✓ | ✓ | ✓ |
| Pan/Tilt speed | ✓ | ✓ | **✓** | ✓ | ✓ | — | — | ✓ | ✓ |
| Gimbal stop | — | — | **✓** | ✓ | ✓ | — | — | ✓ | ✓ |
| Zoom (1.0–2.0) | ✓ | ✓ | **✓** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Zoom (up to 4.0) | — | — | **✓** | ✓ | ✓ | — | — | ✓ | ✓ (up to 20×) |
| Zoom with speed | — | — | **✓** | ✓ | ✓ | — | — | ✓ | ✓ |
| Boot/home preset | ✓ | ✓ | **✓** | ✓ | ✓ | — | — | ✓ | ✓ |
| Gimbal presets (add/recall/del) | ✓ | ✓ | **✓** | ✓ | ✓ | — | — | ✓ | ✓ |
| Zone presets / zone tracking | — | — | — | ✓ | — | — | — | — | — |
| Hand tracking | — | — | **✓** | ✓ | — | — | — | — | — |
| AI work mode (Human/Group/Hand/Whiteboard/Desk) | basic | basic | **✓** | ✓ | + Speech | — | — | (different API) | (different API) |
| AI track mode (Normal/FullBody/HalfBody/CloseUp/AutoView/Animal) | — | — | ✓ | ✓ | ✓ | — | — | ✓ | ✓ |
| Tap-to-track (box select) | — | — | — | — | — | — | — | ✓ | ✓ |
| Track speed (Lazy..Crazy) | — | — | — | — | ✓ | — | — | ✓ | ✓ |
| Vertical track mode (Standard/Headroom/Motion) | ✓ | ✓ | **✓** | ✓ | — | — | — | — | — |
| Gesture controls | ✓ | ✓ | **✓** | ✓ | ✓ | — | — | ✓ | ✓ |
| Voice control (HiTiny/Sleep/Track/Zoom) | — | — | **✓** | ✓ | ✓ | — | — | — | — |
| Brightness/Contrast/Hue/Saturation/Sharpness | ✓ | ✓ | **✓** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| White balance (auto + manual K) | ✓ | ✓ | **✓** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Anti-flicker | ✓ | ✓ | **✓** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| HDR / WDR | — | ✓ | **✓** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Auto/manual focus | ✓ | ✓ | **✓** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Face AE / Face AF | ✓ | ✓ | **✓** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Manual exposure (shutter, ISO, EV) | — | — | — | — | — | — | — | ✓ | ✓ |
| FOV (86/78/65°) | ✓ | ✓ | **✓** | ✓ | ✓ | ✓ | ✓ | — | — |
| Image flip / mirror | — | ✓ | **✓** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Vertical/portrait mode | — | ✓ | — | — | — | — | — | — | — |
| Sleep/wake | ✓ | ✓ | **✓** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Auto-sleep timer | ✓ | ✓ | **✓** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Voice control switches | — | — | **✓** | ✓ | ✓ | — | — | — | — |
| Background image upload/download | — | — | **✓ (sleep bg)** | ✓ | ✓ | ✓ (virtual bg) | ✓ | — | — |
| Virtual background (green/replace/blur) | — | — | — | — | — | ✓ | ✓ | — | — |
| Auto framing (group/single/closeup) | — | — | — | — | — | ✓ | ✓ | — | (different) |
| Photo capture | — | — | — | — | — | — | — | ✓ | ✓ |
| Video record (to SD) | — | — | — | — | — | — | — | ✓ | ✓ |
| NDI / RTSP / SRT streaming | — | — | — | — | — | — | — | ✓ | ✓ |
| HDMI output config | — | — | — | — | — | — | — | ✓ | ✓ |
| Watermark | — | — | — | — | — | — | — | ✓ | ✓ |
| BLE pairing + Wi-Fi setup | — | — | — | — | — | — | — | ✓ | ✓ |
| Battery / SD status | — | — | — | — | — | — | — | ✓ | ✓ |
| Buzzer / indicator LED | — | — | — | — | — | — | — | ✓ | ✓ |
| Device rename | — | — | — | — | — | — | — | ✓ | ✓ |
| Power ctrl (reboot/poweroff) | — | — | — | — | — | — | — | ✓ | ✓ |
| Custom remote key bindings | — | — | — | — | — | — | — | ✓ | ✓ |

**Bold column = Tiny 2 Lite (user's camera). Treat it identically to Tiny 2.**

---

## 7. Build & Linkage

### Sample build
Sample `CMakeLists.txt`:
- CMake 3.16, C++11
- Includes `../include`
- Links `dev` (libdev.dylib) on macOS, `libdev` on Windows
- Out-of-source build required (`CMAKE_BINARY_DIR != CMAKE_SOURCE_DIR`)

### macOS dylib linkage (verified `otool -L`)
The prebuilt `macos/arm64-release/libdev.dylib` links against:
- AVFoundation, AppKit, Cocoa, CoreAudio, CoreMedia, **CoreMediaIO** (UVC layer), CoreVideo, Foundation, **IOKit** (USB enumeration), IOSurface, Carbon, AudioUnit, ScriptingBridge, Security, libobjc, libc++, libSystem.

Implication: SDK uses macOS-native USB/UVC discovery — no libusb shim. Must run with TCC permission for camera + USB-mass-storage access (for MTP).

### Verified exported symbols (via `nm -gU`)
C++ name-mangled, namespace `Device::*` (e.g., `__ZN6Device12cameraStatusEv`, `__ZN6Device11productTypeEv`). Plus log handlers `dev_set_log_handler` and `dev_get_log_handler` as C-callable. Internal use of **boost::filesystem** is bundled in (so no separate boost dep needed for consumers).

### Binary sizes
- macOS arm64 dylib: 1.6 MB
- Linux arm64 .so: 24 MB (probably with debug symbols)
- Windows release dll: 1.9 MB + 13 MB pdb

### Build requirements per platform
| Platform | Toolchain | Notes |
|---|---|---|
| macOS arm64 | Apple Clang (libc++), CMake | Need `-Wno-deprecated-declarations -Wno-switch -stdlib=libc++` per sample |
| macOS x86_64 | Same | Use `x86_64-release/` libdir |
| Linux arm64 | gcc/clang, CMake | libdev.so* (versioned soname) |
| Linux x86_64 | Same | |
| Windows x64 | MSVC, CMake | `/utf-8` flag + warning suppress; needs `w32-pthreads.dll` shipped alongside |

**On the dev machine right now: cmake is NOT installed.** Need to `brew install cmake` before building the bridge.

---

## 8. Limitations & Gotchas

1. **No headers for Tiny 3 / Tail 2 separately** — newer cameras share the existing API. Some methods say "tail2 and later products" — implies SDK auto-routes by `productType()`.
2. **`ENABLE_BLE_FUNC` build flag** — BLE pairing + Wi-Fi-config code only present if the SDK was compiled with BLE. The shipped libdev appears to NOT have BLE bits exported (no `__ZN8Devices*Bluetooth*` style symbols visible in the glance). For Tiny 2 Lite this is fine — USB-only. For future Tail Air support over Wi-Fi, this matters.
3. **No version compat metadata in headers** — must check firmware version field for some commands ("Devices with old firmwares may not support some of these states").
4. **Status struct is a `union`, indexed by `productType()`** — the bridge MUST switch on product type before reading. Wrong cast = junk data.
5. **`*R` commands have ~3s switching latency for media-mode/HDR/WDR** — header says "not suitable to switch frequently". Bridge should debounce these.
6. **Asynchronous callbacks run on SDK thread.** Bridge must not block in the callback (queue to a worker, return immediately).
7. **`gimbalRstPosR()` interacts with AI** — if AI is on, gimbal is owned by AI. Have to call `aiSetTargetSelectR(false)` (tiny/tiny4k) or `cameraSetAiModeU(AiWorkModeNone)` (tiny2) first. Bridge should expose a "manual mode" toggle.
8. **`PresetPosInfo.name` is fixed `char[64]`** — Flutter UI can pass UTF-8 names but truncate at 64 bytes.
9. **No streaming preview from SDK** — for camera thumbnail in the Flutter app, you'd need to either grab UVC frames (out-of-band, AVFoundation) or, on Tail Air, pull RTSP/NDI. SDK doesn't expose a video-frame callback.
10. **macOS code signing & TCC** — bridge binary will need camera/IOKit entitlements for distribution.
11. **No async device-connect API** — SDK auto-discovers; you wait for the `devChangedCallback`. Bridge needs an init delay (sample sleeps 3s).
12. **Documentation is in headers only.** No PDF, no online docs in this drop.
13. **`comm.hpp` defines `LIB_MAJOR_VER 1`, `LIB_MINOR_VER 3`, `LIB_REVISION 0`** → SDK 1.3.0. Check OBSBOT site for newer versions periodically.
14. **`Devices::close()` releases all resources** — bridge must call this on SIGINT/SIGTERM, otherwise USB handle stays held until process death.
15. **Many `[internal]`-tagged methods exist** (e.g., `cameraGetWdrR` is "[internal] Get the current WDR state"). Ship-time deprecation risk; prefer "external" Set methods + read state from `cameraStatus()` callbacks.

---

## 9. Open Questions / Defaults Picked

| Question | Default chosen |
|---|---|
| Does Tiny 2 Lite respond to all Tiny 2 commands? | **Yes** — same `tiny` status struct family, same product-type branch in sample. Confirm by running sample on the user's hardware. |
| Is there a video preview API? | **No, not in SDK.** Bridge will skip preview for v1; performer doesn't need it on stage. |
| Bluetooth/Wi-Fi config flow for Tail Air? | **Out of scope for v1.** Tiny 2 Lite is USB-only. Add when Tail Air support is requested. |
| Multi-camera support? | **`Devices` returns a list.** Bridge can iterate. WebSocket protocol must include a `device_id` (use `devSn()`) on every command. |
| Latency expectations? | Sample uses synchronous `R` calls + sleeps. Real measurement needed; expect <30 ms for UVC-tunneled commands. Add over-WiFi → phone budget of <100 ms is realistic. |
| Threading model? | SDK callbacks happen on internal threads. Bridge must own its own queue; don't issue SDK commands from inside a callback. |

---

## 10. Recommended Bridge App Architecture (informs Phase 2)

Based on the SDK realities:

1. **Language: C++ with one of: Crow / uWebSockets / Beast for WebSocket.** Reasoning:
   - SDK is a C++ class hierarchy with name-mangled symbols. Wrapping for Node.js/Python means writing N-API/pybind11 binding for ~208 methods and 30+ enums + complex unions in `CameraStatus`. That's weeks of glue code.
   - In C++, link `libdev` directly. Use a single-header WebSocket lib (uWebSockets or Crow) so the bridge is one binary with one shared lib (`libdev.dylib`).
   - Trade-off: less ergonomic to develop than Python. But 1-shot translation Device API → JSON protocol is mechanical.
2. **Alternative: C++ core + minimal C-ABI shim, then Rust binary using the shim.** Adds 3 weeks. Skip unless we want a memory-safe wrapper.
3. **Threading:** Single producer/single consumer queue between WebSocket I/O thread and an SDK-call thread. SDK callbacks → enqueue → broadcast to subscribed WS clients.
4. **Discovery:** mDNS / Bonjour broadcast (`_obsbot-bridge._tcp` service). Use Apple's `dnssd` API on macOS, Avahi on Linux, Bonjour Print Services on Windows.
5. **Process lifecycle:** signal handler → `Devices::get().close()` → exit.
6. **Logging:** Hook `dev_set_log_handler` to capture SDK logs into bridge log file.
7. **Config:** YAML/JSON file for port, mDNS name, TLS off-by-default (LAN-only).
8. **Distribution:** macOS notarized .app with helper service; Linux systemd unit; Windows service.

For Phase 2, the bridge spec should freeze at:
- WebSocket port 8765 (configurable)
- HTTP REST on 8766 for device list + config (rare, not realtime)
- mDNS service `_obsbot-bridge._tcp`
- Single binary (`obsbot-bridge`) + bundled `libdev.dylib`

---

## 11. Phase 1 Conclusions

- **SDK is comprehensive.** ~208 commands across 9+ camera families, with clear `@category` doc tags letting us auto-generate the compatibility matrix.
- **Tiny 2 Lite is well-supported** via the existing Tiny 2 code paths.
- **Bridge will be C++.** Writing N-API or Python bindings is more work than just linking libdev directly.
- **macOS-first dev is fine.** Prebuilt arm64 dylib works; `cmake` install needed (`brew install cmake`).
- **Threading + sync/async semantics** are the main implementation hazards. Plan a queue + worker model from day 1.
- **No video preview from SDK** — drop the "camera thumbnail" UI item from Phase 4 v1, or get it via AVFoundation directly.
- **Recommend proceeding to Phase 2 (Architecture + Protocol).** No blocking unknowns.
