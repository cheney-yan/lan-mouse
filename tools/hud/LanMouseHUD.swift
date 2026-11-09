// Lan Mouse HUD — on-screen feedback for Lan Mouse on macOS.
//  * flashes a translucent blue bar on the edge where the cursor crossed to / returned from a remote
//  * ⌃⌥⌘L  "where is the mouse": pulses around the cursor, or shows where it left to the remote
//  * ⌃⌥⌘K  toggle: give the mouse back (release) or send it to the remote (enter client 0)
// Listens on UDP 127.0.0.1:4243 (LAN_MOUSE_HUD_ADDR of the daemon). No Accessibility permission needed.
import Cocoa
import Carbon.HIToolbox

let remoteName = ProcessInfo.processInfo.environment["LAN_MOUSE_HUD_REMOTE_NAME"] ?? "imac"
let lanMouseBin = ProcessInfo.processInfo.environment["LAN_MOUSE_BIN"] ?? (NSHomeDirectory() + "/.local/bin/lan-mouse-region")
let udpPort: UInt16 = UInt16(ProcessInfo.processInfo.environment["LAN_MOUSE_HUD_PORT"] ?? "4243") ?? 4243
let accent = NSColor.systemBlue

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView?.wantsLayer = true
        orderFrontRegardless()
    }
    override var canBecomeKey: Bool { false }
}

final class HUD {
    var windows: [OverlayWindow] = []
    var captured = false
    var lastPoint: CGPoint? = nil        // CG coordinates (top-left origin)
    var lastPosition = "right"

    init() {
        rebuildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuildWindows() }
    }
    func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { OverlayWindow(screen: $0) }
    }
    // CG (top-left of main display, y down) -> AppKit global (bottom-left of main display, y up)
    func appKit(_ p: CGPoint) -> NSPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSPoint(x: p.x, y: h - p.y)
    }
    func window(at p: NSPoint) -> (OverlayWindow, NSPoint)? {
        // nearest window if the point sits exactly on an edge
        var best: (OverlayWindow, CGFloat)? = nil
        for w in windows {
            let f = w.frame
            let dx = max(f.minX - p.x, 0, p.x - f.maxX), dy = max(f.minY - p.y, 0, p.y - f.maxY)
            let d = dx * dx + dy * dy
            if best == nil || d < best!.1 { best = (w, d) }
        }
        guard let (w, _) = best else { return nil }
        let local = NSPoint(x: min(max(p.x - w.frame.minX, 0), w.frame.width), y: min(max(p.y - w.frame.minY, 0), w.frame.height))
        return (w, local)
    }

    // ---- drawing primitives
    func addTemp(_ layer: CALayer, to w: OverlayWindow, for seconds: Double) {
        w.contentView!.layer!.addSublayer(layer)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { layer.removeFromSuperlayer() }
    }
    func fade(_ layer: CALayer, from: Float = 1, to: Float = 0, duration: Double, delay: Double = 0) {
        let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = from; a.toValue = to
        a.duration = duration; a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .both; a.isRemovedOnCompletion = false
        layer.add(a, forKey: "fade")
    }
    /// soft glow on the screen edge: widest and strongest at the crossing point, fading out along the edge
    func edgeBar(at cg: CGPoint, position: String, seconds: Double = 0.9, strength: CGFloat = 1.0) {
        let p = appKit(cg); guard let (w, local) = window(at: p) else { return }
        let vertical = position == "left" || position == "right"
        let along: CGFloat = 1100 * strength, inward: CGFloat = 170 * strength
        let g = CAGradientLayer()
        g.type = .radial
        g.colors = [accent.withAlphaComponent(0.85).cgColor, accent.withAlphaComponent(0.45).cgColor,
                    accent.withAlphaComponent(0.12).cgColor, accent.withAlphaComponent(0).cgColor]
        g.locations = [0, 0.18, 0.55, 1]
        // ellipse centred ON the edge, so only the inner half is visible: thick at the point, thin further away
        let size = vertical ? CGSize(width: inward * 2, height: along) : CGSize(width: along, height: inward * 2)
        var center = local
        switch position {
        case "right": center.x = w.frame.width
        case "left": center.x = 0
        case "bottom": center.y = 0
        case "top": center.y = w.frame.height
        default: break
        }
        g.frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 1)
        addTemp(g, to: w, for: seconds)
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.6; grow.toValue = 1.0
        grow.duration = seconds * 0.35; grow.fillMode = .both; grow.isRemovedOnCompletion = false
        g.add(grow, forKey: "grow")
        fade(g, from: 1, to: 0, duration: seconds * 0.6, delay: seconds * 0.4)
    }
    func ring(at cg: CGPoint, radius: CGFloat, seconds: Double, delay: Double = 0) {
        let p = appKit(cg); guard let (w, local) = window(at: p) else { return }
        let l = CAShapeLayer()
        l.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        l.position = local
        l.fillColor = accent.withAlphaComponent(0.18).cgColor
        l.strokeColor = accent.withAlphaComponent(0.9).cgColor; l.lineWidth = 4
        addTemp(l, to: w, for: seconds + delay)
        let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = 0.3; s.toValue = 1.0
        s.duration = seconds; s.beginTime = CACurrentMediaTime() + delay; s.fillMode = .both; s.isRemovedOnCompletion = false
        l.add(s, forKey: "grow")
        fade(l, from: 1, to: 0, duration: seconds, delay: delay)
    }
    func label(_ text: String, at cg: CGPoint, seconds: Double) {
        let p = appKit(cg); guard let (w, local) = window(at: p) else { return }
        let t = CATextLayer()
        t.string = text; t.fontSize = 22; t.font = NSFont.boldSystemFont(ofSize: 22)
        t.foregroundColor = NSColor.white.cgColor; t.alignmentMode = .center
        t.contentsScale = w.backingScaleFactor
        let size = CGSize(width: 360, height: 44)
        var origin = CGPoint(x: local.x - size.width / 2, y: local.y - size.height / 2 + 70)
        origin.x = min(max(origin.x, 12), w.frame.width - size.width - 12)
        origin.y = min(max(origin.y, 12), w.frame.height - size.height - 12)
        t.frame = CGRect(origin: origin, size: size)
        t.backgroundColor = accent.withAlphaComponent(0.85).cgColor; t.cornerRadius = 12
        addTemp(t, to: w, for: seconds)
        fade(t, from: 1, to: 0, duration: 0.4, delay: seconds - 0.4)
    }

    // ---- events from the daemon
    func handle(event: [String: Any]) {
        guard let kind = event["event"] as? String else { return }
        let x = event["x"] as? Double ?? .nan, y = event["y"] as? Double ?? .nan
        let pos = event["position"] as? String ?? "right"
        let pt = (x.isNaN || y.isNaN) ? nil : CGPoint(x: x, y: y)
        DispatchQueue.main.async {
            switch kind {
            case "enter":
                self.captured = true; self.lastPosition = pos; if let pt = pt { self.lastPoint = pt; self.edgeBar(at: pt, position: pos) }
            case "leave":
                self.captured = false; if let pt = pt { self.lastPoint = pt; self.edgeBar(at: pt, position: pos, seconds: 0.7, strength: 0.7) }
            case "locate":
                self.locate()
            default: break
            }
        }
    }

    // ---- hotkeys
    func locate() {
        if captured, let pt = lastPoint {
            edgeBar(at: pt, position: lastPosition, seconds: 1.6)
            let arrow = ["right": "→", "left": "←", "top": "↑", "bottom": "↓"][lastPosition] ?? "→"
            label("鼠标在 \(remoteName) \(arrow)", at: pt, seconds: 1.6)
        } else {
            let m = NSEvent.mouseLocation
            let h = NSScreen.screens.first?.frame.height ?? 0
            let cg = CGPoint(x: m.x, y: h - m.y)
            for i in 0..<3 { ring(at: cg, radius: 90, seconds: 0.8, delay: Double(i) * 0.22) }
        }
    }
    func toggle() {
        let args = captured ? ["cli", "release"] : ["cli", "enter", "0"]
        let p = Process(); p.executableURL = URL(fileURLWithPath: lanMouseBin); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.standardError
        do { try p.run() } catch { log("cannot run \(lanMouseBin): \(error)") }
        if !captured { label("→ \(remoteName)", at: { let m = NSEvent.mouseLocation; let h = NSScreen.screens.first?.frame.height ?? 0; return CGPoint(x: m.x, y: h - m.y) }(), seconds: 1.0) }
    }
}

// ---- UDP listener
final class UDPListener {
    let fd: Int32; var source: DispatchSourceRead?
    init(port: UInt16, onMessage: @escaping (Data) -> Void) {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r != 0 { log("bind 127.0.0.1:\(port) failed: \(String(cString: strerror(errno)))"); exit(1) }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source?.setEventHandler { [fd] in
            var buf = [UInt8](repeating: 0, count: 2048)
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 { onMessage(Data(buf[0..<n])) }
        }
        source?.resume()
    }
}

// ---- Carbon global hotkeys (no Accessibility needed)
var hotkeyHandlers: [UInt32: () -> Void] = [:]
func registerHotkey(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
    hotkeyHandlers[id] = handler
    var hk = EventHotKeyID(signature: OSType(0x4C4D4844 /* LMHD */), id: id)
    var ref: EventHotKeyRef? = nil
    let st = RegisterEventHotKey(keyCode, modifiers, hk, GetApplicationEventTarget(), 0, &ref)
    if st != noErr { log("RegisterEventHotKey \(id) failed: \(st)") } else { log("hotkey \(id) registered (keyCode \(keyCode))") }
    _ = hk
}
func installHotkeyHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        log("hotkey \(hk.id) fired")
        DispatchQueue.main.async { hotkeyHandlers[hk.id]?() }
        return noErr
    }, 1, &spec, nil, nil)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var hud: HUD!; var udp: UDPListener!
    func applicationDidFinishLaunching(_ n: Notification) {
        hud = HUD()
        udp = UDPListener(port: udpPort) { [weak self] data in
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self?.hud.handle(event: obj)
        }
        installHotkeyHandler()
        let mods = UInt32(controlKey | optionKey | cmdKey)
        registerHotkey(id: 1, keyCode: UInt32(kVK_ANSI_L), modifiers: mods) { [weak self] in self?.hud.locate() }
        registerHotkey(id: 2, keyCode: UInt32(kVK_ANSI_K), modifiers: mods) { [weak self] in self?.hud.toggle() }
        log("lan-mouse-hud ready: udp 127.0.0.1:\(udpPort), hotkeys ⌃⌥⌘L (locate) ⌃⌥⌘K (toggle), remote=\(remoteName)")
    }
}

let app = NSApplication.shared
// .accessory (no Dock icon, no menu bar) rather than .prohibited: Carbon global hotkeys are only
// delivered to processes the window server treats as applications
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
