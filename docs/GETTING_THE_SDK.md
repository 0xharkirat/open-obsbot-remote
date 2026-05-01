# Getting the OBSBOT Camera SDK

This project depends on the OBSBOT Camera SDK (`libdev`), which OBSBOT distributes directly to developers and **cannot be redistributed** under their terms. You'll need to obtain your own copy before you can build the bridge.

## Why the SDK isn't in this repo

The SDK ships as compiled libraries (`libdev.dylib`, `libdev.so`, `libdev.dll`) plus C++ headers. OBSBOT provides it on request to developers building on top of their cameras. Per their distribution practice it is **not** open source, so it stays out of this repository.

## How to request it

1. Email **`developer@obsbot.com`** (or use the [OBSBOT Developer Contact form](https://www.obsbot.com/) — look for *Developer / SDK* under support).
2. Mention the camera model you're working with (Tiny 2 Lite / Tiny 2 / Tail Air etc.) and that you're building a third-party control tool.
3. They typically reply with a download link or zipped attachment within a few business days.

The SDK is the same regardless of whether you're a hobbyist or a company — they don't currently charge for it.

## Where to put it

After you receive the archive, extract it into `third_party/obsbot-sdk/` at the **root of this repo**. The final layout must look like:

```
third_party/obsbot-sdk/
├── include/
│   ├── dev/
│   │   ├── dev.hpp
│   │   └── devs.hpp
│   └── util/
│       └── comm.hpp
├── macos/
│   ├── arm64-release/
│   │   └── libdev.dylib
│   └── x86_64-release/
│       └── libdev.dylib
├── linux/
│   ├── arm64-release/
│   └── x86_64-release/
├── windows/
│   ├── win64-release/
│   └── win64-debug/
└── OBSBOT_Sample/
    ├── CMakeLists.txt
    └── main.cpp
```

If the archive you receive uses different top-level names, just rename it to `obsbot-sdk` and place the `include/`, `macos/`, etc. directories directly inside.

## Verifying

From the repo root, run:

```bash
./scripts/verify-sdk.sh
```

It exits 0 if everything is in place, or prints a list of missing files.

## Versioning

This codebase was developed against **SDK 1.3.0** (`LIB_MAJOR_VER 1`, `LIB_MINOR_VER 3`, `LIB_REVISION 0`). Newer versions should be backwards-compatible at the API level. If something breaks against a newer SDK, please open an issue.

## A note on licensing

Because the SDK can't be redistributed, this project alone won't build into a usable binary out of the box for someone who clones the repo. They'll need to:

1. Clone this repo (Apache 2.0).
2. Email OBSBOT for the SDK.
3. Drop it into `third_party/obsbot-sdk/`.
4. Run the build.

We document this clearly in the root README so contributors aren't surprised. If OBSBOT ever publishes the SDK openly, the build will then "just work" with a fresh clone.
