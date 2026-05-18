#!/usr/bin/env bash
# Sign + copy the dev-built obsbot-bridge subprocess INTO the Debug
# .app bundle so it inherits the parent's TCC camera grant.
#
# Why this script exists:
#   - macOS TCC only treats child processes as inheriting the parent
#     .app's permissions when the child binary is INSIDE the bundle
#     (Contents/MacOS/). Out-of-bundle subprocesses are standalone -
#     they get their own (invisible, ungrantable) TCC slot. Symptom:
#     System Settings -> Privacy -> Camera shows "Open OBSBOT Bridge"
#     toggled ON but the subprocess still logs
#     "video: camera permission denied".
#   - `flutter run -d macos` builds the Debug .app but our supervisor
#     was launching the subprocess from
#     `apps/bridge_cpp/build/obsbot-bridge` (out of bundle). This
#     script copies the CMake-built binary into the Debug .app's
#     Contents/MacOS/ so the bundled-path candidate in
#     `bridge_supervisor._bridgeBinaryPath` wins.
#   - The subprocess is also re-signed with the stable identifier
#     `com.harksingh.obsbotbridge.dev.helper` (mirrors prod's
#     `.helper` from build-bridge-mac.sh) so TCC + Launch Services
#     don't churn on every rebuild.
#
# Run from repo root after `flutter run` has built (or rebuilt) the
# Debug .app, OR after any CMake rebuild of obsbot-bridge:
#   ./scripts/dev-resign.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BIN="$ROOT/apps/bridge_cpp/build/obsbot-bridge"
LIB="$ROOT/apps/bridge_cpp/build/libdev.dylib"
ENT="$ROOT/apps/bridge/macos/Runner/Release.entitlements"
DEV_APP="$ROOT/apps/bridge/build/macos/Build/Products/Debug/Open OBSBOT Bridge.app"

if [[ ! -x "$BIN" ]]; then
    echo "obsbot-bridge missing at $BIN  -  build it first (CMake build)"
    exit 1
fi

# Always sign the source binary too (useful for the out-of-bundle
# fallback path in case the Debug .app isn't built yet).
echo "==> signing source $BIN"
codesign --force --sign - \
    -i com.harksingh.obsbotbridge.dev.helper \
    --entitlements "$ENT" \
    "$BIN" 2>&1 | tail -2

if [[ -d "$DEV_APP" ]]; then
    echo "==> copying subprocess + libdev into Debug .app bundle"
    cp "$BIN" "$DEV_APP/Contents/MacOS/obsbot-bridge"
    cp "$LIB" "$DEV_APP/Contents/MacOS/libdev.dylib"
    chmod +x "$DEV_APP/Contents/MacOS/obsbot-bridge"

    echo "==> re-signing in-bundle subprocess + libdev"
    codesign --force --sign - \
        -i com.harksingh.obsbotbridge.dev.helper \
        --entitlements "$ENT" \
        "$DEV_APP/Contents/MacOS/obsbot-bridge" 2>&1 | tail -2
    codesign --force --sign - \
        -i com.harksingh.obsbotbridge.dev.libdev \
        "$DEV_APP/Contents/MacOS/libdev.dylib" 2>&1 | tail -2

    echo "==> re-sealing parent bundle"
    codesign --force --sign - \
        --entitlements "$ENT" \
        "$DEV_APP" 2>&1 | tail -2
    codesign --verify --deep --strict "$DEV_APP" 2>&1 | tail -2
else
    echo "Debug .app not built yet at:"
    echo "  $DEV_APP"
    echo "Run \`flutter run -d macos --debug\` once first, then re-run this script."
fi

echo "==> identities:"
codesign -dvv "$BIN" 2>&1 | grep -E "Identifier|Signature"
if [[ -d "$DEV_APP" ]]; then
    codesign -dvv "$DEV_APP/Contents/MacOS/obsbot-bridge" 2>&1 | grep -E "Identifier|Signature"
fi
