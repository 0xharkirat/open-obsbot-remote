#!/usr/bin/env bash
# Re-sign the dev-built obsbot-bridge subprocess with the stable
# debug identifier `com.harksingh.obsbotbridge.dev.helper` so that
# macOS TCC routes its camera-permission grant to the matching dev
# .app bundle id (`com.harksingh.obsbotbridge.dev`).
#
# Why this script exists:
#   - `flutter run -d macos` builds an unsigned Debug .app and our
#     supervisor launches the prebuilt subprocess from
#     `apps/bridge_cpp/build/obsbot-bridge` (which CMake leaves with
#     the linker-default ad-hoc identity `obsbot-bridge`).
#   - That identity drifts every C++ rebuild → macOS TCC treats each
#     drift as a new app, the user has to re-grant camera every
#     time. The prod build script (build-bridge-mac.sh) already pins
#     the subprocess to `com.harksingh.obsbotbridge.helper`  -  this
#     mirrors that for dev with `.dev.helper`.
#
# Run from repo root: ./scripts/dev-resign.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BIN="$ROOT/apps/bridge_cpp/build/obsbot-bridge"
ENT="$ROOT/apps/bridge/macos/Runner/Release.entitlements"

if [[ ! -x "$BIN" ]]; then
    echo "obsbot-bridge missing at $BIN  -  build it first (CMake build)"
    exit 1
fi

codesign --force --sign - \
    -i com.harksingh.obsbotbridge.dev.helper \
    --entitlements "$ENT" \
    "$BIN" 2>&1 | tail -3

echo "==> verified identity:"
codesign -dvv "$BIN" 2>&1 | grep -E "Identifier|Signature"
