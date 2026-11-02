// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ApplicationServices

struct PhotoSelection: Equatable, Codable {
    let filename: String
    let documentPath: String?
    let albumName: String?
    let source: PhotoSource
}

enum PhotoSource: String, Codable { case cloud, local, unknown }

enum SelectionState {
    case permissionRequired
    case notRunning
    /// The application is present, but this AX sample is incomplete. This is not evidence of hiding.
    case temporarilyUnavailable
    case noPhoto
    case selected(PhotoSelection)
}

enum PhotoReadClassification: Equatable {
    case singlePhoto, noPhoto, temporarilyUnavailable

    static func classify(hasMainContent: Bool, readFailed: Bool, gridSelected: Bool,
                         compareSelected: Bool, detailSelected: Bool?, candidateCount: Int,
                         sourceKnown: Bool) -> PhotoReadClassification {
        // A positive mode indicator is evidence; an absent/false detail indicator alone is not.
        if hasMainContent && (gridSelected || compareSelected) { return .noPhoto }
        guard hasMainContent, !readFailed else { return .temporarilyUnavailable }
        if candidateCount > 1 { return .noPhoto }
        guard candidateCount == 1, detailSelected != false, sourceKnown else { return .temporarilyUnavailable }
        return .singlePhoto
    }
}

struct LightroomSnapshot {
    let state: SelectionState
    /// Accessibility coordinates: origin at the top-left of the primary display.
    let windowFrame: CGRect?
}

final class LightroomSelectionReader {
    static let bundleID = "com.adobe.lightroomCC"
    private var readFailed = false

    private func readAttribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        // Unsupported optional attributes and leaf children are normal. Transport/lifetime errors
        // mean the UI may be in the middle of replacing its accessibility nodes.
        switch result {
        case .cannotComplete, .invalidUIElement, .failure, .apiDisabled:
            readFailed = true
        default: break
        }
        return (result, value)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let (result, value) = readAttribute(element, name)
        return result == .success ? value : nil
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func photoSource(_ application: AXUIElement) -> PhotoSource {
        guard let value = attribute(application, kAXMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unknown }
        let bar = unsafeBitCast(value, to: AXUIElement.self)
        let items = attribute(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []
        guard let file = items.first(where: { ["文件", "File", "檔案"].contains(string($0, kAXTitleAttribute) ?? "") }) else { return .unknown }
        let menus = attribute(file, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for menu in menus {
            let entries = attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for entry in entries {
                let title = string(entry, kAXTitleAttribute) ?? ""
                let selected = !(string(entry, "AXMenuItemMarkChar") ?? "").isEmpty || string(entry, kAXValueAttribute) == "On"
                if selected && ["云端", "Cloud", "雲端"].contains(title) { return .cloud }
                if selected && ["本地", "Local", "本機"].contains(title) { return .local }
            }
        }
        return .unknown
    }

    func read() -> SelectionState { readSnapshot().state }

    private enum WindowGeometry {
        case visible(CGRect), minimized, temporarilyUnavailable
    }

    private func windowGeometry(_ window: AXUIElement) -> WindowGeometry {
        if (attribute(window, kAXMinimizedAttribute) as? NSNumber)?.boolValue == true { return .minimized }
        guard let position = attribute(window, kAXPositionAttribute),
              let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return .temporarilyUnavailable }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return .temporarilyUnavailable }
        return .visible(CGRect(origin: point, size: dimensions))
    }

    func readSnapshot() -> LightroomSnapshot {
        readFailed = false
        guard AXIsProcessTrusted() else { return LightroomSnapshot(state: .permissionRequired, windowFrame: nil) }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first,
              !app.isTerminated else {
            return LightroomSnapshot(state: .notRunning, windowFrame: nil)
        }
        guard !app.isHidden else { return LightroomSnapshot(state: .noPhoto, windowFrame: nil) }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let source = photoSource(application)
        let windowListRead = readAttribute(application, kAXWindowsAttribute)
        let windowList = windowListRead.1 as? [AXUIElement]
        var windows = windowList ?? []
        var noMainOrFocused = true
        // Lightroom 9.6 can expose an empty AXWindows array while AXMainWindow is valid.
        for key in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            let (result, value) = readAttribute(application, key)
            if let value, result == .success, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(value, to: AXUIElement.self)
                if !windows.contains(where: { CFEqual($0, window) }) { windows.insert(window, at: 0) }
                noMainOrFocused = false
            } else if !(result == .noValue || (result == .success && value == nil)) {
                noMainOrFocused = false
            }
        }
        if windows.isEmpty {
            let definitelyEmpty = windowListRead.0 == .success && windowList?.isEmpty == true && noMainOrFocused && !readFailed
            return LightroomSnapshot(state: definitelyEmpty ? .noPhoto : .temporarilyUnavailable, windowFrame: nil)
        }

        // Distinguish a live window with a transiently missing photo from a minimized/closed window.
        var visibleMainFrame: CGRect?
        var minimizedCount = 0
        // The main editor owns center_content_view. Ignore the secondary display.
        for window in windows {
            let frame: CGRect
            switch windowGeometry(window) {
            case .visible(let value): frame = value
            case .minimized: minimizedCount += 1; continue
            case .temporarilyUnavailable: continue
            }
            var queue = [window]
            var index = 0
            var candidates: [String] = []
            var hasMainContent = false
            var albumName: String?
            var gridSelected = false
            var compareSelected = false
            var detailSelected: Bool?
            while index < queue.count && index < 1500 {
                let element = queue[index]
                index += 1
                let identifier = string(element, kAXIdentifierAttribute) ?? ""
                if identifier == "center_content_view" { hasMainContent = true }
                if ["OrganizeToolbarFlowButton", "OrganizeToolbarGridButton", "OrganizeToolbarCompareButton", "OrganizeToolbarLoupeButton"].contains(identifier),
                   let value = attribute(element, kAXValueAttribute) as? NSNumber {
                    switch identifier {
                    case "OrganizeToolbarFlowButton", "OrganizeToolbarGridButton": gridSelected = gridSelected || value.boolValue
                    case "OrganizeToolbarCompareButton": compareSelected = value.boolValue
                    case "OrganizeToolbarLoupeButton": detailSelected = value.boolValue
                    default: break
                    }
                }
                if string(element, kAXRoleAttribute) == kAXButtonRole {
                    let label = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
                    for prefix in ["搜索 ", "Search "] where label.hasPrefix(prefix) {
                        albumName = String(label.dropFirst(prefix.count))
                    }
                }
                if identifier == "loupeView" {
                    for attr in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
                        if let value = string(element, attr), !value.isEmpty {
                            candidates.append(value)
                            break
                        }
                    }
                }
                if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                    queue.append(contentsOf: children)
                }
            }
            let unique = Set(candidates)
            if hasMainContent { visibleMainFrame = frame }
            let classification = PhotoReadClassification.classify(hasMainContent: hasMainContent,
                readFailed: readFailed || index < queue.count, gridSelected: gridSelected,
                compareSelected: compareSelected, detailSelected: detailSelected,
                candidateCount: unique.count, sourceKnown: source != .unknown)
            if classification == .noPhoto { return LightroomSnapshot(state: .noPhoto, windowFrame: frame) }
            if classification == .singlePhoto, let filename = unique.first {
                let document = string(window, kAXDocumentAttribute)
                let path = document.flatMap { URL(string: $0) }.flatMap { $0.isFileURL ? $0.path : nil }
                return LightroomSnapshot(state: .selected(PhotoSelection(filename: filename, documentPath: path, albumName: albumName, source: source)), windowFrame: frame)
            }
        }
        if minimizedCount == windows.count { return LightroomSnapshot(state: .noPhoto, windowFrame: nil) }
        return LightroomSnapshot(state: .temporarilyUnavailable, windowFrame: visibleMainFrame)
    }
}
