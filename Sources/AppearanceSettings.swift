// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Percent is transparency: 0 is opaque, 100 is clear. Only the HUD background uses this value.
final class AppearanceSettings {
    static let defaultTransparencyPercent: Double = 3
    static let defaultsKey = "BackgroundTransparencyPercent"
    private let defaults: UserDefaults
    private(set) var transparencyPercent: Double
    /// The callback supplies alpha, ready for the HUD background color (not NSWindow.alphaValue).
    var onChange: ((Double) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedNumber = defaults.object(forKey: Self.defaultsKey) as? NSNumber
        let stored = storedNumber.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0 }
        transparencyPercent = Self.normalized(stored?.doubleValue ?? Self.defaultTransparencyPercent)
    }

    var backgroundOpacity: Double { 1 - transparencyPercent / 100 }

    func setTransparencyPercent(_ value: Double) {
        let next = Self.normalized(value)
        guard next != transparencyPercent else { return }
        transparencyPercent = next
        defaults.set(next, forKey: Self.defaultsKey)
        onChange?(backgroundOpacity)
    }

    func restoreDefault() { setTransparencyPercent(Self.defaultTransparencyPercent) }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTransparencyPercent }
        return min(100, max(0, value)).rounded()
    }
}

/// A standard, focusable settings window; the HUD itself remains nonactivating.
final class AppearanceSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?
    private let settings: AppearanceSettings
    private let slider = NSSlider(value: 3, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let percentage = NSTextField(labelWithString: "3%")
    private var isPresented = false

    init(settings: AppearanceSettings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 196),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "拍摄信息设置"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !window.setFrameUsingName("PhotoInfoAppearanceSettings") { window.center() }
        window.setFrameAutosaveName("PhotoInfoAppearanceSettings")

        let root = NSView()
        window.contentView = root
        root.wantsLayer = true
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        let title = NSTextField(labelWithString: "背景透明度")
        title.font = .systemFont(ofSize: 14, weight: .medium)
        percentage.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        percentage.alignment = .right
        percentage.setAccessibilityLabel("当前背景透明度")
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel("背景透明度")
        slider.toolTip = "0% 不透明，100% 全透明；文字和图标不受影响"
        let opaque = NSTextField(labelWithString: "0% 不透明")
        let clear = NSTextField(labelWithString: "100% 全透明")
        for label in [opaque, clear] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        let note = NSTextField(labelWithString: "只调整背景，文字和图标不会变淡。")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetClicked))
        reset.bezelStyle = .rounded
        for view in [title, percentage, slider, opaque, clear, note, reset] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            percentage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            percentage.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            slider.heightAnchor.constraint(equalToConstant: 24),
            opaque.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            opaque.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 3),
            clear.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            clear.centerYAnchor.constraint(equalTo: opaque.centerYAnchor),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            note.topAnchor.constraint(equalTo: opaque.bottomAnchor, constant: 18),
            reset.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            reset.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showSettings() {
        updateControls()
        if !isPresented {
            isPresented = true
            // Set the preview state before activation makes this accessory app frontmost.
            onVisibilityChange?(true)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard isPresented else { return }
        isPresented = false
        onVisibilityChange?(false)
    }

    private func updateControls() {
        slider.doubleValue = settings.transparencyPercent
        percentage.stringValue = "\(Int(settings.transparencyPercent))%"
    }

    @objc private func sliderChanged() {
        settings.setTransparencyPercent(slider.doubleValue)
        updateControls()
    }

    @objc private func resetClicked() {
        settings.restoreDefault()
        updateControls()
    }
}
