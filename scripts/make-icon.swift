// Draws Peek's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

func draw(_ px: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let s = px / 1024
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle base with a deep night gradient.
    let inset = 100 * s
    let body = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let base = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.11, blue: 0.20, alpha: 1),
                        NSColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1)])!.draw(in: base, angle: -90)

    // Soft amber glow under the notch.
    ctx.saveGState()
    base.addClip()
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 0.93, green: 0.55, blue: 0.33, alpha: 0.55).cgColor,
                                   NSColor(red: 0.93, green: 0.55, blue: 0.33, alpha: 0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: px / 2, y: body.maxY - 250 * s), startRadius: 0,
                           endCenter: CGPoint(x: px / 2, y: body.maxY - 250 * s), endRadius: 430 * s, options: [])
    ctx.restoreGState()

    // The notch: a black pill hanging from the top edge.
    let notch = NSRect(x: px / 2 - 250 * s, y: body.maxY - 230 * s, width: 500 * s, height: 230 * s)
    let notchPath = NSBezierPath(roundedRect: notch, xRadius: 95 * s, yRadius: 95 * s)
    notchPath.append(NSBezierPath(rect: NSRect(x: notch.minX, y: notch.midY, width: notch.width, height: notch.height / 2)))
    NSColor.black.setFill()
    ctx.saveGState(); base.addClip(); notchPath.fill(); ctx.restoreGState()

    // Live activity inside the notch: amber dot + mint spectrum bars.
    NSColor(red: 0.93, green: 0.55, blue: 0.33, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: notch.minX + 70 * s, y: notch.minY + 70 * s, width: 64 * s, height: 64 * s)).fill()
    NSColor(red: 0.36, green: 0.86, blue: 0.58, alpha: 1).setFill()
    let heights: [CGFloat] = [70, 120, 90, 140]
    for (i, h) in heights.enumerated() {
        let x = notch.maxX - 200 * s + CGFloat(i) * 36 * s
        let r = NSRect(x: x, y: notch.minY + 102 * s - h * s / 2, width: 22 * s, height: h * s)
        NSBezierPath(roundedRect: r, xRadius: 11 * s, yRadius: 11 * s).fill()
    }
    img.unlockFocus()
    return img
}

let fm = FileManager.default
let set = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(data: draw(px).tiffRepresentation!)!
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let big = NSBitmapImageRep(data: draw(512).tiffRepresentation!)!
try! big.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/images/icon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: set)
print("Wrote Resources/AppIcon.icns and docs/images/icon.png")
