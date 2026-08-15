#!/usr/bin/env bash
# Build the Flutter web remote and, optionally, deploy it to a Linux bridge.
#
# WHY THIS EXISTS
#
# The Linux bridge serves the remote itself (`--web-root`), so something has to
# put the built web app on that machine. The obvious shortcut is to copy
# `Open OBSBOT Bridge.app/Contents/Resources/web` off a Mac, because those
# assets are already built and are platform-independent.
#
# That shortcut is a trap. Those assets carry the app as it was when that DMG
# was cut, which is not the app the bridge you are running was built from. A
# remote a month older than its bridge connects, authenticates, renders the
# whole control surface, and then sits on "Connecting..." forever with nothing
# in the browser console, because the only thing that fails is decoding the
# state event that carries the device list. No devices means no selected
# camera, which means no preview URL.
#
# So: build the remote from the same checkout as the bridge. Always.
#
# Usage:
#   ./scripts/build-web-remote.sh                 # build only
#   ./scripts/build-web-remote.sh nitro           # build, then deploy over ssh
#   WEB_ROOT=~/obsbot-web ./scripts/build-web-remote.sh nitro
#
# The deploy step writes to a staging directory and swaps it in, so a failed
# transfer leaves the running bridge serving the previous build rather than
# half of the new one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST="${1:-}"
WEB_ROOT="${WEB_ROOT:-\$HOME/obsbot-web}"
SERVICE="${SERVICE:-obsbot-bridge}"

echo "==> building the web remote from $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"
cd apps/rc
flutter build web --release
cd "$ROOT"

OUT="apps/rc/build/web"
echo "==> built $(find "$OUT" -type f | wc -l | tr -d ' ') files"

if [[ -z "$HOST" ]]; then
  echo
  echo "Built at $OUT"
  echo "Deploy with: $0 <ssh-host>"
  exit 0
fi

echo "==> deploying to $HOST:$WEB_ROOT"
# tar over ssh rather than rsync: macOS ships openrsync, which rejects several
# flags GNU rsync accepts, and this needs to work from a stock Mac.
tar -C apps/rc/build -czf - web 2>/dev/null | ssh "$HOST" "
  set -e
  STAGE=\"\$HOME/.obsbot-web-staging\"
  rm -rf \"\$STAGE\" && mkdir -p \"\$STAGE\"
  tar -C \"\$STAGE\" -xzf - 2>/dev/null
  # Swap only once the new tree is fully extracted.
  rm -rf $WEB_ROOT
  mv \"\$STAGE\" $WEB_ROOT
  systemctl --user restart $SERVICE 2>/dev/null || true
  echo \"    deployed; service: \$(systemctl --user is-active $SERVICE 2>/dev/null || echo 'not managed')\"
"

echo
echo "==> verify the remote actually pulls video, not just the page:"
echo "    ssh $HOST 'journalctl --user -u $SERVICE -f' | grep 'mjpeg: client connected'"
echo "    then open the remote in a browser. A line appears only if the app"
echo "    decoded the device list; a stale build never asks for the stream."
