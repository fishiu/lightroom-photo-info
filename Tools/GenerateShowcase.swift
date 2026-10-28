// SPDX-License-Identifier: GPL-3.0-only
import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let icon = NSImage(contentsOf: destination.appendingPathComponent("icon.png"))!
let panel = NSImage(contentsOf: destination.appendingPathComponent("expanded.png"))!
let mint = NSColor(srgbRed: 0.57, green: 0.89, blue: 0.81, alpha: 1)
let white = NSColor(srgbRed: 0.94, green: 0.96, blue: 0.97, alpha: 1)
let secondary = NSColor(srgbRed: 0.62, green: 0.70, blue: 0.74, alpha: 1)

func render(_ name: String, width: Int, height: Int, portrait: Bool) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(width) / (portrait ? 1080 : 1600)
    context.cgContext.scaleBy(x: scale, y: scale)
    let w = CGFloat(width) / scale
    let h = CGFloat(height) / scale
    func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: x, y: h - top - height, width: width, height: height)
    }
    func text(_ string: String, x: CGFloat, top: CGFloat, size: CGFloat, color: NSColor = white, weight: NSFont.Weight = .regular) {
        let value = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        value.draw(at: NSPoint(x: x, y: h - top - value.size().height))
    }
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.035, green: 0.055, blue: 0.08, alpha: 1),
                              ending: NSColor(srgbRed: 0.09, green: 0.17, blue: 0.19, alpha: 1))!
    gradient.draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)), angle: 28)
    NSColor.white.withAlphaComponent(0.035).setStroke()
    for i in 0..<12 {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: w * 0.54 + CGFloat(i) * 55, y: 0))
        path.line(to: NSPoint(x: w * 0.72 + CGFloat(i) * 55, y: h))
        path.lineWidth = 1
        path.stroke()
    }
    if portrait {
        icon.draw(in: rect(72, 78, 100, 100))
        text("Lightroom Photo Info", x: 188, top: 108, size: 31, weight: .medium)
        text("边修图，", x: 86, top: 254, size: 76, weight: .semibold)
        text("边看拍摄参数。", x: 86, top: 350, size: 76, weight: .semibold)
        text("给 Lightroom 云端版补上一块信息窗", x: 88, top: 470, size: 31, color: secondary)
        let panelRect = rect(86, 590, 908, 468)
        panel.draw(in: panelRect)
        text("自动跟随照片   /   背景透明度可调", x: 88, top: 1120, size: 29, color: mint, weight: .medium)
        text("macOS · Apple Silicon · GPL-3.0 开源", x: 88, top: 1180, size: 25, color: secondary)
        text("github.com/fishiu/lightroom-photo-info", x: 88, top: 1310, size: 24, color: secondary)
    } else {
        icon.draw(in: rect(76, 80, 94, 94))
        text("Lightroom Photo Info", x: 188, top: 108, size: 30, weight: .medium)
        text("边修图，", x: 88, top: 270, size: 65, weight: .semibold)
        text("边看拍摄参数。", x: 88, top: 356, size: 65, weight: .semibold)
        text("Lightroom 云端版的轻量元数据浮窗", x: 91, top: 478, size: 25, color: secondary)
        text("自动跟随  ·  本地只读  ·  原生 macOS", x: 91, top: 547, size: 22, color: mint, weight: .medium)
        panel.draw(in: rect(830, 266, 682, 352))
        text("真实界面 · 演示数据", x: 830, top: 647, size: 19, color: secondary)
        text("by fishiu  /  GPL-3.0", x: 91, top: h - 89, size: 20, color: secondary)
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}

try render("hero.png", width: 1600, height: 900, portrait: false)
try render("social-preview.png", width: 1200, height: 675, portrait: false)
try render("share-cover.png", width: 1080, height: 1440, portrait: true)
