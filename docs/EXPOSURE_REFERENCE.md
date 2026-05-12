# Exposure / image control reference - OBSBOT Center

> **Status: implemented in v1.2.** This was the reference capture for the
> exposure / anti-flicker / white balance section of the Image tab. The
> controls below shipped as part of `fix/ui-revamp-from-review` (folds
> together what was originally planned as PR F + PR G of the v1.2 PR
> sequence).
>
> Implementation notes (vs the open questions at the bottom of this doc):
>
> - **Auto Exposure refresh icon.** Not implemented in v1.2. OBSBOT
>   Center's refresh icon next to Auto Exposure / Auto WB is probably
>   a "re-apply your preference because the firmware may have drifted"
>   button. The user has not reported drift in real use, so this is
>   deferred. If it becomes a problem we can either add the same
>   button in our UI (passive: user-tap) or have the bridge re-apply
>   on a periodic tick (active).
> - **Compensation slider scale.** Mapped to `DevAEEvBiasType` (enum
>   -3.0 to +3.0 in 1/3 stops). Our UI shows the user-friendly range
>   -2.0 to +2.0 EV in 1/6-stop steps; the bridge snaps to the
>   nearest SDK enum value when writing.
> - **"tail air" tag on EV bias APIs.** RE-VERIFIED empirically on
>   Tiny 2 Lite firmware 6.2.8.1 (PR P, 2026-05-12 via
>   `tests/exposure_probe.mjs`): every exposure_mode + ev_bias variant
>   returns r=0. The earlier "unsupported" finding was wrong (likely a
>   firmware revision difference). The `unsupported` guard is now
>   removed; the bridge surfaces these as normal commands.
> - **AE Mode "Face".** Not surfaced in v1.2. Out of scope until
>   the SDK actually supports it on Tiny 2 Lite (the "Face" segmented
>   in OBSBOT Center appears to be tied to `cameraSetFaceAER`, which
>   we already expose as a separate toggle).

Captured from OBSBOT Center (macOS, Tiny 2 Lite). Originally written
ahead of the v1.2 exposure-controls PR so we knew the user-visible
shape before touching the bridge.

## Controls visible in OBSBOT Center (Image panel)

### Exposure section
- **Auto Exposure** - toggle (on/off). Refresh icon next to label
  (see note below).
- **Auto Exposure Mode** - segmented control: **Global** | **Face**.
- **Compensation** - slider, range visually centered on 0
  (presumed -100..+100 mapping to EV-bias enum).

### Flicker
- **Anti-Flicker** - segmented: **Off** | **50 Hz** | **60 Hz**.

### White balance
- **Auto** white balance toggle. Refresh icon ↻ next to label.
- **Temperature** slider when Auto is off - 2800k .. 6500k typical
  (shown 4700k as midpoint default).

### Image section
- **HDR** - toggle (off in capture - Tiny 2 Lite HDR DOL2TO1 needs
  tone-map; our bridge already auto-forces it off on connect).
- **Auto Focus** - toggle.
- **Auto Focus Mode** - segmented: **Global** | **Face**.
- **Contrast / Saturation / Sharpness / Hue** - 0..100 sliders,
  default 50.

## Open questions before implementing

1. **Why the refresh icon next to Auto Exposure + Auto WB?** - RESOLVED
   in PR P (2026-05-12). We mirror it in our UI with a single
   "Refresh from camera" action on the Image tab that calls the
   bridge `image.refresh` command. The bridge reads back
   exposure_mode / ev_bias / anti_flicker / wb_type+kelvin via
   `cameraGetExposureModeR`, `cameraGetAAEEvBiasR`,
   `cameraGetAntiFlickR`, `cameraGetWhiteBalanceR` and stamps its
   snapshot, which then flows out to every connected phone as a
   normal state event. Useful when OBSBOT Center or another phone
   changed values out-of-band.

2. **`Compensation` slider scale**: OBSBOT Center shows centered-at-0
   with no units. The libdev API exposes `DevAEEvBiasType` as a discrete
   enum from `-3.0` (idx 0) to `+3.0` (idx 18) in 1/3-stop increments.
   Need to confirm the Compensation slider maps to this enum or to a
   different finer-grained UVC parameter.

3. **"tail air" category on EV bias APIs**: RESOLVED in PR P. Tiny 2
   Lite firmware 6.2.8.1 accepts every enum (0..18) and every
   exposure_mode value with r=0. SDK header tag is misleading.

4. **AE Mode "Face"**: maps to `cameraSetFaceAER(true)`? Or to a
   separate exposure-mode enum? Verify before adding the toggle.

## SDK functions to plumb

```
cameraSetExposureModeR(int32_t exposure_mode)
cameraGetExposureModeR(int32_t& exposure_mode)
// DevExposureModeType: 0 unknown, 1 manual, 2 allauto, 3 aperture, 4 shutter

cameraSetAAEEvBiasR(DevAEEvBiasType ev_bias)    // valid -3.0..+3.0 in 1/3 stops
cameraGetAAEEvBiasR(int32_t& ev_bias)

cameraSetFaceAER(int)            // bool toggle
cameraGetFaceAER(bool&)

cameraSetWhiteBalanceR(...)      // auto / manual + temperature
cameraSetAntiFlickerR(int)       // 0=off / 1=50hz / 2=60hz (verify enum)
```

## Protocol additions (proposed)

```jsonc
// new actions:
{ "action": "image.set_exposure_mode", "mode": "auto" | "manual" }
{ "action": "image.set_ev_bias",       "bias": -2.0 }            // float, snaps to enum
{ "action": "image.set_face_ae_mode",  "mode": "global" | "face" }
{ "action": "image.set_anti_flicker",  "mode": "off" | "50" | "60" }
{ "action": "image.set_wb_auto",       "enabled": true }
{ "action": "image.set_wb_temp",       "kelvin": 4700 }
```

State event additions:

```jsonc
"image": {
  ...existing...,
  "exposure_mode": "auto",
  "ev_bias": 0.0,
  "anti_flicker": "off",
  "wb_auto": true,
  "wb_kelvin": 4700
}
```

## UI placement (per UI_REDESIGN_SPEC.md, Image tab)

```
Image tab
├── Exposure
│   ├── Auto / Manual segmented
│   ├── Mode: Global / Face (when auto)
│   ├── Compensation slider (-2.0 EV ↔ +2.0 EV)
│   └── Anti-Flicker: Off / 50 Hz / 60 Hz
├── White balance
│   ├── Auto toggle
│   └── Temperature slider (2800-6500 k)
├── Focus
│   ├── Auto toggle
│   └── Mode: Global / Face
└── Color
    ├── Brightness, Contrast, Saturation, Sharpness, Hue (0-100)
    ├── HDR toggle (with low-light hint)
    └── Flip horizontal toggle
```

## Reference screenshots

Two screenshots from OBSBOT Center attached in PR / issue
comments (not committed - large binary). Key visual cues:

- All toggles use a red "on" state, matching OBSBOT brand
- Segmented controls use a 2-tab pill (red active, dark inactive)
- Sliders use a horizontal red bar with a circular white thumb +
  a numeric value box on the right
- Section headers use larger weight type with a small reset/refresh
  icon to the right of the section label
