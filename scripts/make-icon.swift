// Renders the macOS paper-and-dictation icon into an .icns file.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // macOS icon grid: 80% rounded tile, with a softly lit paper face.
    let tile = NSBezierPath(roundedRect: NSRect(x: s * 0.1, y: s * 0.1,
                                              width: s * 0.8, height: s * 0.8),
                            xRadius: s * 0.18, yRadius: s * 0.18)
    let shadow = NSShadow()
    NSGraphicsContext.saveGraphicsState()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.024
    shadow.set()
    NSColor.systemBlue.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.28, green: 0.62, blue: 0.98, alpha: 1),
               ending: NSColor(calibratedRed: 0.04, green: 0.35, blue: 0.78, alpha: 1))!
        .draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    tile.lineWidth = s * 0.002
    tile.stroke()

    let paper = NSBezierPath(roundedRect: NSRect(x: s * 0.26, y: s * 0.22,
                                               width: s * 0.48, height: s * 0.56),
                             xRadius: s * 0.06, yRadius: s * 0.06)
    NSGraphicsContext.saveGraphicsState()
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.shadowBlurRadius = s * 0.016
    shadow.set()
    NSColor.white.setFill()
    paper.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: .white, ending: NSColor(calibratedWhite: 0.94, alpha: 1))!
        .draw(in: paper, angle: -90)
    NSColor(calibratedRed: 0.12, green: 0.43, blue: 0.82, alpha: 1).setFill()
    for y in [0.632, 0.532] {
        NSBezierPath(roundedRect: NSRect(x: s * 0.346, y: s * y,
                                        width: s * 0.308, height: s * 0.027),
                     xRadius: s * 0.0135, yRadius: s * 0.0135).fill()
    }
    for (index, height) in [0.0625, 0.129, 0.1914, 0.1016].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: s * (0.346 + Double(index) * 0.0801),
                                        y: s * (0.375 - height / 2),
                                        width: s * 0.0352, height: s * height),
                     xRadius: s * 0.0176, yRadius: s * 0.0176).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// ICNS supports PNG payloads directly; writing the container avoids an external encoder.
func bigEndian(_ value: Int) -> Data {
    var number = UInt32(value).bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}

var chunks = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                     ("ic08", 256), ("ic09", 512), ("ic10", 1024),
                     ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)] {
    let png = render(size)
    chunks.append(Data(type.utf8))
    chunks.append(bigEndian(png.count + 8))
    chunks.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndian(chunks.count + 8))
icon.append(chunks)
try icon.write(to: output)
