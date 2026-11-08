# Lan Mouse layout GUI (macOS host)

A small local web page to arrange a remote Lan Mouse client *spatially* around
the Mac's displays, including the "dead zone" inside the bounding box of all
displays that upstream Lan Mouse cannot target (see the `macos-regions` branch:
`LAN_MOUSE_REGION_{LEFT,RIGHT,TOP,BOTTOM}` environment variables).

What it does on **Apply**:

1. Moves non-main Mac displays if you dragged them (CoreGraphics
   `CGConfigureDisplayOrigin`, persistent).
2. Derives which Lan Mouse positions touch the remote rectangle
   (`right` = entered from a display on its left, `bottom` = entered from a
   display above it, …).
3. Rewrites the `[[clients]]` entries in `~/.config/lan-mouse/config.toml`
   (one entry per position, same host/ips) and the `LAN_MOUSE_REGION_*`
   variables in the launchd plist, then restarts the daemon.
4. Backs up both files to `~/.local/state/lan-mouse-layout/backup/` first.

The remote's logical resolution is probed over `ssh <hostname>` with
`remote-size.sh` (Hyprland, Sway, niri, X11).

## Run

```sh
./build.sh                       # builds the `displays` and `arrange` helpers (needs Xcode CLT)
LAN_MOUSE_BIN=~/.local/bin/lan-mouse-region PORT=8765 python3 -I server.py
open http://localhost:8765
```

Assumptions: the daemon runs from a launchd agent labelled `com.local.lan-mouse`
whose plist lives at `~/Library/LaunchAgents/com.local.lan-mouse.plist`.

## Known limits

* Regions are absolute display coordinates. Changing the *main* display moves
  the origin, so re-apply from this page afterwards.
* Lan Mouse sends only relative motion: the cursor does not appear at the
  matching point on the remote edge yet (needs a protocol extension).
