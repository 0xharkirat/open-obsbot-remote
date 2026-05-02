## Summary

<!-- 1-3 bullet points describing what changes and why. Reference the issue number if any. -->

## Surface changes

- [ ] WebSocket protocol (`docs/PROTOCOL.md` updated)
- [ ] Bridge subprocess (`apps/bridge_cpp/`)
- [ ] Bridge desktop UI (`apps/bridge/`)
- [ ] RC mobile/web (`apps/rc/`)
- [ ] Documentation only

## Test plan

<!-- How did you verify this works? -->

- [ ] `flutter analyze apps/rc apps/bridge` — clean
- [ ] `cmake --build apps/bridge_cpp/build` — clean
- [ ] `./scripts/build-bridge-mac.sh` produces a working `.app`
- [ ] Manual: <!-- e.g. "camera plugged in, ran sequencer with ping-pong, watched it cycle for 5 minutes" -->

## Screenshots / recordings

<!-- If UI changes, attach screenshots or a 5-second screen recording. -->

## Anything reviewers should pay extra attention to?

<!-- New gotchas worth adding to CLAUDE.md? Tricky concurrency? Subtle protocol change? -->
