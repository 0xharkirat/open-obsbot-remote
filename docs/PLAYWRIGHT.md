# Playwright mobile e2e

Mobile end-to-end smoke against the Flutter web build of the phone app, served
by the bridge at `http://localhost:8765/`.

Two device profiles run per spec:

| Profile        | Viewport (logical) | DPR | Engine    |
|----------------|--------------------|-----|-----------|
| iPhone 15 Pro  | 393 x 852          | 3   | WebKit    |
| Galaxy S22     | 360 x 780          | 3   | Chromium  |

The viewports are pinned by hand rather than re-using whatever the Playwright
`devices` table ships, so the spec matches the design targets in
`docs/UI_REDESIGN_SPEC.md` and won't drift across Playwright versions.

## Setup (one-time)

```bash
cd tests/playwright
npm install                 # installs @playwright/test
npx playwright install      # downloads browser binaries (WebKit + Chromium)
```

Neither command needs the bridge running.

## Run

1. Launch the bridge so it serves the phone web build on `:8765`:

   ```bash
   ./scripts/build-bridge-mac.sh
   open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
   ```

2. Confirm `http://localhost:8765/` loads in a browser.

3. Run the spec:

   ```bash
   cd tests/playwright
   npx playwright test
   ```

## Behaviour when the bridge isn't running

The spec probes port 8765 in `beforeAll`. If the bridge isn't listening,
every test is **skipped** (not failed). That keeps the harness listable and
CI-safe without requiring a live bridge:

```bash
cd tests/playwright
npx playwright test --list   # works without the bridge
```

If the bridge is up but the pair screen renders without a usable
`~/Library/Application Support/Open OBSBOT Bridge/auth.json`, the pair step
also skips rather than failing.

## What the smoke covers

For each viewport profile:

1. Page loads; `<title>` contains `OBSBOT`.
2. If the pair screen renders, the spec reads the live PIN from
   `auth.json` and types it. (Skips if the file is missing.)
3. The `Drive` / `Image` / `More` tab strip is visible.
4. The preview `<img>` element is present. (Frame content not asserted;
   bridge may not have a camera and that's fine.)
5. Each tab is tapped and a signature element from that tab appears.
6. On the Image tab, the `Face exposure` / `Face focus` / `HDR` / `Flip`
   toggles render.
7. A full-page screenshot is attached to the report for visual regression.

## Override base URL

To point at a bridge on another host (e.g. a Mac on your LAN at
`192.168.1.20`):

```bash
BRIDGE_BASE_URL=http://192.168.1.20:8765 npx playwright test
```

The port probe and the `goto` both use `BRIDGE_BASE_URL`.

## Where it fits in the test battery

This is additive. Existing test files (`tests/bridge_smoke.mjs`,
`tests/sequencer_save.mjs`, etc.) still run from `tests/` with `node`. The
Playwright suite lives in its own npm workspace under `tests/playwright/`
so adding `@playwright/test` (and its 200+ MB of browser binaries) doesn't
contaminate the backend smoke harness.
