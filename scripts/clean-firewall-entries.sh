#!/usr/bin/env bash
# Remove stale obsbot-bridge entries from the macOS Application Firewall list.
#
# Why this is needed:
#   - The macOS Application Firewall keys allow/deny rules by binary
#     code-signature hash, NOT by bundle id or path.
#   - Every rebuild of `obsbot-bridge` produces a different hash (C++
#     output is not bit-reproducible across compiler runs, even with
#     the same source). Stable codesign identifier
#     (com.harksingh.obsbotbridge.helper) doesn't change this - the
#     firewall doesn't read the identifier, it hashes the binary.
#   - Result: every dev rebuild + every release install stacks a new
#     "obsbot-bridge - Allow incoming connections" row in Firewall ->
#     Options.... Cosmetic mess; doesn't break anything but reads bad.
#
# This script enumerates all "obsbot-bridge" entries via socketfilterfw
# and removes them. Requires sudo.
#
# Run after a bunch of rebuilds, or whenever the Firewall list gets noisy.
#
# Usage:
#   ./scripts/clean-firewall-entries.sh
#
# After running, the next bridge launch (release or dev) will re-prompt
# for the firewall allow, OR macOS will auto-allow if the signature
# matches a previously-allowed entry that we missed.

set -euo pipefail

FW=/usr/libexec/ApplicationFirewall/socketfilterfw

if [[ ! -x "$FW" ]]; then
    echo "socketfilterfw not found at $FW - macOS update may have moved it"
    exit 1
fi

echo "==> Current obsbot-bridge entries:"
sudo "$FW" --listapps 2>/dev/null | grep -B 1 -A 1 -i obsbot || echo "  (none)"

echo
echo "==> Removing every obsbot-bridge entry the firewall knows about..."

# socketfilterfw --listapps prints blocks like:
#     <bundle-id-or-path>
#         ( Allow incoming connections )
# We need the path lines for --remove. Match anything with "obsbot-bridge"
# in the path; ignore OBSBOT_Main / OBSBOT Center / etc.

paths=$(sudo "$FW" --listapps 2>/dev/null \
    | grep -E "obsbot-bridge" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -E "^/" || true)

if [[ -z "$paths" ]]; then
    echo "  (no path-style obsbot-bridge entries found)"
else
    while IFS= read -r p; do
        echo "  - $p"
        sudo "$FW" --remove "$p" 2>&1 | head -1 || true
    done <<<"$paths"
fi

echo
echo "==> After cleanup:"
sudo "$FW" --listapps 2>/dev/null | grep -B 1 -A 1 -i obsbot || echo "  (none)"

echo
echo "Done. Next launch may re-prompt for firewall allow."
