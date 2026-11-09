#!/usr/bin/env python3
"""Lan Mouse desktop layout GUI backend (Python 3.9, stdlib only).

Serves index.html and a small JSON API:
  GET  /api/state  -> Mac displays, remote client rectangle, daemon state
  POST /api/apply  -> write region env vars + client entries, optionally move Mac displays, restart daemon
"""
import json, os, re, shutil, subprocess, time
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
CONFIG = os.path.join(HOME, ".config/lan-mouse/config.toml")
PLIST = os.path.join(HOME, "Library/LaunchAgents/com.local.lan-mouse.plist")
LOG = os.path.join(HOME, "Library/Logs/lan-mouse.log")
DAEMON_CLI = os.environ.get("LAN_MOUSE_BIN", os.path.join(HOME, ".local/bin/lan-mouse-region"))
DISPLAYS_TOOL = os.path.join(HERE, "displays")
ARRANGE_TOOL = os.path.join(HERE, "arrange")
REMOTE_SIZE_SCRIPT = os.path.join(HERE, "remote-size.sh")
BACKUP_DIR = os.path.join(HOME, ".local/state/lan-mouse-layout/backup")
LABEL = "com.local.lan-mouse"
POSITIONS = ["left", "right", "top", "bottom"]


def run(cmd, timeout=20):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


def display_names():
    """map (w,h in points) -> product name via system_profiler"""
    names = {}
    try:
        _, out = run(["system_profiler", "SPDisplaysDataType", "-json"], timeout=30)
        data = json.loads(out)
        for gpu in data.get("SPDisplaysDataType", []):
            for d in gpu.get("spdisplays_ndrvs", []):
                res = d.get("_spdisplays_resolution", "")
                m = re.match(r"\s*(\d+)\s*x\s*(\d+)", res)
                if m:
                    names[(int(m.group(1)), int(m.group(2)))] = d.get("_name", "")
    except Exception:
        pass
    return names


def displays():
    code, out = run([DISPLAYS_TOOL])
    names = display_names()
    res = []
    for line in out.splitlines():
        m = re.match(r"id=(\d+) main=(\w+) builtin=\w+ origin=\((-?\d+),(-?\d+)\) size=(\d+)x(\d+)(?: mm=(\d+)x(\d+))?", line)
        if not m:
            continue
        w, h = int(m.group(5)), int(m.group(6))
        mm_w = int(m.group(7)) if m.group(7) else 0
        mm_h = int(m.group(8)) if m.group(8) else 0
        res.append({"id": int(m.group(1)), "main": m.group(2) == "true", "x": int(m.group(3)),
                    "y": int(m.group(4)), "w": w, "h": h, "name": names.get((w, h), ""),
                    "mm_w": mm_w, "mm_h": mm_h,
                    "pts_per_mm": round(w / mm_w, 4) if mm_w else None})
    return res


def read_config():
    text = open(CONFIG).read() if os.path.exists(CONFIG) else ""
    clients, other, cur = [], [], None
    for line in text.splitlines():
        s = line.strip()
        if s == "[[clients]]":
            cur = {"raw": []}
            clients.append(cur)
            continue
        if s.startswith("[") and not s.startswith("[["):
            cur = None
        if cur is not None:
            cur["raw"].append(line)
            m = re.match(r"(\w+)\s*=\s*(.+)", s)
            if m:
                cur[m.group(1)] = m.group(2)
        else:
            other.append(line)
    parsed = []
    for c in clients:
        host = (c.get("hostname") or '""').strip().strip('"')
        ips = re.findall(r'"([^"]+)"', c.get("ips", ""))
        pos = (c.get("position") or '""').strip().strip('"')
        parsed.append({"hostname": host, "ips": ips, "position": pos})
    return parsed, other


def write_config(other_lines, hostname, ips, positions):
    # drop trailing blank lines before [authorized_fingerprints] and rebuild
    head, tail, in_tail = [], [], False
    for line in other_lines:
        if line.strip().startswith("[authorized_fingerprints]"):
            in_tail = True
        (tail if in_tail else head).append(line)
    while head and not head[-1].strip():
        head.pop()
    blocks = []
    for pos in positions:
        blocks.append("\n[[clients]]\nhostname = %s\nips = [%s]\nposition = \"%s\"\nactivate_on_startup = true\n" % (
            json.dumps(hostname), ", ".join(json.dumps(i) for i in ips), pos))
    text = "\n".join(head) + "\n" + "".join(blocks) + ("\n" + "\n".join(tail) if tail else "") + "\n"
    open(CONFIG, "w").write(text)


def read_plist():
    _, out = run(["plutil", "-convert", "json", "-o", "-", PLIST])
    return json.loads(out)


def write_plist(data):
    tmp = PLIST + ".json"
    open(tmp, "w").write(json.dumps(data))
    code, out = run(["plutil", "-convert", "xml1", "-o", PLIST, tmp])
    os.remove(tmp)
    if code != 0:
        raise RuntimeError(out)


def regions_from_plist(pl):
    env = pl.get("EnvironmentVariables", {}) or {}
    regions = {}
    for pos in POSITIONS:
        v = env.get("LAN_MOUSE_REGION_" + pos.upper())
        if v:
            try:
                x, y, w, h = [float(t) for t in v.split(",")]
                regions[pos] = {"x": x, "y": y, "w": w, "h": h}
            except ValueError:
                pass
    return regions


def daemon_state():
    code, out = run(["launchctl", "list"])
    running = any(LABEL in l and not l.startswith("-") for l in out.splitlines())
    _, clients = run([DAEMON_CLI, "cli", "list"])
    _, tail = run(["tail", "-n", "12", LOG])
    return {"running": running, "clients": clients, "log": tail}


_size_cache = {}

OPPOSITE = {"left": "right", "right": "left", "top": "bottom", "bottom": "top"}


def local_ipv4s(remote_ips=()):
    """this Mac's IPv4 addresses the remote should dial: the ones sharing a /24 with the remote first,
    then tailnet (100.64/10). Virtual-switch and bridge addresses are left out."""
    _, out = run(["ifconfig"])
    ips = [i for i in re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out) if not i.startswith("127.") and not i.endswith(".0")]
    nets = {".".join(r.split(".")[:3]) for r in remote_ips}
    same = [i for i in ips if ".".join(i.split(".")[:3]) in nets]
    tail = [i for i in ips if re.match(r"100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.", i)]
    lan = [i for i in ips if i.startswith(("192.168.", "10.")) or re.match(r"172\.(1[6-9]|2\d|3[01])\.", i)]
    return (same or lan) + tail


def remote_apply(hostname, mac_positions, remote_ips=()):
    """Rewrite the remote's lan-mouse config so it has one active client towards this Mac for every
    edge that borders it (the opposite of each position on the Mac side), then restart its receiver."""
    positions = [OPPOSITE[p] for p in mac_positions]
    _, my_name = run(["scutil", "--get", "LocalHostName"])
    my_name = my_name.strip() or "mac"
    script = r"""
import pathlib, re, sys, json, subprocess, time, base64
name, ips, positions = json.loads(base64.b64decode(sys.argv[1]))
p = pathlib.Path.home() / ".config/lan-mouse/config.toml"
s = p.read_text() if p.exists() else "port = 4242\n"
p.with_suffix(".toml.bak-" + time.strftime("%Y%m%d-%H%M%S")).write_text(s)
head = s.split("[[clients]]")[0].rstrip()
tail = s[s.index("[authorized_fingerprints]"):] if "[authorized_fingerprints]" in s else ""
blocks = "".join("\n\n[[clients]]\nhostname = %s\nips = [%s]\nposition = \"%s\"\nactivate_on_startup = true\n"
                 % (json.dumps(name), ", ".join(json.dumps(i) for i in ips), pos) for pos in positions)
p.write_text(head + blocks + ("\n" + tail if tail else "") + "\n")
r = subprocess.run(["systemctl", "--user", "restart", "lan-mouse-receiver"], capture_output=True, text=True)
print("remote config: %s -> %s; restart rc=%d %s" % (name, positions, r.returncode, r.stderr.strip()))
"""
    import base64
    arg = base64.b64encode(json.dumps([my_name, local_ipv4s(remote_ips), positions]).encode()).decode()
    try:
        pr = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", hostname, "python3", "-", arg],
                            input=script, capture_output=True, text=True, timeout=30)
        return (pr.stdout + pr.stderr).strip() or "remote: no output"
    except Exception as e:
        return "remote apply failed: %s" % e


def remote_size(hostname):
    """logical size of the remote's primary output, probed over ssh (cached 60 s)"""
    now = time.time()
    hit = _size_cache.get(hostname)
    if hit and now - hit[0] < 60:
        return hit[1]
    size = None
    try:
        script = open(REMOTE_SIZE_SCRIPT).read()
        p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4", hostname, "sh -s"],
                           input=script, capture_output=True, text=True, timeout=12)
        m = re.match(r"\s*(\d+)\s+(\d+)", p.stdout)
        if m:
            size = {"w": int(m.group(1)), "h": int(m.group(2))}
            mm = re.search(r"^mm\s+(\d+)\s+(\d+)", p.stdout, re.M)
            if mm:
                size["mm_w"], size["mm_h"] = int(mm.group(1)), int(mm.group(2))
    except Exception:
        size = None
    _size_cache[hostname] = (now, size)
    return size


def state():
    clients, _ = read_config()
    pl = read_plist()
    regions = regions_from_plist(pl)
    remote = None
    if clients:
        c0 = clients[0]
        region = next(iter(regions.values()), None)
        remote = {"hostname": c0["hostname"], "ips": c0["ips"],
                  "positions": [c["position"] for c in clients],
                  "region": region,
                  "detected_size": remote_size(c0["hostname"]) if c0["hostname"] else None}
    return {"displays": displays(), "remote": remote, "regions": regions, "daemon": daemon_state()}


def overlap(a0, a1, b0, b1):
    return min(a1, b1) - max(a0, b0)


def positions_for(rect, disps):
    """which Lan Mouse positions (from the Mac's point of view) touch the remote rectangle"""
    pos = set()
    rx, ry, rw, rh = rect["x"], rect["y"], rect["w"], rect["h"]
    for d in disps:
        dx, dy, dw, dh = d["x"], d["y"], d["w"], d["h"]
        if abs(dx + dw - rx) < 0.5 and overlap(dy, dy + dh, ry, ry + rh) > 0:
            pos.add("right")   # display is left of remote -> cursor leaves display to the right
        if abs(rx + rw - dx) < 0.5 and overlap(dy, dy + dh, ry, ry + rh) > 0:
            pos.add("left")
        if abs(dy + dh - ry) < 0.5 and overlap(dx, dx + dw, rx, rx + rw) > 0:
            pos.add("bottom")
        if abs(ry + rh - dy) < 0.5 and overlap(dx, dx + dw, rx, rx + rw) > 0:
            pos.add("top")
    return [p for p in POSITIONS if p in pos]


def apply(body):
    rect = body["remote"]
    for k in ("x", "y", "w", "h"):
        rect[k] = int(round(float(rect[k])))
    moves = body.get("displays", [])
    disps = displays()
    steps = []
    # 1. move Mac displays if requested (main display stays at 0,0)
    for mv in moves:
        d = next((d for d in disps if d["id"] == int(mv["id"])), None)
        if not d or d["main"]:
            continue
        nx, ny = int(round(float(mv["x"]))), int(round(float(mv["y"])))
        if (nx, ny) != (d["x"], d["y"]):
            code, out = run([ARRANGE_TOOL, str(d["id"]), str(nx), str(ny)])
            steps.append("move display %d -> (%d,%d): %s" % (d["id"], nx, ny, out))
            if code != 0:
                return {"ok": False, "steps": steps, "error": "display move failed"}
    if moves:
        time.sleep(1.0)
        disps = displays()
    # 2. validate remote rectangle
    for d in disps:
        if overlap(d["x"], d["x"] + d["w"], rect["x"], rect["x"] + rect["w"]) > 0 and \
           overlap(d["y"], d["y"] + d["h"], rect["y"], rect["y"] + rect["h"]) > 0:
            return {"ok": False, "steps": steps, "error": "远端方块和 Mac 显示器 %s 重叠了" % (d["name"] or d["id"])}
    positions = positions_for(rect, disps)
    if not positions:
        return {"ok": False, "steps": steps, "error": "远端方块没有贴着任何 Mac 显示器的边，鼠标无法穿越"}
    # 3. backups
    os.makedirs(BACKUP_DIR, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(CONFIG, os.path.join(BACKUP_DIR, "config.toml." + ts))
    shutil.copy2(PLIST, os.path.join(BACKUP_DIR, "com.local.lan-mouse.plist." + ts))
    # 4. config.toml client entries
    clients, other = read_config()
    if not clients:
        return {"ok": False, "steps": steps, "error": "config.toml 里没有客户端条目"}
    host, ips = clients[0]["hostname"], clients[0]["ips"]
    write_config(other, host, ips, positions)
    steps.append("config.toml: %s -> positions %s" % (host, positions))
    # 5. plist env vars
    pl = read_plist()
    env = {k: v for k, v in (pl.get("EnvironmentVariables") or {}).items() if not k.startswith("LAN_MOUSE_REGION_")}
    val = "%d,%d,%d,%d" % (rect["x"], rect["y"], rect["w"], rect["h"])
    for p in positions:
        env["LAN_MOUSE_REGION_" + p.upper()] = val
    pl["EnvironmentVariables"] = env
    write_plist(pl)
    steps.append("plist regions: " + val)
    # 6. remote side: one client towards us per bordering edge (opposite positions)
    if body.get("apply_remote", True) and host:
        steps.append(remote_apply(host, positions, ips))
    # 7. restart daemon
    uid = os.getuid()
    run(["launchctl", "bootout", "gui/%d/%s" % (uid, LABEL)])
    time.sleep(0.8)
    code, out = run(["launchctl", "bootstrap", "gui/%d" % uid, PLIST])
    steps.append("daemon restart: " + (out or "ok"))
    time.sleep(3.0)
    return {"ok": True, "steps": steps, "positions": positions, "state": state()}


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/api/state"):
            try:
                self._send(200, state())
            except Exception as e:
                self._send(500, {"error": str(e)})
        elif self.path in ("/", "/index.html"):
            self._send(200, open(os.path.join(HERE, "index.html"), "rb").read(), "text/html")
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/apply":
            return self._send(404, {"error": "not found"})
        n = int(self.headers.get("Content-Length", "0"))
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
            self._send(200, apply(body))
        except Exception as e:
            self._send(500, {"ok": False, "error": str(e)})

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8765"))
    print("Lan Mouse layout GUI on http://127.0.0.1:%d" % port, flush=True)
    HTTPServer(("127.0.0.1", port), H).serve_forever()
