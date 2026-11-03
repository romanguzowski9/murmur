// Draws Murmur's app icon and writes Resources/AppIcon.icns.
// Run from the package directory: swift scripts/make_icon.swift
import AppKit

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: an 824 pt rounded square centred on a 1024 canvas, with a soft drop shadow.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor(red: 0.30, green: 0.18, blue: 0.80, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Violet to coral, top-left to bottom-right, with a gentle glow at the top.
    NSGradient(colors: [NSColor(red: 0.33, green: 0.20, blue: 0.92, alpha: 1),
                        NSColor(red: 0.62, green: 0.28, blue: 0.93, alpha: 1),
                        NSColor(red: 0.98, green: 0.47, blue: 0.55, alpha: 1)],
               atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!.draw(in: shape, angle: -50)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // A spoken waveform: rounded bars, tallest in the middle.
    let heights: [CGFloat] = [120, 230, 360, 470, 330, 200, 290, 150]
    let barWidth = 56 * s, gap = 30 * s
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = tile.midX - total / 2
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(red: 0.20, green: 0.05, blue: 0.45, alpha: 0.35)
    glow.shadowBlurRadius = 18 * s
    glow.shadowOffset = NSSize(width: 0, height: -6 * s)
    glow.set()
    NSColor.white.setFill()
    for h in heights {
        let height = h * s
        NSBezierPath(roundedRect: NSRect(x: x, y: tile.midY - height / 2, width: barWidth, height: height),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(size: CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try! draw(size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
