import Cocoa

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// 圆角底板（macOS 图标规范：内容缩进约 10%）
let inset = size * 0.09
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.20, yRadius: size * 0.20)

let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1),
    NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1),
])!
grad.draw(in: path, angle: -90)

// 顶部细高光，别让它太扁
let hl = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.maxY - size * 0.28,
                                          width: rect.width, height: size * 0.26),
                      xRadius: size * 0.20, yRadius: size * 0.20)
// 高光必须裁在底板里，否则圆角外侧会露出白弧
NSGraphicsContext.saveGraphicsState()
path.addClip()
NSColor.white.withAlphaComponent(0.045).setFill()
hl.fill()
NSGraphicsContext.restoreGraphicsState()

// 中心店铺符号
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
if let sym = NSImage(systemSymbolName: "storefront.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    NSColor(srgbRed: 0.93, green: 0.33, blue: 0.31, alpha: 1).set()
    let r = NSRect(origin: .zero, size: sym.size)
    sym.draw(in: r)
    r.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let s = tinted.size
    let scale = min((size * 0.52) / s.width, (size * 0.52) / s.height)
    let w = s.width * scale, h = s.height * scale
    tinted.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2 + size * 0.02, width: w, height: h))
}

img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")
