#!/bin/sh
# Runs ON the remote (Linux) host over ssh; prints "<logical_width> <logical_height>" of its primary output.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# physical size of the first connected DRM output, from EDID (bytes 21/22 = cm)
phys() {
  for e in /sys/class/drm/card*-*/; do
    [ "$(cat "$e/status" 2>/dev/null)" = connected ] || continue
    python3 -c "b=open('$e/edid','rb').read(); print('mm', b[21]*10, b[22]*10)" 2>/dev/null && return 0
  done
  return 0
}
if command -v hyprctl >/dev/null 2>&1 && [ -d "$XDG_RUNTIME_DIR/hypr" ]; then
  export HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)}"
  hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys
ms=json.load(sys.stdin); m=next((m for m in ms if m.get("focused")), ms[0]); print(round(m["width"]/m["scale"]), round(m["height"]/m["scale"]))' && { phys; exit 0; }
fi
if command -v swaymsg >/dev/null 2>&1; then
  export SWAYSOCK="${SWAYSOCK:-$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* 2>/dev/null | head -1)}"
  swaymsg -t get_outputs -r 2>/dev/null | python3 -c 'import json,sys
os_=[o for o in json.load(sys.stdin) if o.get("active")]; o=next((o for o in os_ if o.get("focused")), os_[0]); r=o["rect"]; print(r["width"], r["height"])' && { phys; exit 0; }
fi
if command -v niri >/dev/null 2>&1; then
  niri msg --json outputs 2>/dev/null | python3 -c 'import json,sys
os_=json.load(sys.stdin).values(); o=next(iter(os_)); l=o["logical"]; print(l["width"], l["height"])' && { phys; exit 0; }
fi
if command -v xrandr >/dev/null 2>&1; then
  xrandr --listactivemonitors 2>/dev/null | awk 'NR==2{split($3,a,"/"); split(a[2],b,"x"); sub(/.*x/,"",a[2]); w=a[1]; split($3,c,"x"); split(c[2],d,"/"); print w, d[1]}' && { phys; exit 0; }
fi
echo "unknown" >&2; exit 1
