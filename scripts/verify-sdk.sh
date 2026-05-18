#!/usr/bin/env bash
# Fail fast if the OBSBOT SDK isn't on the local filesystem.
# The SDK is gitignored  -  every dev keeps their own copy under third_party/obsbot-sdk/.
# Builds (CMake / Flutter macOS) pull libdev from here and bundle it into the resulting .app.
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

The SDK is distributed by OBSBOT directly. Drop your local copy into
third_party/obsbot-sdk/ (gitignored). See docs/GETTING_THE_SDK.md.

MSG
  exit 1
fi

echo "OBSBOT SDK found at $SDK"
