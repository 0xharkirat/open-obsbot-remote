# Roadmap to public release

This document is the checklist between the current private demo and a public open-source repo.

## Status today

✅ End-to-end working: PIN-paired phone control of a Tiny 2 Lite via a Mac bridge, web + native clients, sequencer with named libraries, live MJPEG preview, simple mode for stage use, advanced mode for tuning. Replaces OBSBOT Center for everything except firmware updates.

✅ Repo is private at `0xharkirat/obsbot-control`.

✅ SDK is gitignored. Built artifacts include `libdev.dylib` from the developer's local copy, copied into the .app at build time.

## TL;DR — when can I make the repo public?

**You can flip the repo public right now.** The SDK is gitignored, all source is Apache-2.0 + permissive third-party deps. Anyone cloning it would build from source and need their own SDK copy from OBSBOT. Standard BYOSDK pattern. **No legal exposure** in the source repo itself.

**You can also publish a first Mac release right now**, with one of two choices:

1. **Ship an ad-hoc-signed DMG.** Free. Gatekeeper warns "unidentified developer" on first launch; user right-clicks → Open. Fine for sharing with friends + early users. **The DMG would bundle `libdev.dylib`, which is OBSBOT's binary.** That's a redistribution. To be safe legally, send the email below first; if you ship before they reply, it's a calculated risk that nobody has been sued for in similar situations but isn't zero.

2. **Ship a notarized DMG.** Requires $99/year Apple Developer Program + a 1-day setup of Developer ID Application cert + `notarytool submit`. Same SDK-redistribution caveat as #1.

3. **BYOSDK release** (defensive). DMG ships **without** `libdev.dylib`. App on first launch checks `~/Library/Application Support/Open OBSBOT Bridge/sdk/libdev.dylib`; if missing, shows a screen with the obsbot.com download instructions. Legal posture is bulletproof — you're never redistributing their binary. Bad UX (extra step for non-devs) but acceptable for v1.

### My recommendation

1. **Today**: flip repo public + tag `v1.0.0-rc1`. Source is clean.
2. **This week**: send the OBSBOT email (draft in [docs/GETTING_THE_SDK.md](GETTING_THE_SDK.md)) asking explicitly:
   - "May we bundle libdev.dylib in our DMG distribution on GitHub Releases?"
   - "Preferred attribution wording in our README?"
3. **Next week**: depending on reply, either ship ad-hoc / notarized DMG with libdev included (best path), or fall back to BYOSDK first-run flow.

## Pre-public checklist

### Legal / licensing (the gating items)

- [ ] **Email OBSBOT** for SDK redistribution permission. Draft is in [docs/GETTING_THE_SDK.md](GETTING_THE_SDK.md). Three possible answers and what we do for each:

  | Their answer | Our action |
  |---|---|
  | "Yes, you can bundle libdev in your distributable" | Public repo can include SDK in `third_party/`, DMG ships ready-to-run. Add `THIRD_PARTY_NOTICES` file with their wording. |
  | "No, but you can link against it" | Public repo stays gitignored; DMG releases on GitHub also can't include libdev. Users follow BYOSDK flow: install our .app, on first run drop libdev.dylib into `~/Library/Application Support/Open OBSBOT Bridge/sdk/`. |
  | (No reply within 2 weeks) | Default to BYOSDK flow above. |

- [ ] **Apache 2.0 NOTICE** file listing third-party deps:
  - Crow (BSD-3) — `apps/bridge_cpp/third_party/crow_all.h`
  - nlohmann/json (MIT) — `apps/bridge_cpp/third_party/json.hpp`
  - Flutter packages: `flutter_mjpeg` (MIT), `qr_flutter` (BSD-3), `web` (BSD-3), `window_manager` (MIT), `shared_preferences` (BSD-3)
  - OBSBOT SDK if approved for redistribution

- [ ] **Trademark check**: "OBSBOT" is OBSBOT Tech's trademark. Project name uses "Open OBSBOT" — could be challenged. Either get OBSBOT's blessing (probably yes since this helps their product) or rename to something neutral like "OpenCam Remote" before going public.

### Code quality

- [x] All `flutter analyze` warnings down to deprecated-API + style infos only.
- [x] No TODOs that block the demo path.
- [ ] Add basic unit tests:
  - Bridge: protocol-parsing round-trip
  - RC: `CameraState.fromEvent` decoder, ws_client pair flow
- [ ] Add a CI workflow (`.github/workflows/ci.yml`) running:
  - `flutter analyze` for `apps/rc` + `apps/bridge`
  - `cmake --build` for `apps/bridge_cpp` (skipping if SDK absent — CI doesn't have it)

### Distribution artifacts

- [ ] **Notarized DMG** for macOS. Steps:
  1. Apple Developer ID account (you have one).
  2. Generate a Developer ID Application certificate, install in Keychain.
  3. Update `build-bridge-mac.sh` to sign with `-s "Developer ID Application: <Name> (<TeamID>)"` instead of ad-hoc `-`.
  4. Build the DMG (`hdiutil create` or `create-dmg`).
  5. Run `notarytool submit ... --wait`.
  6. `xcrun stapler staple` the resulting DMG.
- [ ] **Android APK** signed release build. `keystore.jks` excluded from repo via `android/key.properties`.
- [ ] **iOS** — TestFlight is the next step; final App Store decision depends on whether we want to go that route at all (web client may suffice).

### Documentation polish

- [x] README accurate to current state.
- [x] CLAUDE.md / AGENTS.md current.
- [x] CHANGELOG covers v0.1 through current.
- [x] PROTOCOL.md updated for auth + sequencer + speed actions.
- [x] ARCHITECTURE.md updated for current stack.
- [x] RUN.md updated with PIN flow + simple-mode walkthrough.
- [ ] Add `docs/SECURITY.md` — how to report vulnerabilities (LAN-only for now, but document the pattern).
- [ ] Add 30-second screen recording / GIF to README so people can see what it does without building it.
- [ ] Add screenshots of: bridge window with PIN visible, simple mode preset grid on phone, sequencer editor.

### Repo-level

- [x] LICENSE (Apache 2.0).
- [x] CONTRIBUTING.md.
- [x] CODE_OF_CONDUCT.md.
- [ ] `.github/ISSUE_TEMPLATE/bug_report.yml`
- [ ] `.github/ISSUE_TEMPLATE/feature_request.yml`
- [ ] `.github/PULL_REQUEST_TEMPLATE.md`
- [ ] `.github/SECURITY.md` (or root `SECURITY.md`)
- [ ] GitHub repo description, topics (`obsbot`, `flutter`, `webrtc`, `tiny-2-lite`, `camera-control`, `sikh-temple` 🙂).

### Polish before announcing

- [ ] Make the OBSBOT Center "must quit first" message a banner inside the bridge UI instead of buried in CLAUDE.md.
- [ ] Add a "Demo Mode" or screencast for first-time installs.
- [ ] Set up GitHub Releases page workflow that auto-builds + uploads DMG + APK on each tag.

## Open-source release sequence (recommended order)

1. **Land OBSBOT's licensing answer** (or wait 2 weeks and assume BYOSDK).
2. **Final docs pass** (this checklist's documentation rows).
3. **CI + tests** so the public sees a green build.
4. **Notarize macOS .app**, build first signed DMG.
5. **Tag `v1.0.0`**, push.
6. **Flip repo public** via GitHub settings.
7. **Publish a Release** with DMG + APK attached.
8. **Announce** on Hacker News, r/streaming, OBSBOT user forums, your Twitter.

## What stays private even after public

- The author's local copy of the OBSBOT SDK at `third_party/obsbot-sdk/` — `.gitignore` keeps it out forever.
- Apple Developer signing certificates (in macOS Keychain, never on disk).
- Android keystore (`apps/rc/android/key.properties`, gitignored).

## Long-term roadmap (post-public)

- WebRTC preview alongside MJPEG (lower latency, hardware H.264 decode on phone).
- Foreground service on Android APK so WS stays alive when phone backgrounds.
- Pigeon → Swift → libdev rewrite of the bridge subprocess (single-process .app).
- Windows + Linux bridge builds.
- Tail Air, Tiny SE, Meet series support — same protocol, different camera-status decoders.
- Multi-camera coordination on one bridge.
- OBS Studio plugin: when a preset is recalled, switch to a configured OBS scene.
