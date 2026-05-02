# OBSBOT SDK — local setup

This repo doesn't include the OBSBOT SDK in git. Each developer keeps their own copy locally at `third_party/obsbot-sdk/`. The build pulls `libdev.dylib` from there and bundles it inside the resulting `.app` — so the shipped DMG is self-contained and the end user doesn't deal with the SDK at all.

## How to get the SDK

1. Go to **<https://www.obsbot.com/sdk>**.
2. Fill in the short form (camera model + your use case — "third-party controller for Tiny 2 Lite" is fine).
3. They typically reply with a download link within minutes (sometimes hours, rarely longer).
4. Download the archive, unzip, and rename the extracted folder to `obsbot-sdk`.
5. Drop it into `third_party/` at the root of this repo so the path becomes `third_party/obsbot-sdk/include/dev/dev.hpp` etc.

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

