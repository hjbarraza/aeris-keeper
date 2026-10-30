// Renders the Aeris Keeper app icon: the Keeper glyph (hexagon + keyhole) on a dark macOS squircle.
// Usage: swift Icon/make-icon.swift Icon/AppIcon-1024.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // Body on Apple's grid: 824pt square, centered, continuous corners.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor(white: 0.07, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Subtle top light, like the panel's dark surface catching light.
    NSGradient(starting: NSColor(white: 1, alpha: 0.07), ending: NSColor(white: 1, alpha: 0))!.draw(in: shape, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke()
    shape.lineWidth = 2
    shape.stroke()

    // The glyph: outline hexagon with a solid keyhole, same proportions as the menu bar icon.
    let center = NSPoint(x: 512, y: 512)
    let radius: CGFloat = 245
    let hexagon = NSBezierPath()
    for i in 0..<6 {
        let angle = CGFloat.pi / 2 + CGFloat(i) * .pi / 3
        let point = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        i == 0 ? hexagon.move(to: point) : hexagon.line(to: point)
    }
    hexagon.close()
    hexagon.lineWidth = 44
    hexagon.lineJoinStyle = .round
    NSColor(white: 0.94, alpha: 1).set()
    hexagon.stroke()

    let unit = radius / 7.6 // menu bar glyph units → icon points
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: center.x + (x - 9) * unit, y: center.y + (y - 9) * unit) }
    NSBezierPath(ovalIn: NSRect(origin: p(7.1, 8.6), size: NSSize(width: 3.8 * unit, height: 3.8 * unit))).fill()
    let stem = NSBezierPath()
    stem.move(to: p(8.3, 9.6)); stem.line(to: p(9.7, 9.6)); stem.line(to: p(10.3, 5.4)); stem.line(to: p(7.7, 5.4))
    stem.close()
    stem.fill()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
