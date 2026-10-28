// SPDX-License-Identifier: GPL-3.0-only
import AppKit

@main
struct PreviewUI {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let content = InfoPanelContent(frame: NSRect(origin: .zero, size: InfoPanelContent.panelSize))
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = content
        let samples: [(String, PhotoMetadata)] = [
            // Synthetic examples for documentation. Never render someone's real catalog for publication.
            ("gfx", PhotoMetadata(filename: "SAMPLE_0001.RAF", camera: "FUJIFILM GFX100RF", lens: "未记录", focalLength: "35 mm", shutter: "1/900 s", aperture: "f/4", iso: "160", captureDate: "2026-01-15T10:24:18+08:00", assetID: "preview-gfx", focalLengthMM: 35, pixelWidth: 11648, pixelHeight: 8736)),
            ("gr4", PhotoMetadata(filename: "SAMPLE_0002.DNG", camera: "RICOH IMAGING COMPANY, LTD. RICOH GR IV", lens: "GR IV LENS 18.3mm F2.8", focalLength: "18.3 mm", shutter: "1/30 s", aperture: "f/2.8", iso: "500", captureDate: "2026-01-15T10:24:18", assetID: "preview-gr4", focalLengthMM: 18.3, equivalentFocalLengthMM: 28, pixelWidth: 6192, pixelHeight: 4128)),
            ("sony", PhotoMetadata(filename: "SAMPLE_0003.ARW", camera: "SONY ILCE-7CM2", lens: "FE 20-70mm F4 G", focalLength: "62 mm", shutter: "1/1600 s", aperture: "f/4", iso: "100", captureDate: "2026-01-15T10:24:18+08:00", assetID: "preview-sony", focalLengthMM: 62, equivalentFocalLengthMM: 62, pixelWidth: 4672, pixelHeight: 7008)),
            ("long", PhotoMetadata(filename: "SAMPLE_very-long-photograph-filename-000042.RAF", camera: "FUJIFILM X100VI", lens: "未记录", focalLength: "23 mm", shutter: "1/180000 s", aperture: "f/16", iso: "12800", captureDate: "", assetID: "preview-long", focalLengthMM: 23))
        ]
        for (name, sample) in samples {
            content.setExpanded(false)
            content.show(sample)
            content.layoutSubtreeIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fatalError("No bitmap") }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            content.setExpanded(true)
            content.layoutSubtreeIfNeeded()
            let expandedBitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: expandedBitmap)
            try expandedBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + "-expanded.png"))
        }
        content.setExpanded(false)
        content.showStatus("需要辅助功能权限", permissionRequired: true)
        content.layoutSubtreeIfNeeded()
        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("permission.png"))
        print("Rendered native AppKit previews at \(InfoPanelContent.panelSize.width) × \(InfoPanelContent.panelSize.height) pt")
    }
}
