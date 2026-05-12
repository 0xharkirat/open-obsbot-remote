## Problem

<!-- One paragraph: what real-world symptom or feedback prompted this change.
Link the issue if any. -->

## Fix

<!-- One-line summary of the change (matches the squashed commit subject). -->

## Surface changes

- [ ] WebSocket protocol (`docs/PROTOCOL.md` updated)
- [ ] Bridge subprocess (`apps/bridge_cpp/`)
- [ ] Bridge desktop UI (`apps/bridge/`)
- [ ] RC mobile/web (`apps/rc/`)
- [ ] Documentation only

## Verification

- [ ] `flutter analyze` clean (apps/rc and apps/bridge)
- [ ] `cmake --build apps/bridge_cpp/build` clean
- [ ] `./scripts/build-bridge-mac.sh` produces a working `.app`
- [ ] Bridge smoke battery passes against real Tiny 2 Lite (or a documented superset if this PR adds new tests):
  - `tests/bridge_smoke.mjs` 27 tests
  - `tests/zoom_speed.mjs` 9 tests
  - `tests/slow_motion.mjs` 7 tests
  - `tests/sequencer_save.mjs` 6 tests
  - `tests/exposure.mjs` 8 tests
  - `tests/zoom_smoothness.mjs` (visual fluidity at 5 s / 30 s plans)
- [ ] Offline widget tests: `cd apps/rc && flutter test` (currently 21 tests)
- [ ] Manual: <!-- e.g. "camera plugged in, ran sequencer with ping-pong, watched it cycle for 5 minutes" -->
- [ ] Touch regression (if UI): tested at 360x800 / 390x844 / 768x1024 via Playwright CDP touch emulation per `docs/TOUCH_FINDINGS_2026-05-10.md`

## Risk / rollout

<!-- Anything that could regress. Feature flags. Bumped versions.
Migration steps for existing pairings / saved sequences. -->

## Screenshots / recordings

<!-- If UI changes, attach screenshots or a 5-second screen recording. -->

## Anything reviewers should pay extra attention to?

<!-- New gotchas worth adding to CLAUDE.md? Tricky concurrency? Subtle protocol change? -->

---

By opening this PR I confirm I've read [docs/CONTRIBUTING.md](../docs/CONTRIBUTING.md).
