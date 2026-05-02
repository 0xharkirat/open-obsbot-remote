#!/usr/bin/env bash
# Build the self-contained "Open OBSBOT Bridge.app" macOS bundle.
# Result: apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app
# That .app contains:
#   Contents/MacOS/obsbot_bridge_mac      ← Flutter UI
#   Contents/MacOS/obsbot-bridge          ← C++ WS bridge (libdev consumer)
#   Contents/MacOS/libdev.dylib           ← OBSBOT SDK
#   Contents/Frameworks/FlutterMacOS.framework
#
# End-user just drags the .app to /Applications. First launch prompts for
# camera + local-network access (declared in Info.plist).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 0) sanity: SDK present
./scripts/verify-sdk.sh

# 1) build C++ bridge (uses libdev from third_party/obsbot-sdk/)
echo "==> Building C++ bridge..."
export PATH="/opt/homebrew/bin:$PATH"
cmake -S apps/bridge_cpp -B apps/bridge_cpp/build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build apps/bridge_cpp/build -j

BRIDGE_BIN="$ROOT/apps/bridge_cpp/build/obsbot-bridge"
BRIDGE_LIB="$ROOT/apps/bridge_cpp/build/libdev.dylib"
test -x "$BRIDGE_BIN" || { echo "obsbot-bridge missing"; exit 1; }
test -f "$BRIDGE_LIB" || { echo "libdev.dylib missing"; exit 1; }

# 2a) build Flutter web app (Open OBSBOT Remote) so the bridge can serve it.
echo "==> Building Flutter web app..."
(cd apps/rc && flutter build web --release)
WEB_DIR="$ROOT/apps/rc/build/web"
test -d "$WEB_DIR" || { echo "web build missing at $WEB_DIR"; exit 1; }

# 2b) build Flutter macOS app
echo "==> Building Flutter macOS app..."
cd apps/bridge
flutter build macos --release

APP="$ROOT/apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
if [[ ! -d "$APP" ]]; then
  # Fall back to older naming if a stale build is still around.
  for legacy in \
      "$ROOT/apps/bridge/build/macos/Build/Products/Release/OBSBOT Bridge.app" \
      "$ROOT/apps/bridge/build/macos/Build/Products/Release/obsbot_bridge_mac.app"; do
    if [[ -d "$legacy" ]]; then APP="$legacy"; break; fi
  done
fi
test -d "$APP" || { echo ".app not built (looked for $APP)"; exit 1; }

# 3) copy bridge binary + dylib + web assets into the bundle
echo "==> Bundling bridge binary + libdev + web assets into .app..."
cp "$BRIDGE_BIN" "$APP/Contents/MacOS/obsbot-bridge"
cp "$BRIDGE_LIB" "$APP/Contents/MacOS/libdev.dylib"
chmod +x "$APP/Contents/MacOS/obsbot-bridge"

rm -rf "$APP/Contents/Resources/web"
mkdir -p "$APP/Contents/Resources/web"
cp -R "$WEB_DIR/." "$APP/Contents/Resources/web/"

# 4) ad-hoc sign the whole bundle. Without this, the unsigned subprocess
#    has its own TCC identity and won't inherit camera-access grants
#    from the parent .app — preview silently fails.
echo "==> Ad-hoc signing the bundle..."
codesign --force --deep --sign - \
    --entitlements "$ROOT/apps/bridge/macos/Runner/Release.entitlements" \
    "$APP" 2>&1 | tail -5 || true
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3 || true

# 5) sanity: file sizes
echo
echo "==> Self-contained .app ready:"
echo "    $APP"
du -sh "$APP" 2>/dev/null || true
echo
echo "Drag the .app above to /Applications and double-click to launch."
echo "First launch will prompt for camera + local-network access."
echo
echo "Tip: 'open \"$APP\"' opens it without dragging to /Applications."
