#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

BRIDGE_DIR="apps/bridge_cpp"
BIN="$BRIDGE_DIR/build/obsbot-bridge"

# Sanity-check the SDK is in place before any build attempt.
if [[ ! -f third_party/obsbot-sdk/include/dev/dev.hpp ]]; then
  cat <<'MSG' >&2
ERROR: OBSBOT SDK not found at third_party/obsbot-sdk/

This SDK is distributed by OBSBOT directly and cannot be redistributed.
See docs/GETTING_THE_SDK.md for how to obtain a copy.
MSG
  exit 1
fi

# Build if missing.
if [[ ! -x "$BIN" ]]; then
  echo "Building bridge..."
  export PATH="/opt/homebrew/bin:$PATH"
  cmake -S "$BRIDGE_DIR" -B "$BRIDGE_DIR/build" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$BRIDGE_DIR/build" -j
fi

PORT="${1:-8765}"

# Stop any previous bridge still holding the port.
EXISTING="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
if [[ -n "$EXISTING" ]]; then
  echo "Port $PORT busy (pid $EXISTING). Stopping previous bridge..."
  kill "$EXISTING" 2>/dev/null || true
  sleep 0.4
  kill -9 "$EXISTING" 2>/dev/null || true
  sleep 0.4
fi

echo "Bridge LAN addresses (use these from your phone):"
ifconfig | awk '/inet / && $2 != "127.0.0.1" { printf "  ws://%s:%s/v1\n", $2, "'"$PORT"'" }'
echo
echo "Plug your OBSBOT camera into USB, then leave this terminal open."
echo

cd "$BRIDGE_DIR/build"
exec ./obsbot-bridge "$PORT"
