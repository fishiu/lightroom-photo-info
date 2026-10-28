// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class InfoPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PassiveLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

private final class PassiveImage: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Each equal-width cell centers its natural icon+value group. Only exceptional long values shrink.
private final class ExposureValue: NSView {
    private let value = PassiveLabel(labelWithString: "—")
    private let icon: NSView
    private let name: String
    private let iconWidth: CGFloat

    init(symbol: String?, name: String) {
        self.name = name
        iconWidth = symbol == nil ? 25 : 16
        if let symbol {
            let image = PassiveImage()
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            image.contentTintColor = NSColor.white.withAlphaComponent(0.52)
            icon = image
        } else {
            let badge = NSView()
            badge.wantsLayer = true
            badge.layer?.borderColor = NSColor.white.withAlphaComponent(0.42).cgColor
            badge.layer?.borderWidth = 0.75
            badge.layer?.cornerRadius = 3
            let letters = PassiveLabel(labelWithString: "ISO")
            letters.font = .systemFont(ofSize: 9, weight: .medium)
            letters.textColor = NSColor.white.withAlphaComponent(0.68)
            letters.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(letters)
            NSLayoutConstraint.activate([
                letters.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                letters.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
            ])
            icon = badge
        }
        super.init(frame: .zero)
        value.textColor = NSColor.white.withAlphaComponent(0.94)
        value.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        value.lineBreakMode = .byClipping
        addSubview(icon)
        addSubview(value)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        toolTip = name
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    func set(_ text: String) {
        value.stringValue = text
        value.setAccessibilityLabel(name + " " + text)
        toolTip = name + "：" + text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let available = max(1, bounds.width - iconWidth - 5)
        var fontSize: CGFloat = 18
        var font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        while fontSize > 12 && (value.stringValue as NSString).size(withAttributes: [.font: font]).width + 4 > available {
            fontSize -= 0.25
            font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        }
        value.font = font
        let textSize = (value.stringValue as NSString).size(withAttributes: [.font: font])
        let textWidth = min(available, ceil(textSize.width) + 4)
        let groupWidth = iconWidth + 5 + textWidth
        let start = floor((bounds.width - groupWidth) / 2)
        icon.frame = NSRect(x: start, y: (bounds.height - 16) / 2, width: iconWidth, height: 16)
        value.frame = NSRect(x: start + iconWidth + 5, y: floor((bounds.height - textSize.height) / 2), width: textWidth, height: ceil(textSize.height))
    }
}

final class InfoPanelContent: NSView {
    static let panelSize = NSSize(width: 326, height: 104)
    static let expandedHeight: CGFloat = 168
    static let expansionDuration: TimeInterval = 0.20
    var onOpenAccessibility: (() -> Void)?
    var onExpansionChange: ((CGFloat, Bool) -> Void)?
    private let camera = PassiveLabel(labelWithString: "拍摄信息")
    private let filename = PassiveLabel(labelWithString: "")
    private let lens = PassiveLabel(labelWithString: "等待 Lightroom")
    private let focal = NSButton(title: "", target: nil, action: nil)
    private let more = NSButton()
    private let shutter = ExposureValue(symbol: "timer", name: "快门")
    private let aperture = ExposureValue(symbol: "camera.aperture", name: "光圈")
    private let iso = ExposureValue(symbol: nil, name: "感光度")
    private let permissionButton = NSButton(title: "打开辅助功能设置…", target: nil, action: nil)
    private let details = NSView()
    private let captureTime = PassiveLabel(labelWithString: "未记录")
    private let dimensions = PassiveLabel(labelWithString: "未记录")
    private var photo: PhotoMetadata?
    private var isPending = false
    private var lastStatus: String?
    private var expansionGeneration = 0
    private(set) var isExpanded = false
    private var equivalent = UserDefaults.standard.object(forKey: "ShowEquivalentFocalLength") as? Bool ?? true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.125, blue: 0.135, alpha: 0.97).cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true

        camera.font = .systemFont(ofSize: 14.5, weight: .semibold)
        camera.textColor = NSColor.white.withAlphaComponent(0.95)
        camera.lineBreakMode = .byTruncatingTail
        camera.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        camera.setContentHuggingPriority(.required, for: .horizontal)
        camera.widthAnchor.constraint(lessThanOrEqualToConstant: 145).isActive = true
        filename.font = .systemFont(ofSize: 13.5, weight: .medium)
        filename.textColor = NSColor.white.withAlphaComponent(0.78)
        filename.alignment = .right
        filename.lineBreakMode = .byTruncatingMiddle
        filename.maximumNumberOfLines = 1
        filename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filename.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lens.font = .systemFont(ofSize: 12)
        lens.textColor = NSColor.white.withAlphaComponent(0.57)
        lens.lineBreakMode = .byTruncatingMiddle
        lens.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        focal.isBordered = false
        focal.font = .systemFont(ofSize: 12)
        focal.contentTintColor = NSColor.white.withAlphaComponent(0.68)
        focal.target = self
        focal.action = #selector(toggleFocal)
        focal.setContentCompressionResistancePriority(.required, for: .horizontal)
        focal.setContentHuggingPriority(.required, for: .horizontal)
        focal.setAccessibilityLabel("切换实际与等效焦距")
        more.isBordered = false
        more.imagePosition = .imageOnly
        more.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        more.target = self
        more.action = #selector(toggleDetails)
        more.widthAnchor.constraint(equalToConstant: 18).isActive = true
        more.heightAnchor.constraint(equalToConstant: 20).isActive = true
        updateDisclosure()

        let header = NSStackView(views: [camera, filename, more])
        header.orientation = .horizontal
        header.spacing = 8
        header.distribution = .fill
        let readings = NSStackView(views: [shutter, aperture, iso])
        readings.orientation = .horizontal
        readings.distribution = .fillEqually
        readings.spacing = 7
        let footer = NSStackView(views: [lens, focal])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 8
        permissionButton.bezelStyle = .inline
        permissionButton.attributedTitle = NSAttributedString(string: "打开辅助功能设置…", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ])
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        permissionButton.isHidden = true
        for (view, top, height) in [(header, CGFloat(10), CGFloat(22)), (readings, 38, 28), (footer, 76, 18)] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor, constant: top),
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                view.heightAnchor.constraint(equalToConstant: height)
            ])
        }
        permissionButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(permissionButton)
        NSLayoutConstraint.activate([
            permissionButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            permissionButton.topAnchor.constraint(equalTo: topAnchor, constant: 74)
        ])
        details.translatesAutoresizingMaskIntoConstraints = false
        details.wantsLayer = true
        details.isHidden = true
        details.alphaValue = 0
        addSubview(details)
        NSLayoutConstraint.activate([
            details.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            details.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            details.topAnchor.constraint(equalTo: topAnchor, constant: Self.panelSize.height),
            details.heightAnchor.constraint(equalToConstant: Self.expandedHeight - Self.panelSize.height)
        ])
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        details.addSubview(rule)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: details.topAnchor), rule.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: details.trailingAnchor), rule.heightAnchor.constraint(equalToConstant: 0.5)
        ])
        for (title, field, top) in [("拍摄时间", captureTime, CGFloat(12)), ("原图尺寸", dimensions, CGFloat(35))] {
            let label = PassiveLabel(labelWithString: title)
            label.font = .systemFont(ofSize: 11.5)
            label.textColor = NSColor.white.withAlphaComponent(0.48)
            field.font = .systemFont(ofSize: 11.5)
            field.textColor = NSColor.white.withAlphaComponent(0.78)
            field.alignment = .left
            field.lineBreakMode = .byTruncatingMiddle
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [label, field])
            row.orientation = .horizontal
            row.spacing = 10
            row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false
            details.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: details.topAnchor, constant: top),
                row.leadingAnchor.constraint(equalTo: details.leadingAnchor), row.trailingAnchor.constraint(equalTo: details.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: 17)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    func setBackgroundOpacity(_ opacity: Double) {
        let alpha = min(1, max(0, opacity.isFinite ? opacity : 0.97))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.125, blue: 0.135, alpha: alpha).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.07 * alpha / 0.97).cgColor
        CATransaction.commit()
    }

    func show(_ newPhoto: PhotoMetadata) {
        guard photo != newPhoto || lastStatus != nil || isPending else { return }
        photo = newPhoto
        isPending = false
        lastStatus = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        permissionButton.isHidden = true
        lens.isHidden = false
        focal.isHidden = false
        camera.stringValue = CameraPresentation(photo: newPhoto).cameraName
        camera.toolTip = newPhoto.camera
        filename.stringValue = newPhoto.filename
        filename.toolTip = newPhoto.filename
        lens.stringValue = newPhoto.lens == "未记录" ? "镜头未记录" : newPhoto.lens.replacingOccurrences(of: "GR IV LENS ", with: "")
        lens.toolTip = newPhoto.lens
        shutter.set(newPhoto.shutter)
        aperture.set(newPhoto.aperture)
        iso.set(newPhoto.iso)
        captureTime.stringValue = newPhoto.captureDate == "未记录" || newPhoto.captureDate.isEmpty ? "未记录" : String(newPhoto.captureDate.prefix(19)).replacingOccurrences(of: "T", with: " ")
        captureTime.toolTip = newPhoto.captureDate
        if let width = newPhoto.pixelWidth, let height = newPhoto.pixelHeight {
            dimensions.stringValue = "\(width) × \(height) 像素"
        } else { dimensions.stringValue = "未记录" }
        updateFocal()
        more.isEnabled = true
        CATransaction.commit()
    }

    private func updateFocal() {
        guard let photo else { return }
        let presentation = CameraPresentation(photo: photo)
        focal.title = presentation.focalLengthText(equivalent: equivalent)
        focal.toolTip = presentation.focalLengthTooltip(equivalent: equivalent)
    }

    func showPending(targetFilename: String?) {
        guard let previous = photo else {
            showStatus("正在读取拍摄参数…", filename: targetFilename ?? "")
            return
        }
        if !isPending {
            isPending = true
            // A read gap can also occur without changing photos. Keep the last snapshot explicitly labeled.
            lens.stringValue = "正在读取 · 显示上次读数"
            focal.isHidden = true
        }
        let explanation = "正在读取 \(targetFilename ?? "当前照片")；目前仍显示 \(previous.filename) 的参数。"
        if lens.toolTip != explanation { lens.toolTip = explanation }
    }

    func showStatus(_ message: String, filename name: String = "", permissionRequired: Bool = false) {
        let key = message + "|" + name + "|" + String(permissionRequired)
        guard lastStatus != key else { return }
        lastStatus = key
        photo = nil
        isPending = false
        camera.stringValue = "拍摄信息"
        camera.toolTip = nil
        filename.stringValue = name
        filename.toolTip = name
        shutter.set("—"); aperture.set("—"); iso.set("—")
        lens.stringValue = message
        lens.toolTip = message
        lens.isHidden = permissionRequired
        focal.isHidden = true
        captureTime.stringValue = "—"
        dimensions.stringValue = "—"
        permissionButton.isHidden = !permissionRequired
        more.isEnabled = isExpanded
    }

    @objc private func toggleFocal() {
        equivalent.toggle()
        UserDefaults.standard.set(equivalent, forKey: "ShowEquivalentFocalLength")
        updateFocal()
    }

    @objc private func requestPermission() { onOpenAccessibility?() }
    @objc private func toggleDetails() { setExpanded(!isExpanded, animated: true) }

    func setExpanded(_ expanded: Bool, animated: Bool = false) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        expansionGeneration += 1
        let generation = expansionGeneration
        updateDisclosure()
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if expanded { details.isHidden = false }
        let height = expanded ? Self.expandedHeight : Self.panelSize.height
        if let onExpansionChange { onExpansionChange(height, animate) }
        else if let window { window.setContentSize(NSSize(width: Self.panelSize.width, height: height)) }
        else { setFrameSize(NSSize(width: Self.panelSize.width, height: height)) }
        if animate {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.expansionDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                details.animator().alphaValue = expanded ? 1 : 0
            }, completionHandler: { [weak self] in
                guard let self, self.expansionGeneration == generation else { return }
                self.details.isHidden = !self.isExpanded
            })
        } else {
            details.alphaValue = expanded ? 1 : 0
            details.isHidden = !expanded
        }
    }

    private func updateDisclosure() {
        more.image = NSImage(systemSymbolName: isExpanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        more.toolTip = isExpanded ? "收起拍摄时间与原图尺寸" : "展开拍摄时间与原图尺寸"
        more.setAccessibilityLabel(more.toolTip)
        more.setAccessibilityValue(isExpanded ? "已展开" : "已收起")
    }
}
