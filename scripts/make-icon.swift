// Renders the app icon into an .iconset folder: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    // macOS icon grid: an 824pt squircle centred on a 1024pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(red: 0.10, green: 0.80, blue: 0.70, alpha: 1),
        NSColor(red: 0.20, green: 0.55, blue: 0.90, alpha: 1),
        NSColor(red: 0.42, green: 0.36, blue: 0.96, alpha: 1),
    ])!.draw(in: tile, angle: -50)
    // Soft highlight across the top.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 520, width: 824, height: 404), angle: -90)

    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 430, weight: .semibold)
            .applying(.init(paletteColors: [.white]))) {
        let size = symbol.size
        let rect = NSRect(x: 512 - size.width / 2, y: 500 - size.height / 2, width: size.width, height: size.height)
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor(red: 0.1, green: 0.1, blue: 0.35, alpha: 0.35)
        glyphShadow.shadowBlurRadius = 18
        glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
        glyphShadow.set()
        symbol.draw(in: rect)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size)@2x.png"))
}
