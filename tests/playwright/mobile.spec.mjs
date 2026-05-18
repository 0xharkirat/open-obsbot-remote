// Mobile e2e smoke against the Flutter web build of the phone app, served
// by the bridge at http://localhost:8765/.
//
// Run per viewport (see playwright.config.mjs for iPhone 15 Pro + Galaxy S22):
//   1. Page loads, title contains "OBSBOT".
//   2. If pair screen renders, read the live PIN from the bridge's auth.json
//      and type it. Tests skip if the file is missing (CI / fresh checkout).
//   3. Drive / Image / More tabs visible (v1.4 W6 shell).
//   4. The preview <img> element is present (bridge may not have a camera;
//      503 fine).
//   5. Tap each tab; assert content swaps.
//   6. Tap Image; assert Face exposure / Face focus / HDR / Flip toggles.
//   7. Screenshot per viewport for visual regression.
//
// Bridge readiness: spec probes port 8765 and skips the whole test when the
// bridge isn't listening. That keeps the spec listable + CI-safe without
// requiring a live bridge.
//
// Flutter web rendering notes:
//   - Build runs CanvasKit, so widget text is rasterised into a <canvas>;
//     getByText() can't see it directly.
//   - The pair screen TextField renders into <flt-text-editing-host> as a
//     real <input class="flt-text-editing"> the Flutter engine intercepts.
//     `page.keyboard.type` after focus updates the Dart-side controller;
//     `input.fill()` does NOT (it bypasses the Flutter input adapter).
//   - We enable Flutter's semantics tree by clicking the
//     <flt-semantics-placeholder> hidden button via dispatchEvent. After
//     that all widget labels appear under <flt-semantics> as DOM text.

import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import net from 'node:net';

const AUTH_PATH = `${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`;
const BASE_URL = process.env.BRIDGE_BASE_URL || 'http://localhost:8765';

// Best-effort TCP probe: connect, dispose. Returns boolean.
async function bridgeListening() {
  const { hostname, port } = new URL(BASE_URL);
  return new Promise((resolve) => {
    const sock = new net.Socket();
    const done = (ok) => {
      sock.destroy();
      resolve(ok);
    };
    sock.setTimeout(750);
    sock.once('connect', () => done(true));
    sock.once('error', () => done(false));
    sock.once('timeout', () => done(false));
    sock.connect(Number(port) || 8765, hostname || 'localhost');
  });
}

function readPin() {
  try {
    const raw = fs.readFileSync(AUTH_PATH, 'utf8');
    const j = JSON.parse(raw);
    if (typeof j.pin === 'string' && /^\d{6}$/.test(j.pin)) return j.pin;
  } catch {
    /* fall through */
  }
  return null;
}

// Wait for the Flutter engine to mount. The reliable signal across both
// canvaskit and skwasm builds is <flutter-view> / <flt-glass-pane> /
// <flt-semantics-host>.
async function waitForFlutter(page) {
  await page.waitForFunction(
    () => (
      document.querySelector('flutter-view') !== null ||
      document.querySelector('flt-glass-pane') !== null ||
      document.querySelector('flt-semantics-host') !== null
    ),
    { timeout: 30_000 }
  );
}

// Activate the Flutter semantics tree. Flutter exposes a hidden
// <flt-semantics-placeholder role="button" aria-label="Enable accessibility">
// that's positioned outside the viewport (so screen readers find it but
// mouse users don't). page.click won't reach it (outside viewport); a JS
// dispatch does.
async function enableSemantics(page) {
  await page.evaluate(() => {
    const ph = document.querySelector('flt-semantics-placeholder');
    if (!ph) return false;
    ph.click();
    ph.dispatchEvent(new Event('click', { bubbles: true }));
    return true;
  });
  // Wait for at least one <flt-semantics> node to appear, which means
  // the engine has built the semantics tree.
  await page
    .waitForFunction(() => document.querySelectorAll('flt-semantics').length > 0, {
      timeout: 10_000,
    })
    .catch(() => {
      /* OK to proceed - some screens have nothing to label. */
    });
}

// Find a Flutter widget label by traversing both DOM and the semantics
// tree. Returns the first locator that matches.
//
// Flutter exposes button / tab widgets as
//   <flt-semantics role="tab" aria-label="Image"></flt-semantics>
// with EMPTY textContent (the visible glyphs are on the canvas). So
// getByText doesn't see those - we have to OR against aria-label too.
function anyText(page, needle) {
  // Build an OR locator: aria-label exact OR getByText partial.
  const escaped = String(needle).replace(/"/g, '\\"');
  return page
    .locator(`[aria-label="${escaped}"], :text("${escaped}")`)
    .first();
}

// Tap a label. Prefer ARIA role=button / role=tab from the semantics tree,
// fall back to text matching anywhere in the DOM.
async function tapByLabel(page, label) {
  const candidates = [
    page.getByRole('tab', { name: label }),
    page.getByRole('button', { name: label }),
    page.locator(`[aria-label="${label}"]`),
    // flt-semantics text nodes - dispatch click on the parent that has
    // the button role.
    page.locator(`flt-semantics[role="button"]:has-text("${label}")`),
    page.getByText(label, { exact: false }),
  ];
  for (const c of candidates) {
    if (await c.count().catch(() => 0)) {
      // force: true bypasses the "outside viewport" / "transparent"
      // guards that flt-semantics nodes routinely fail.
      await c.first().click({ force: true }).catch(() => {});
      return true;
    }
  }
  return false;
}

test.describe('phone web app mobile smoke', () => {
  // First Flutter web boot + pairing + tab walk can easily exceed the 30s
  // default. CanvasKit download + initial paint alone is ~5-10s.
  test.setTimeout(120_000);

  test.beforeAll(async () => {
    const up = await bridgeListening();
    test.skip(!up, `bridge not listening on ${BASE_URL}; start the bridge first`);
  });

  test('loads, pairs (if needed), tab structure, image toggles', async ({ page, context }, testInfo) => {
    const url = `${BASE_URL}/?enable-semantics=true`;

    // Default mode is "simple" (presets-only view); the tab shell we want
    // to exercise is the "advanced" mode. Pre-seed SharedPreferences so
    // first paint lands in TabShell. Flutter web's shared_preferences
    // plugin uses `localStorage` with `flutter.` prefix.
    await context.addInitScript(() => {
      try {
        window.localStorage.setItem('flutter.mode', '"advanced"');
      } catch {
        /* private mode: skip */
      }
    });

    const navOk = await page
      .goto(url, { waitUntil: 'domcontentloaded', timeout: 15_000 })
      .then(() => true)
      .catch(() => false);
    test.skip(!navOk, `could not GET ${url}; bridge may have stopped`);

    // (1) Title contains OBSBOT (DOM-level, always available).
    await expect(page).toHaveTitle(/OBSBOT/i);

    await waitForFlutter(page);
    await enableSemantics(page);
    // Settle: networkidle may never resolve due to the long-lived WS, so
    // cap the wait.
    await page.waitForLoadState('networkidle', { timeout: 6_000 }).catch(() => {});

    // (2) Pair screen handling. After enableSemantics() the helper copy
    // is visible in <flt-semantics> DOM text.
    const pairHint = anyText(page, 'Enter the 6-digit PIN');
    const tabHintDrive = anyText(page, 'Drive');

    await Promise.race([
      pairHint.waitFor({ state: 'visible', timeout: 15_000 }).catch(() => null),
      tabHintDrive.waitFor({ state: 'visible', timeout: 15_000 }).catch(() => null),
    ]);

    if (await pairHint.isVisible().catch(() => false)) {
      const pin = readPin();
      test.skip(!pin, 'pair screen visible but auth.json missing/invalid; skipping');

      // Focus Flutter's hidden text-editing input + type real keystrokes.
      // input.fill() does NOT propagate to the Dart-side
      // TextEditingController; only keystrokes Flutter intercepts do.
      const fltInput = page.locator('input.flt-text-editing').first();
      const hasFlt = await fltInput.count();
      if (hasFlt) {
        await fltInput.focus();
      } else {
        // Older Flutter or a regular Material input. Fall back to any input.
        const anyInput = page.locator('input').first();
        if (await anyInput.count()) await anyInput.focus();
      }
      await page.keyboard.type(pin, { delay: 80 });

      // onChanged auto-submits at length==6; be defensive and tap Pair if
      // it's still around.
      await page.waitForTimeout(1500);
      await tapByLabel(page, 'Pair').catch(() => {});
      await tabHintDrive.waitFor({ state: 'visible', timeout: 25_000 }).catch(() => {});

      // Re-enable semantics on the new screen (the tree resets on route
      // change).
      await enableSemantics(page);
    }

    // If first paint landed in simple mode (addInitScript races vs the
    // bootloader on some browsers), flip to advanced by tapping the
    // tune icon's tooltip target.
    const driveSeenEarly = await anyText(page, 'Drive')
      .isVisible()
      .catch(() => false);
    if (!driveSeenEarly) {
      await tapByLabel(page, 'Advanced mode').catch(() => {});
      await page.waitForTimeout(800);
      await enableSemantics(page);
    }

    // (3) Tab structure: Drive / Image / More.
    for (const label of ['Drive', 'Image', 'More']) {
      await expect(
        anyText(page, label),
        `tab label "${label}" should be visible`
      ).toBeVisible({ timeout: 15_000 });
    }

    // (4) Preview <img> present. Don't assert frame content - bridge may
    // not have a camera and the spec is about UI shape, not pixels.
    expect(
      await page.locator('img').count(),
      'expected at least one <img> element for the MJPEG preview surface'
    ).toBeGreaterThan(0);

    // (5) Tap each tab; assert a signature element from that tab. Iterate
    // in a non-default order so the swap is exercised each time.
    const tabSignatures = [
      { tab: 'More', signal: /About|Connection|Sequence library|Grid/i },
      { tab: 'Drive', signal: /Recenter|Zoom|Joystick|Preset/i },
      { tab: 'Image', signal: /HDR|Face exposure|Flip/i },
    ];
    for (const { tab, signal } of tabSignatures) {
      await tapByLabel(page, tab);
      await page.waitForTimeout(700);
      await expect(
        page.getByText(signal).first(),
        `after tapping "${tab}" expected to see ${signal}`
      ).toBeVisible({ timeout: 12_000 });
    }

    // (6) Image tab: assert the four toggles render.
    await tapByLabel(page, 'Image');
    await page.waitForTimeout(700);
    for (const label of ['Face exposure', 'Face focus', 'HDR', 'Flip']) {
      await expect(
        anyText(page, label),
        `Image toggle "${label}" should be visible`
      ).toBeVisible({ timeout: 12_000 });
    }

    // (7) Screenshot for visual regression.
    await testInfo.attach('image-tab', {
      body: await page.screenshot({ fullPage: true }),
      contentType: 'image/png',
    });
  });
});
