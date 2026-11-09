#!/bin/sh
# Runs ON a Hyprland/wlroots host. Starts a throwaway receiver (wlroots emulation, dummy capture, port 24243)
# and a throwaway sender (dummy capture -> EdgeFraction 0.25, port 24242), both under a temp HOME so the
# real lan-mouse service is untouched. The sender "enters" the receiver from its RIGHT side at 0.25, so the
# receiver must place the real pointer near the right edge, a quarter of the way down the first output.
# Usage: imac-placement.sh <lan-mouse-binary> [seconds]
set -e
BIN="$1"; SECS="${2:-2}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-$(ls $XDG_RUNTIME_DIR | grep -m1 '^wayland-[0-9]$')}"
export HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-$(ls -t $XDG_RUNTIME_DIR/hypr 2>/dev/null | head -1)}"
T=$(mktemp -d /tmp/lm-place.XXXXXX)
mkdir -p "$T/A/.config/lan-mouse" "$T/B/.config/lan-mouse" "$T/A/run" "$T/B/run"
# each throwaway daemon gets its own XDG_RUNTIME_DIR (the IPC socket lives there, and the real
# service owns the real one); the Wayland socket is passed as an absolute path instead
WL_ABS="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
daemon() { h="$1"; shift; HOME="$T/$h" XDG_CONFIG_HOME="$T/$h/.config" XDG_RUNTIME_DIR="$T/$h/run" WAYLAND_DISPLAY="$WL_ABS" "$BIN" "$@" daemon; }
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/.*=//' | tr 'A-F' 'a-f'; }
for h in A B; do
  printf 'port = %s\n' $([ $h = A ] && echo 24242 || echo 24243) > "$T/$h/.config/lan-mouse/config.toml"
  daemon $h --capture-backend dummy --emulation-backend dummy > "$T/$h/boot.log" 2>&1 & pid=$!; sleep 1.5; kill $pid 2>/dev/null || { echo "daemon $h died at boot:"; cat "$T/$h/boot.log"; exit 1; }; wait $pid 2>/dev/null || true
done
FA=$(fp "$T/A/.config/lan-mouse/lan-mouse.pem"); FB=$(fp "$T/B/.config/lan-mouse/lan-mouse.pem")
cat > "$T/A/.config/lan-mouse/config.toml" <<CFG
port = 24242

[[clients]]
hostname = "b"
ips = ["127.0.0.1"]
port = 24243
position = "left"
activate_on_startup = true

[authorized_fingerprints]
"$FB" = "b"
CFG
printf 'port = 24243\n\n[authorized_fingerprints]\n"%s" = "a"\n' "$FA" > "$T/B/.config/lan-mouse/config.toml"
echo "pointer before: $(hyprctl cursorpos 2>/dev/null)"
hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys
for m in json.load(sys.stdin): print("output %s at (%d,%d) logical %dx%d" % (m["name"], m["x"], m["y"], round(m["width"]/m["scale"]), round(m["height"]/m["scale"])))'
LAN_MOUSE_LOG_LEVEL=info,input_emulation=debug daemon B --capture-backend dummy --emulation-backend wlroots > "$T/B/run.log" 2>&1 & PB=$!
sleep 1
LAN_MOUSE_DUMMY_STILL=1 LAN_MOUSE_LOG_LEVEL=info daemon A --capture-backend dummy --emulation-backend dummy > "$T/A/run.log" 2>&1 & PA=$!
sleep 0.8
echo "pointer ~0.5s after entry: $(hyprctl cursorpos 2>/dev/null)   (expected: right edge minus 0.3%, a quarter down the first output)"
sleep "$SECS"
kill $PA $PB 2>/dev/null; wait $PA $PB 2>/dev/null || true
echo "=== receiver log"; grep -E "wlroots emulation|entered this device|enter_at|emulation backend|WARN|ERROR" "$T/B/run.log" | sed -E 's/^\[([^ ]+) ([A-Z]+) +[a-z_:]+\] /\2 /' | head -n 8
echo "=== sender log"; grep -E "acknowledged|entering client|WARN" "$T/A/run.log" | sed -E 's/^\[([^ ]+) ([A-Z]+) +[a-z_:]+\] /\2 /' | sort | uniq -c | head -n 5
echo "logs: $T"
