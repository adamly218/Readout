// Draws the Readout app icon to icon/icon.png (1024×1024).
// Run from the project folder: swift icon/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(red: 0.13, green: 0.15, blue: 0.21, alpha: 1),
                        NSColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)])!.draw(in: shape, angle: -90)

    // Faint grid lines, like a chart background.
    NSColor(white: 1, alpha: 0.06).setStroke()
    for row in 1...3 {
        let y = tile.minY + 180 + CGFloat(row) * 130
        let line = NSBezierPath()
        line.move(to: NSPoint(x: tile.minX + 120, y: y))
        line.line(to: NSPoint(x: tile.maxX - 120, y: y))
        line.lineWidth = 6
        line.stroke()
    }

    // Three bars in the module colors.
    let bars: [(CGFloat, NSColor)] = [
        (0.42, NSColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1)),
        (0.68, NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)),
        (0.52, NSColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 1)),
    ]
    let barWidth: CGFloat = 120
    for (index, bar) in bars.enumerated() {
        let x = tile.minX + 175 + CGFloat(index) * 175
        let rect = NSRect(x: x, y: tile.minY + 150, width: barWidth, height: 520 * bar.0)
        bar.1.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26).fill()
    }

    // A live line running across the top.
    let points: [CGPoint] = [(0.10, 0.55), (0.28, 0.62), (0.42, 0.50), (0.58, 0.78), (0.72, 0.66), (0.90, 0.86)]
        .map { CGPoint(x: tile.minX + tile.width * $0.0, y: tile.minY + tile.height * $0.1) }
    let line = NSBezierPath()
    line.move(to: points[0])
    points.dropFirst().forEach { line.line(to: $0) }
    line.lineWidth = 34
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    NSColor(red: 0.35, green: 0.95, blue: 0.90, alpha: 1).setStroke()
    line.stroke()

    let dot = points.last!
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: dot.x - 34, y: dot.y - 34, width: 68, height: 68)).fill()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon/icon.png"))
print("Wrote icon/icon.png")
