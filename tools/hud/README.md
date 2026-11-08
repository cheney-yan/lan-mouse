# Lan Mouse HUD (macOS)

On-screen feedback for the Lan Mouse daemon:

* a translucent blue bar flashes on the screen edge where the cursor crossed to the remote,
  and a ring pulses where it reappears when it comes back;
* Ctrl+Option+Cmd+L "where is the mouse": pulses around the cursor, or shows where it left to the remote;
* Ctrl+Option+Cmd+K toggle: give the mouse back (lan-mouse cli release) or send it to the remote (cli enter 0).

The daemon sends one JSON datagram per event to LAN_MOUSE_HUD_ADDR (default 127.0.0.1:4243):
{"event":"enter"|"leave","position":"right","x":3007.0,"y":800.0} (macOS global display coordinates).

Build and run (no Accessibility permission needed; hotkeys use Carbon RegisterEventHotKey):

    swiftc -O -framework Cocoa -framework Carbon LanMouseHUD.swift -o lan-mouse-hud
    LAN_MOUSE_HUD_REMOTE_NAME=imac LAN_MOUSE_BIN=~/.local/bin/lan-mouse-region ./lan-mouse-hud
