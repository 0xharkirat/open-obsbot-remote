#!/usr/bin/env bash
# Build and package the macOS release ZIP.
#
# The source repo never commits OBSBOT SDK files. The release artifact does
# include the SDK runtime dylib inside the .app bundle:
#   Open OBSBOT Bridge.app/Contents/MacOS/libdev.dylib
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(sed -n 's/^version: *\([^+[:space:]]*\).*/\1/p' apps/bridge/pubspec.yaml | head -1)"
fi
if [[ -z "$VERSION" ]]; then
  echo "Could not determine version. Pass one explicitly, e.g. scripts/package-mac-release.sh 1.0.0" >&2
  exit 1
fi

./scripts/build-bridge-mac.sh

APP="$ROOT/apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
BRIDGE_BIN="$APP/Contents/MacOS/obsbot-bridge"
SDK_DYLIB="$APP/Contents/MacOS/libdev.dylib"
ENTITLEMENTS="$ROOT/apps/bridge/macos/Runner/Release.entitlements"

test -d "$APP" || { echo "Missing app bundle: $APP" >&2; exit 1; }
test -x "$BRIDGE_BIN" || { echo "Missing bundled bridge binary: $BRIDGE_BIN" >&2; exit 1; }
test -f "$SDK_DYLIB" || { echo "Missing bundled SDK dylib: $SDK_DYLIB" >&2; exit 1; }

SIGN_IDENTITY="${SIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application/ { print $2; exit }')"
fi

sign_developer_id() {
  echo "==> Developer ID signing..."
  echo "    $SIGN_IDENTITY"

  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$SDK_DYLIB"

  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$BRIDGE_BIN"

  while IFS= read -r framework; do
    codesign --force --options runtime --timestamp \
      --sign "$SIGN_IDENTITY" \
      "$framework"
  done < <(find "$APP/Contents/Frameworks" -type d -name "*.framework" | sort -r)

  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"
}

if [[ -n "$SIGN_IDENTITY" ]]; then
  sign_developer_id
else
  echo "==> No Developer ID Application identity found; keeping ad-hoc signature."
fi

codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/Open-OBSBOT-Bridge-macOS-arm64-v${VERSION}.zip"
rm -f "$ZIP" "$ZIP.sha256"

NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "NOTARYTOOL_PROFILE is set, but no Developer ID Application identity was found." >&2
    exit 1
  fi

  NOTARY_ZIP="$ROOT/dist/.notary-Open-OBSBOT-Bridge-macOS-arm64-v${VERSION}.zip"
  rm -f "$NOTARY_ZIP"

  echo "==> Submitting for notarization..."
  ditto -c -k --norsrc --keepParent "$APP" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait

  echo "==> Stapling notarization ticket..."
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

echo
echo "Release artifact ready:"
echo "  $ZIP"
echo "  $ZIP.sha256"
echo
echo "Signature type:"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Signature=|TeamIdentifier=' || true
if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
  echo "Notarization: stapled"
else
  echo "Notarization: not requested"
fi
