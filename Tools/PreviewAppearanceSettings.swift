// SPDX-License-Identifier: GPL-3.0-only
import AppKit

@main struct PreviewAppearanceSettings {
    static func main() throws {
        _ = NSApplication.shared
        let suite = "com.leverest.lightroom-photo-info.preview.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppearanceSettings(defaults: defaults)
        settings.setTransparencyPercent(35)
        let controller = AppearanceSettingsWindowController(settings: settings)
        let view = controller.window!.contentView!
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Rendered appearance settings content without presenting a window")
    }
}
