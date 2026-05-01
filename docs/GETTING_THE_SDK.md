# OBSBOT SDK — local setup

This repo doesn't include the OBSBOT SDK in git. Each developer keeps their own copy locally at `third_party/obsbot-sdk/`. The build pulls `libdev.dylib` from there and bundles it inside the resulting `.app` — so the shipped DMG is self-contained and the end user doesn't deal with the SDK at all.

## How to get the SDK

OBSBOT's developer team emails the SDK on request:

1. Email **`developer@obsbot.com`** mentioning the OBSBOT camera you're working with.
2. They reply with a download link or attachment within a few business days.
3. Extract it to `third_party/obsbot-sdk/` at the root of this repo.

After extracting, the layout must be:

```
third_party/obsbot-sdk/
├── include/
│   ├── dev/{dev.hpp, devs.hpp}
│   └── util/comm.hpp
├── macos/
│   ├── arm64-release/libdev.dylib
│   └── x86_64-release/libdev.dylib
├── linux/...
├── windows/...
└── OBSBOT_Sample/
```

## Verify

From the repo root:

```bash
./scripts/verify-sdk.sh
```

Exits 0 if the SDK is in place, otherwise prints what's missing.

## Why it's gitignored

OBSBOT's SDK ships with no LICENSE / EULA / NOTICE file, so default copyright applies — we have no explicit redistribution license. Keeping it out of git history makes the repo safe to flip public later (or to add collaborators who don't have their own copy yet).

Builds bundle `libdev.dylib` into the macOS `.app` for end-user convenience. That bundling is also a redistribution and needs OBSBOT's blessing before we hand a DMG to anyone outside the team.

## Before going public

When we eventually open the repo:

1. Email OBSBOT for explicit redistribution wording (draft below).
2. If approved, leave the build flow as-is and add a `THIRD_PARTY_NOTICES` file with their wording.
3. If not approved, switch to BYOSDK (the install flow becomes "download DMG, drop libdev.dylib into a known path on first run").

### Email draft to OBSBOT

```
Subject: Open-source OBSBOT controller — SDK redistribution / licensing question

Hi OBSBOT developer team,

I'm building a phone-based remote for OBSBOT cameras (starting with Tiny 2 Lite).
Currently a private repo; I'd like to open-source it once a working demo is ready.

You sent me the Camera SDK by email. The archive didn't include a LICENSE / EULA /
NOTICE, so I want to confirm:

1. Am I permitted to:
   - Use libdev in personal / internal builds?
   - Bundle libdev.dylib inside a notarized macOS .app or DMG I distribute?
   - Include the SDK in a public open-source repo so other developers don't have
     to email you?

2. Do you have preferred attribution / wording for our README + a THIRD_PARTY_NOTICES
   file?

Happy to send source + a demo video for context. Thanks for the SDK.

— <name>
```
