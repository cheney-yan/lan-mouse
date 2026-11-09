#!/bin/sh
# Loopback protocol test: two daemons on this machine with dummy backends.
#   A (sender)   port 14242, dummy capture -> emits EdgeFraction(0.25) + Begin, then motion
#   B (receiver) port 14243, dummy emulation -> logs enter_at edge/fraction
# Usage: run.sh <sender-binary> <receiver-binary> [seconds]
# Pass an older lan-mouse as receiver to check the legacy fallback (Enter without fraction).
set -e
A_BIN="$1"; B_BIN="$2"; SECS="${3:-6}"
[ -x "$A_BIN" ] && [ -x "$B_BIN" ] || { echo "usage: $0 <sender-binary> <receiver-binary> [seconds]"; exit 2; }
T=$(mktemp -d /tmp/lm-loop.XXXXXX)
mkdir -p "$T/A/.config/lan-mouse" "$T/A/Library/Caches" "$T/B/.config/lan-mouse" "$T/B/Library/Caches"
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' | tr 'A-F' 'a-f'; }
# generate certs by starting each daemon once
for h in A B; do
  printf 'port = %s\n' $([ $h = A ] && echo 14242 || echo 14243) > "$T/$h/.config/lan-mouse/config.toml"
  HOME="$T/$h" "$([ $h = A ] && echo "$A_BIN" || echo "$B_BIN")" --capture-backend dummy --emulation-backend dummy daemon > "$T/$h/boot.log" 2>&1 &
  pid=$!; sleep 1.5; kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
done
FA=$(fp "$T/A/.config/lan-mouse/lan-mouse.pem"); FB=$(fp "$T/B/.config/lan-mouse/lan-mouse.pem")
[ -n "$FA" ] && [ -n "$FB" ] || { echo "certificate generation failed"; cat "$T/A/boot.log" "$T/B/boot.log"; exit 1; }
cat > "$T/A/.config/lan-mouse/config.toml" <<CFG
port = 14242

[[clients]]
hostname = "b"
ips = ["127.0.0.1"]
port = 14243
position = "left"
activate_on_startup = true

[authorized_fingerprints]
"$FB" = "b"
CFG
cat > "$T/B/.config/lan-mouse/config.toml" <<CFG
port = 14243

[authorized_fingerprints]
"$FA" = "a"
CFG
HOME="$T/B" LAN_MOUSE_LOG_LEVEL=info "$B_BIN" --capture-backend dummy --emulation-backend dummy daemon > "$T/B/run.log" 2>&1 & PB=$!
sleep 1
HOME="$T/A" LAN_MOUSE_LOG_LEVEL=info "$A_BIN" --capture-backend dummy --emulation-backend dummy daemon > "$T/A/run.log" 2>&1 & PA=$!
sleep "$SECS"
kill $PA $PB 2>/dev/null; wait $PA $PB 2>/dev/null || true
echo "=== A (sender) $A_BIN"; grep -E "entering client|acknowledged|WARN|connected @|EnterAt|Enter\(" "$T/A/run.log" | sed -E 's/^\[([^ ]+) ([A-Z]+) +[a-z_:]+\] /\2 /' | sort | uniq -c | sort -rn | head -8
echo "=== B (receiver) $B_BIN"; grep -E "entered this device|enter_at|received event: \([0-9]+\) (begin|pointer motion)" "$T/B/run.log" | sed -E 's/^\[([^ ]+) ([A-Z]+) +[a-z_:]+\] /\2 /' | sed -E 's/dx=[-0-9.]+ dy=[-0-9.]+/dx=.. dy=../' | sort | uniq -c | sort -rn | head -8
ok=1
grep -q "acknowledged the connection" "$T/A/run.log" || { echo "FAIL: sender never got an Ack"; ok=0; }
grep -q "entered this device" "$T/B/run.log" || { echo "FAIL: receiver never saw Enter"; ok=0; }
if "$B_BIN" --version 2>/dev/null | grep -q "tag:" && grep -q "EnterAt" "$T/B/run.log"; then
  grep -q "enter_at: .* edge=Right fraction=0.250" "$T/B/run.log" || { echo "FAIL: receiver did not place the pointer at edge Right / 0.25"; ok=0; }
fi
[ $ok = 1 ] && echo "PASS ($T)" || { echo "logs in $T"; exit 1; }
