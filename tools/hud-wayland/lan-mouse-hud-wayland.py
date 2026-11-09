#!/usr/bin/env python3
"""Lan Mouse HUD for Wayland (wlr-layer-shell compositors: Hyprland, Sway, ...).

Click-through transparent overlay on every output. Listens for the daemon's HUD
datagrams (LAN_MOUSE_HUD_ADDR, default 127.0.0.1:4243) and draws:
  * a translucent blue radial glow on the edge where the cursor entered / left,
    strongest at the crossing point and fading along the edge ("enter_remote",
    "leave_local", "return_local" with position + fraction);
  * three expanding rings around the pointer on "locate".
Pointer position for "locate" comes from `hyprctl cursorpos` (Hyprland) or
`swaymsg` (Sway); without either, the rings are drawn at the output centre.
"""
import json, os, socket, subprocess, threading, time
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gtk, Gdk, GLib, Gtk4LayerShell as LayerShell  # noqa: E402
import cairo  # noqa: E402

PORT = int(os.environ.get("LAN_MOUSE_HUD_PORT", "4243"))
ACCENT = (0.20, 0.47, 0.96)  # systemBlue-ish, same as the macOS HUD
EDGE_SECONDS = 0.9
LOCATE_SECONDS = 1.1


class Effect:
    def __init__(self, kind, seconds, **kw):
        self.kind, self.seconds, self.t0 = kind, seconds, time.monotonic()
        self.__dict__.update(kw)

    def progress(self):
        return (time.monotonic() - self.t0) / self.seconds


class Overlay(Gtk.Window):
    def __init__(self, app, monitor):
        super().__init__(application=app)
        self.monitor = monitor
        self.effects = []
        # no client-side decorations: a (transparent) header bar would push the
        # drawing area down and shift every top-edge effect
        self.set_decorated(False)
        LayerShell.init_for_window(self)
        LayerShell.set_layer(self, LayerShell.Layer.OVERLAY)
        LayerShell.set_monitor(self, monitor)
        for edge in (LayerShell.Edge.TOP, LayerShell.Edge.BOTTOM, LayerShell.Edge.LEFT, LayerShell.Edge.RIGHT):
            LayerShell.set_anchor(self, edge, True)
        LayerShell.set_exclusive_zone(self, -1)
        LayerShell.set_keyboard_mode(self, LayerShell.KeyboardMode.NONE)
        LayerShell.set_namespace(self, "lan-mouse-hud")
        self.area = Gtk.DrawingArea()
        self.area.set_draw_func(self.draw)
        self.set_child(self.area)
        css = Gtk.CssProvider()
        css.load_from_data(b"window { background: transparent; }")
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.connect("realize", self.on_realize)
        self.present()

    def on_realize(self, *_):
        # empty input region: every click goes through to whatever is below
        surface = self.get_surface()
        if surface is not None:
            surface.set_input_region(cairo.Region())

    def size(self):
        g = self.monitor.get_geometry()  # logical, layout coords
        return g.x, g.y, g.width, g.height

    def add(self, effect):
        self.effects.append(effect)
        if len(self.effects) == 1:
            GLib.timeout_add(16, self.tick)

    def tick(self):
        self.effects = [e for e in self.effects if e.progress() < 1.0]
        self.area.queue_draw()
        return bool(self.effects)

    def draw(self, _area, cr, w, h):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        for e in self.effects:
            p = e.progress()
            if e.kind == "edge":
                self.draw_edge(cr, w, h, e, p)
            elif e.kind == "ring":
                self.draw_ring(cr, e, p)

    def draw_edge(self, cr, w, h, e, p):
        # centre on the edge; half-ellipse visible, widest/strongest at the crossing point
        f = e.fraction if e.fraction is not None else 0.5
        along, inward = 1100 * e.strength, 170 * e.strength
        if e.position in ("left", "right"):
            cx = 0 if e.position == "left" else w
            cy = f * h
            rx, ry = inward, along / 2
        else:
            cx = f * w
            cy = 0 if e.position == "top" else h
            rx, ry = along / 2, inward
        scale = 0.6 + 0.4 * min(1.0, p / 0.35)
        alpha = 1.0 if p < 0.4 else max(0.0, 1.0 - (p - 0.4) / 0.6)
        if os.environ.get("LAN_MOUSE_HUD_DEBUG") and not getattr(e, "logged", False):
            e.logged = True
            print(f"edge {e.position} f={f} area={w}x{h} centre=({cx:.0f},{cy:.0f}) r=({rx:.0f},{ry:.0f}) scale={scale:.2f} alpha={alpha:.2f}", flush=True)
        r, g, b = ACCENT
        grad = cairo.RadialGradient(0, 0, 0, 0, 0, 1)
        grad.add_color_stop_rgba(0.00, r, g, b, 0.85 * alpha)
        grad.add_color_stop_rgba(0.18, r, g, b, 0.45 * alpha)
        grad.add_color_stop_rgba(0.55, r, g, b, 0.12 * alpha)
        grad.add_color_stop_rgba(1.00, r, g, b, 0.0)
        cr.save()
        cr.translate(cx, cy)
        cr.scale(rx * scale, ry * scale)
        cr.set_source(grad)
        cr.arc(0, 0, 1, 0, 6.2832)
        cr.fill()
        cr.restore()

    def draw_ring(self, cr, e, p):
        delay = e.delay / LOCATE_SECONDS
        q = (p - delay) / (1 - delay) if p > delay else None
        if q is None or q > 1:
            return
        radius = 90 * (0.3 + 0.7 * q)
        alpha = 1 - q
        r, g, b = ACCENT
        cr.set_source_rgba(r, g, b, 0.18 * alpha)
        cr.arc(e.x, e.y, radius, 0, 6.2832)
        cr.fill()
        cr.set_source_rgba(r, g, b, 0.9 * alpha)
        cr.set_line_width(4)
        cr.arc(e.x, e.y, radius, 0, 6.2832)
        cr.stroke()


class Hud(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="de.feschber.LanMouse.HudWayland")
        self.overlays = []
        self.last_edge = None  # (position, fraction) of where our cursor left

    def do_activate(self):
        display = Gdk.Display.get_default()
        monitors = display.get_monitors()
        for i in range(monitors.get_n_items()):
            self.overlays.append(Overlay(self, monitors.get_item(i)))
        threading.Thread(target=self.listen, daemon=True).start()
        print(f"lan-mouse-hud-wayland ready: udp 127.0.0.1:{PORT}, {len(self.overlays)} output(s)", flush=True)

    def listen(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", PORT))
        while True:
            data, _ = sock.recvfrom(2048)
            try:
                ev = json.loads(data.decode())
            except ValueError:
                continue
            GLib.idle_add(self.handle, ev)

    def handle(self, ev):
        kind = ev.get("event")
        pos, frac = ev.get("position"), ev.get("fraction")
        if kind in ("enter_remote", "return_local") and pos:
            for o in self.overlays:
                o.add(Effect("edge", EDGE_SECONDS, position=pos, fraction=frac, strength=1.0))
        elif kind == "leave_local" and pos:
            self.last_edge = (pos, frac)
            for o in self.overlays:
                o.add(Effect("edge", EDGE_SECONDS * 0.8, position=pos, fraction=frac, strength=0.7))
        elif kind == "locate":
            self.locate()
        return False

    def pointer(self):
        """pointer in layout coordinates, or None"""
        for cmd in (["hyprctl", "cursorpos", "-j"], ["hyprctl", "cursorpos"]):
            try:
                out = subprocess.run(cmd, capture_output=True, text=True, timeout=1).stdout.strip()
                if out.startswith("{"):
                    d = json.loads(out)
                    return float(d["x"]), float(d["y"])
                x, y = out.replace(",", " ").split()[:2]
                return float(x), float(y)
            except Exception:
                continue
        return None

    def locate(self):
        pt = self.pointer()
        for o in self.overlays:
            gx, gy, gw, gh = o.size()
            if pt is None:
                x, y = gw / 2, gh / 2
            else:
                x, y = pt[0] - gx, pt[1] - gy
                if not (0 <= x <= gw and 0 <= y <= gh):
                    continue
            for i in range(3):
                o.add(Effect("ring", LOCATE_SECONDS, x=x, y=y, delay=i * 0.22))


if __name__ == "__main__":
    Hud().run(None)
