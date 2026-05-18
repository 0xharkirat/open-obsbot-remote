// Playwright config for mobile e2e against the phone web app served by the
// bridge at http://localhost:8765/. Two profiles:
//
//   iPhone 15 Pro   - 393 x 852 logical, dpr 3, WebKit
//   Galaxy S22      - 360 x 780 logical, dpr 3, Chromium (Pixel-class Android UA)
//
// Hand-rolled viewports because @playwright/test ships device descriptors but
// the exact 393x852 / 360x780 pair matches the design targets in
// docs/UI_REDESIGN_SPEC.md - keep them pinned rather than chasing whatever
// Playwright ships for "iPhone 15 Pro" or "Galaxy S22" in a given release.
//
// Bridge does NOT need to be running for `npx playwright test --list` or for
// `npm install`. The spec itself probes the port and skips when the bridge
// isn't reachable - see tests/playwright/mobile.spec.mjs.

import { defineConfig, devices } from '@playwright/test';

const BASE_URL = process.env.BRIDGE_BASE_URL || 'http://localhost:8765';

export default defineConfig({
  testDir: '.',
  // One worker per project: the bridge is single-tenant per camera; running
  // viewport projects in parallel against the same bridge would race on
  // PTZ commands. Keep it serial for sanity.
  workers: 1,
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: [['list']],
  use: {
    baseURL: BASE_URL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    // Ignore the self-signed / ad-hoc nature of the dev bridge.
    ignoreHTTPSErrors: true,
  },
  projects: [
    {
      name: 'iphone-15-pro',
      use: {
        ...devices['iPhone 14 Pro'],
        // Pin exact target instead of relying on shipped descriptor.
        viewport: { width: 393, height: 852 },
        deviceScaleFactor: 3,
        isMobile: true,
        hasTouch: true,
        userAgent:
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) ' +
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 ' +
          'Mobile/15E148 Safari/604.1',
        // WebKit engine = iPhone reality.
        browserName: 'webkit',
      },
    },
    {
      name: 'galaxy-s22',
      use: {
        ...devices['Pixel 7'],
        viewport: { width: 360, height: 780 },
        deviceScaleFactor: 3,
        isMobile: true,
        hasTouch: true,
        userAgent:
          'Mozilla/5.0 (Linux; Android 13; SM-S901B) ' +
          'AppleWebKit/537.36 (KHTML, like Gecko) ' +
          'Chrome/120.0.0.0 Mobile Safari/537.36',
        browserName: 'chromium',
      },
    },
  ],
});
