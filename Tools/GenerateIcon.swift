// SPDX-License-Identifier: GPL-3.0-only
import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon() {
    let background = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 196, yRadius: 196)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.06, green: 0.10, blue: 0.15, alpha: 1),
                              ending: NSColor(srgbRed: 0.14, green: 0.26, blue: 0.31, alpha: 1))!
    gradient.draw(in: background, angle: 45)
    NSColor.white.withAlphaComponent(0.13).setStroke()
    background.lineWidth = 3
    background.stroke()

    let mint = NSColor(srgbRed: 0.57, green: 0.89, blue: 0.81, alpha: 1)
    // Original eight-blade geometry. App icons do not embed Apple's SF Symbols artwork.
    let center = NSPoint(x: 502, y: 540)
    func point(_ radius: CGFloat, _ degrees: CGFloat) -> NSPoint {
        let radians = degrees * .pi / 180
        return NSPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
    }
    for blade in 0..<8 {
        let angle = CGFloat(blade) * 45
        let path = NSBezierPath()
        path.move(to: point(119, angle + 31))
        path.line(to: point(284, angle - 7))
        path.appendArc(withCenter: center, radius: 284, startAngle: angle - 7, endAngle: angle + 32, clockwise: false)
        path.line(to: point(119, angle + 75))
        path.close()
        mint.withAlphaComponent(0.79 + Double(blade % 3) * 0.07).setFill()
        path.fill()
    }
    let badgeRect = NSRect(x: 664, y: 126, width: 218, height: 218)
    NSColor(srgbRed: 0.08, green: 0.16, blue: 0.21, alpha: 1).setFill()
    NSBezierPath(ovalIn: badgeRect.insetBy(dx: -12, dy: -12)).fill()
    mint.setFill()
    NSBezierPath(ovalIn: badgeRect).fill()
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 148, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.07, green: 0.16, blue: 0.20, alpha: 1)
    ]
    let text = NSAttributedString(string: "i", attributes: attributes)
    let size = text.size()
    text.draw(at: NSPoint(x: badgeRect.midX - size.width / 2, y: badgeRect.midY - size.height / 2 + 5))
}

for (name, pixels) in [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}
