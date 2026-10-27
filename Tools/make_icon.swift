import AppKit

// usage: swift Tools/make_icon.swift <output.iconset>
// Draws the app icon (warm gradient squircle with a white bell) at every size macOS needs.
guard CommandLine.arguments.count > 1 else { print("usage: make_icon.swift <out.iconset>"); exit(2) }
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func png(size: Int) -> Data? {
    let px = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx

    let body = NSRect(x: px * 0.098, y: px * 0.098, width: px * 0.804, height: px * 0.804)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = px * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -px * 0.012)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [NSColor(red: 1.00, green: 0.66, blue: 0.22, alpha: 1), NSColor(red: 1.00, green: 0.27, blue: 0.36, alpha: 1)])
    gradient?.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: body.width * 0.52, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = bell.size
        bell.draw(in: NSRect(x: body.midX - s.width / 2, y: body.midY - s.height / 2, width: s.width, height: s.height))
    }
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                              ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, size) in sizes {
    if let data = png(size: size) {
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
    }
}
print("wrote \(sizes.count) icons to \(outDir)")
