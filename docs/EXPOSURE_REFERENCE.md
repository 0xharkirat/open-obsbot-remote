# Exposure / image control reference — OBSBOT Center

Captured from OBSBOT Center (macOS, Tiny 2 Lite) for the future
`feat/exposure-controls` PR. **Do not implement before the UI redesign
PRs land** — exposure controls will live inside the new "Image" tab.

## Controls visible in OBSBOT Center (Image panel)

### Exposure section
- **Auto Exposure** — toggle (on/off). Refresh icon ↻ next to label —
  see note below.
- **Auto Exposure Mode** — segmented control: **Global** | **Face**.
- **Compensation** — slider, range visually centered on 0
  (presumed -100..+100 mapping to EV-bias enum).

### Flicker
- **Anti-Flicker** — segmented: **Off** | **50 Hz** | **60 Hz**.

### White balance
- **Auto** white balance toggle. Refresh icon ↻ next to label.
- **Temperature** slider when Auto is off — 2800k .. 6500k typical
  (shown 4700k as midpoint default).

### Image section
- **HDR** — toggle (off in capture — Tiny 2 Lite HDR DOL2TO1 needs
  tone-map; our bridge already auto-forces it off on connect).
- **Auto Focus** — toggle.
- **Auto Focus Mode** — segmented: **Global** | **Face**.
- **Contrast / Saturation / Sharpness / Hue** — 0..100 sliders,
  default 50.

## Open questions before implementing

1. **Why the refresh icon next to Auto Exposure + Auto WB?** — likely
   means the SDK / camera firmware can lose the auto state and OBSBOT
   Center polls to re-sync. We should verify whether
   `cameraGetExposureModeR` / `cameraGetMAEIsoR` drift, and decide
   whether to:
   - mirror the refresh button in our UI (passive), or
   - have the bridge auto-re-apply on a periodic tick (active).
   This matters because the user reported "auto exposure makes
   camera very dark always" — possibly the firmware is silently
   reverting to a different mode and OBSBOT Center's refresh button
   re-applies the user's preference.

2. **`Compensation` slider scale**: OBSBOT Center shows centered-at-0
   with no units. The libdev API exposes `DevAEEvBiasType` as a discrete
   enum from `-3.0` (idx 0) to `+3.0` (idx 18) in 1/3-stop increments.
   Need to confirm the Compensation slider maps to this enum or to a
   different finer-grained UVC parameter.

3. **"tail air" category on EV bias APIs**: SDK header tags
   `cameraSetAAEEvBiasR` / `cameraSetPAEEvBiasR` / `cameraSetSAEEvBiasR`
   under `tail air` — needs empirical test whether Tiny 2 Lite accepts.

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
│   └── Temperature slider (2800–6500 k)
├── Focus
│   ├── Auto toggle
│   └── Mode: Global / Face
└── Color
    ├── Brightness, Contrast, Saturation, Sharpness, Hue (0–100)
    ├── HDR toggle (with low-light hint)
    └── Flip horizontal toggle
```

## Reference screenshots

Two screenshots from OBSBOT Center attached in PR / issue
comments (not committed — large binary). Key visual cues:

- All toggles use a red "on" state, matching OBSBOT brand
- Segmented controls use a 2-tab pill (red active, dark inactive)
- Sliders use a horizontal red bar with a circular white thumb +
  a numeric value box on the right
- Section headers use larger weight type with a small reset/refresh
  icon to the right of the section label
