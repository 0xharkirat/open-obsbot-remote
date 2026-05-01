#!/usr/bin/env bash
# Fail fast if the OBSBOT SDK isn't in place.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$ROOT/third_party/obsbot-sdk"

missing=()
[[ -f "$SDK/include/dev/dev.hpp" ]]                          || missing+=("include/dev/dev.hpp")
[[ -f "$SDK/include/dev/devs.hpp" ]]                         || missing+=("include/dev/devs.hpp")
[[ -f "$SDK/include/util/comm.hpp" ]]                        || missing+=("include/util/comm.hpp")
[[ -f "$SDK/macos/arm64-release/libdev.dylib" ]]             || missing+=("macos/arm64-release/libdev.dylib")

if (( ${#missing[@]} )); then
  cat <<MSG >&2
OBSBOT SDK is missing required files at $SDK:

  $(printf '  - %s\n' "${missing[@]}")

The SDK is distributed by OBSBOT directly and cannot be redistributed.
Follow docs/GETTING_THE_SDK.md to obtain a copy, then extract it so the
layout looks like:

  third_party/obsbot-sdk/
  ├── include/
  ├── macos/
  ├── linux/
  ├── windows/
  └── OBSBOT_Sample/

MSG
  exit 1
fi

echo "OBSBOT SDK found at $SDK"
