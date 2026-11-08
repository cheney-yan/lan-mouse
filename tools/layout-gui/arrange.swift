import CoreGraphics
import Foundation
// usage: arrange <displayID> <originX> <originY>   (moves one display in the macOS arrangement, persistently)
let a = CommandLine.arguments
guard a.count == 4, let id = UInt32(a[1]), let x = Int32(a[2]), let y = Int32(a[3]) else { print("usage: arrange <displayID> <x> <y>"); exit(2) }
var cfg: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&cfg) == .success else { print("begin failed"); exit(1) }
let r1 = CGConfigureDisplayOrigin(cfg, id, x, y)
let r2 = CGCompleteDisplayConfiguration(cfg, .permanently)
print("origin=\(r1.rawValue) complete=\(r2.rawValue)")
exit(r1 == .success && r2 == .success ? 0 : 1)
