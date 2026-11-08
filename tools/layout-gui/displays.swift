import CoreGraphics
var count: UInt32 = 0
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
CGGetActiveDisplayList(16, &ids, &count)
for i in 0..<Int(count) {
  let d = ids[i]; let b = CGDisplayBounds(d); let mm = CGDisplayScreenSize(d)
  print("id=\(d) main=\(CGDisplayIsMain(d) != 0) builtin=\(CGDisplayIsBuiltin(d) != 0) origin=(\(Int(b.origin.x)),\(Int(b.origin.y))) size=\(Int(b.size.width))x\(Int(b.size.height)) mm=\(Int(mm.width))x\(Int(mm.height))")
}
