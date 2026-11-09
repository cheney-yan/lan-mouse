# Lan Mouse HUD for Wayland

Counterpart of `tools/hud` (macOS) for wlr-layer-shell compositors (Hyprland, Sway, ...).
A click-through transparent overlay on every output that listens for the daemon's HUD
datagrams (`LAN_MOUSE_HUD_ADDR`, default `127.0.0.1:4243`, see `src/hud.rs`) and draws a
blue glow on the edge where the cursor entered or left (strongest at the crossing point)
and three rings around the pointer on `locate` (Ctrl+Alt+Super+L, recognised by the daemon).

Requirements (Arch names): `gtk4`, `gtk4-layer-shell`, `python-gobject`, `python-cairo`.

    python3 lan-mouse-hud-wayland.py

Autostart: `lan-mouse-hud.service` (systemd user unit), `systemctl --user enable --now lan-mouse-hud`.
