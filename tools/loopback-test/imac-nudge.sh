#!/bin/sh
# ON a Hyprland host, with the real lan-mouse receiver STOPPED (it owns the barriers otherwise).
# Throwaway B: layer-shell capture + dummy emulation, one client "left" -> throwaway A (dummy/dummy).
# Park the real pointer on B's left barrier with wlrctl, let B capture and
# then release it via its CLI: after the release the pointer must have moved OFF the edge (x >= 8)
# and B must not log a second capture without pointer movement.
# Usage: imac-nudge.sh <lan-mouse-binary>
set -e
BIN="$1"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-$(ls $XDG_RUNTIME_DIR | grep -m1 '^wayland-[0-9]$')}"
export HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-$(ls -t $XDG_RUNTIME_DIR/hypr 2>/dev/null | head -1)}"
T=$(mktemp -d /tmp/lm-nudge.XXXXXX); mkdir -p "$T/A/.config/lan-mouse" "$T/B/.config/lan-mouse" "$T/A/run" "$T/B/run"
WL_ABS="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
daemon() { h="$1"; shift; HOME="$T/$h" XDG_CONFIG_HOME="$T/$h/.config" XDG_RUNTIME_DIR="$T/$h/run" WAYLAND_DISPLAY="$WL_ABS" "$BIN" "$@"; }
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/.*=//' | tr 'A-F' 'a-f'; }
for h in A B; do
  printf 'port = %s\n' $([ $h = A ] && echo 24242 || echo 24243) > "$T/$h/.config/lan-mouse/config.toml"
  daemon $h --capture-backend dummy --emulation-backend dummy daemon > "$T/$h/boot.log" 2>&1 & pid=$!; sleep 1.5; kill $pid 2>/dev/null || { cat "$T/$h/boot.log"; exit 1; }; wait $pid 2>/dev/null || true
done
FA=$(fp "$T/A/.config/lan-mouse/lan-mouse.pem"); FB=$(fp "$T/B/.config/lan-mouse/lan-mouse.pem")
printf 'port = 24242\n\n[authorized_fingerprints]\n"%s" = "b"\n' "$FB" > "$T/A/.config/lan-mouse/config.toml"
cat > "$T/B/.config/lan-mouse/config.toml" <<CFG
port = 24243

[[clients]]
hostname = "a"
ips = ["127.0.0.1"]
port = 24242
position = "left"
activate_on_startup = true

[authorized_fingerprints]
"$FA" = "a"
CFG
# wlrctl moves the real pointer through wlr-virtual-pointer (relative moves; a huge move clamps at the edge)
park_away() { wlrctl pointer move -9000 0; wlrctl pointer move 400 0; }
park_on_left_edge() { wlrctl pointer move -9000 0; }
park_away
LAN_MOUSE_LOG_LEVEL=info daemon A --capture-backend dummy --emulation-backend dummy daemon > "$T/A/run.log" 2>&1 & PA=$!
sleep 1
LAN_MOUSE_LOG_LEVEL=info daemon B --capture-backend layer-shell --emulation-backend dummy daemon > "$T/B/run.log" 2>&1 & PB=$!
sleep 2
echo "pointer parked away from edge: $(hyprctl cursorpos)"
park_on_left_edge; sleep 1
echo "pointer on left edge:          $(hyprctl cursorpos)   B should have captured"
daemon B cli release >/dev/null 2>&1 || true; sleep 1
echo "after B released:               $(hyprctl cursorpos)   expected x >= 8"
sleep 2
kill $PA $PB 2>/dev/null; wait $PA $PB 2>/dev/null || true
echo "=== B log"; grep -E "begin|entering client|releasing|acknowledged|nudge|virtual-pointer|WARN|ERROR" "$T/B/run.log" | sed -E 's/^\[([^ ]+) ([A-Z]+) +[a-z_:]+\] /\1 \2 /' | tail -n 12
echo "logs: $T"
