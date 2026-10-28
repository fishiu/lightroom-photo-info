// SPDX-License-Identifier: GPL-3.0-only
import AppKit

@main struct TransientPresentationTests {
    static func text(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { text(in: $0) }
    }
    static func main() {
        _ = NSApplication.shared
        let content = InfoPanelContent(frame: NSRect(origin: .zero, size: InfoPanelContent.panelSize))
        let first = PhotoMetadata(filename: "before.RAF", camera: "GFX100RF", lens: "35 mm", focalLength: "35 mm", shutter: "1/900 s", aperture: "f/4", iso: "160", captureDate: "2026-01-01T12:00:00", assetID: "first")
        let second = PhotoMetadata(filename: "after.RAF", camera: "GFX100RF", lens: "35 mm", focalLength: "35 mm", shutter: "1/400 s", aperture: "f/8", iso: "800", captureDate: "2026-01-02T12:00:00", assetID: "second")
        content.show(first)
        content.showPending(targetFilename: second.filename)
        var shown = text(in: content)
        precondition(shown.contains(first.filename) && shown.contains(first.shutter) && !shown.contains(second.filename))
        precondition(shown.contains(where: { $0.contains("上次读数") }), "Retained values must not masquerade as the new photo")
        content.show(second)
        shown = text(in: content)
        precondition(shown.contains(second.filename) && shown.contains(second.shutter) && !shown.contains(first.filename))
        precondition(!shown.contains(where: { $0.contains("上次读数") }))
        content.setBackgroundOpacity(0.35)
        precondition(abs((content.layer?.backgroundColor?.alpha ?? -1) - 0.35) < 0.0001)
        precondition(content.alphaValue == 1 && content.subviews.allSatisfy { $0.alphaValue == 1 || $0.isHidden })
        content.showStatus("无法确认当前照片", filename: second.filename)
        shown = text(in: content)
        precondition(!shown.contains(second.shutter) && shown.contains(second.filename), "Expired data must be removed together")
        print("PASS: pending presentation retains and labels old snapshot; complete replacement; expired values cleared; background-only alpha")
    }
}
