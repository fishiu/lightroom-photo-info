// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct AppearanceSettingsTests {
    static func main() {
        let suite = "com.leverest.lightroom-photo-info.tests.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppearanceSettings(defaults: defaults)
        precondition(settings.transparencyPercent == 3)
        precondition(abs(settings.backgroundOpacity - 0.97) < 0.000_001)
        var alphas: [Double] = []
        settings.onChange = { alphas.append($0) }
        settings.setTransparencyPercent(25)
        precondition(settings.transparencyPercent == 25)
        precondition(settings.backgroundOpacity == 0.75)
        precondition(alphas == [0.75])
        precondition(AppearanceSettings(defaults: defaults).transparencyPercent == 25)
        settings.setTransparencyPercent(25)
        precondition(alphas.count == 1, "Unchanged values must not trigger redundant rendering")
        settings.setTransparencyPercent(-5)
        precondition(settings.backgroundOpacity == 1)
        settings.setTransparencyPercent(105)
        precondition(settings.backgroundOpacity == 0)
        settings.setTransparencyPercent(.nan)
        precondition(settings.transparencyPercent == 3)
        settings.setTransparencyPercent(45.8)
        precondition(settings.transparencyPercent == 46)
        settings.restoreDefault()
        precondition(settings.transparencyPercent == 3)
        defaults.set(Double.infinity, forKey: AppearanceSettings.defaultsKey)
        precondition(AppearanceSettings(defaults: defaults).transparencyPercent == 3)
        defaults.set("invalid", forKey: AppearanceSettings.defaultsKey)
        precondition(AppearanceSettings(defaults: defaults).transparencyPercent == 3)
        defaults.set(true, forKey: AppearanceSettings.defaultsKey)
        precondition(AppearanceSettings(defaults: defaults).transparencyPercent == 3)
        print("PASS: transparency direction, default alpha, clamping, persistence and change callbacks")
    }
}
