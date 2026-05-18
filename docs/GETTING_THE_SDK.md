# OBSBOT SDK  -  local setup

This repo does not include the OBSBOT SDK in git. Each developer keeps a local copy at `third_party/obsbot-sdk/`. The macOS build pulls `libdev.dylib` from there and bundles it inside the resulting `.app`.

Do not commit the SDK files. GitHub Release ZIPs may include the runtime `libdev.dylib` inside `Open OBSBOT Bridge.app`, but the full SDK package, headers, samples, and archives stay out of git.

## How to get the SDK

1. Go to **<https://www.obsbot.com/sdk>**.
2. Fill in the short form with the camera model and use case, for example "third-party local camera controller".
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

OBSBOT's SDK ships separately from this repo. Keeping it out of git history lets the source repo stay public without committing third-party SDK headers or samples.

Builds bundle `libdev.dylib` into the macOS `.app` for convenience. Check OBSBOT's SDK terms before publishing release assets that include the runtime dylib.
