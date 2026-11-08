#!/bin/sh
# Build the daemon (no GTK), sign it with a stable local identity and restart the launchd agent.
# Usage: tools/install-macos.sh [codesign-identity-sha1]   (default: contents of ~/.config/lan-mouse/codesign-identity)
set -e
cd "$(dirname "$0")/.."
ID="${1:-$(cat ~/.config/lan-mouse/codesign-identity 2>/dev/null || true)}"
cargo build --release --no-default-features
/bin/cp -f target/release/lan-mouse ~/.local/bin/lan-mouse-region
if [ -n "$ID" ]; then codesign -s "$ID" -f --identifier de.feschber.LanMouse.region ~/.local/bin/lan-mouse-region
else codesign -s - -f --identifier de.feschber.LanMouse.region ~/.local/bin/lan-mouse-region; echo "WARNING: ad-hoc signature, Accessibility grant will be lost"; fi
launchctl kickstart -k "gui/$(id -u)/com.local.lan-mouse" 2>/dev/null || launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.local.lan-mouse.plist
sleep 3; tail -n 6 ~/Library/Logs/lan-mouse.log
