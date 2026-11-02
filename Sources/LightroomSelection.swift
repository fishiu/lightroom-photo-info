// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ApplicationServices

struct PhotoSelection: Equatable, Codable {
    let filename: String
    let documentPath: String?
    let albumName: String?
    let source: PhotoSource
    var albumDocID: Int64? = nil
}

enum AlbumScopeRead: Equatable {
    case unknown
    case scope(name: String?, docID: Int64?)
    case conflicting
}

/// Reads semantic accessibility labels, never free-form search input or sidebar guesses.
/// Lightroom's own Accessibility mode exposes CollectionSource:<localDocId> search tokens.
struct AlbumScopeEvidence {
    private var fieldNames = Set<String>()
    private var buttonNames = Set<String>()
    private var tokenNames = Set<String>()
    private var tokenIDs = Set<Int64>()
    private var observedTokenKeys = Set<String>()
    private var titledTokenKeys = Set<String>()
    private var invalidToken = false

    mutating func observe(role: String, identifier: String, title: String?,
                          description: String? = nil, placeholder: String? = nil) {
        if identifier == "organize_search_field", role == kAXTextFieldRole {
            for label in [title, placeholder].compactMap({ $0 }) {
                if let name = Self.searchScopeName(label) { fieldNames.insert(name) }
            }
            return
        }
        guard role == kAXButtonRole else { return }
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 3, parts[1].hasPrefix("CollectionSource:") {
            observedTokenKeys.insert(String(parts[1]))
        }
        if parts.last == "title", parts.contains(where: { $0.hasPrefix("CollectionSource:") }) {
            guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("CollectionSource:") else {
                invalidToken = true; return
            }
            let rawID = parts[1].dropFirst("CollectionSource:".count)
            guard !rawID.isEmpty, rawID.first != "0", rawID.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let id = Int64(rawID), id > 0 else { invalidToken = true; return }
            tokenIDs.insert(id)
            titledTokenKeys.insert(String(parts[1]))
            if let title {
                for prefix in ["相册: ", "Album: ", "相簿: "] where title.hasPrefix(prefix) {
                    let name = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { tokenNames.insert(name) }
                }
            }
            return
        }
        // Legacy Lightroom layouts expose the scope as a search button instead.
        for label in [title, description].compactMap({ $0 }) {
            if let name = Self.searchScopeName(label) { buttonNames.insert(name) }
        }
    }

    func resolve() -> AlbumScopeRead {
        guard !invalidToken, observedTokenKeys == titledTokenKeys,
              tokenIDs.count <= 1, tokenNames.count <= 1, fieldNames.count <= 1 else {
            return .conflicting
        }
        if let id = tokenIDs.first {
            if let field = fieldNames.first, let token = tokenNames.first, field != token { return .conflicting }
            return .scope(name: tokenNames.first ?? fieldNames.first, docID: id)
        }
        if let name = fieldNames.first { return .scope(name: name, docID: nil) }
        guard buttonNames.count <= 1 else { return .conflicting }
        if let name = buttonNames.first { return .scope(name: name, docID: nil) }
        return .unknown
    }

    private static func searchScopeName(_ label: String) -> String? {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !["搜索照片", "搜尋相片", "Search Photos", "Search your photos", "Search My Photos"].contains(value) else { return nil }
        for prefix in ["搜索 ", "Search ", "搜尋 "] where value.hasPrefix(prefix) {
            let name = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return nil
    }
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
            var queue: [(element: AXUIElement, inToolbar: Bool)] = [(window, false)]
            var index = 0
            var candidates: [String] = []
            var hasMainContent = false
            var albumEvidence = AlbumScopeEvidence()
            var gridSelected = false
            var compareSelected = false
            var detailSelected: Bool?
            while index < queue.count && index < 1500 {
                let entry = queue[index]
                let element = entry.element
                index += 1
                let identifier = string(element, kAXIdentifierAttribute) ?? ""
                let role = string(element, kAXRoleAttribute) ?? ""
                let inToolbar = entry.inToolbar || role == kAXToolbarRole
                // Accessibility mode exposes every album and filmstrip badge. Neither is
                // needed to read the current loupe and toolbar, so avoid their large trees.
                if ["library", "filmstrip_scroll_view", "organize loupe filmstrip", "right_panel_buttons", "filterScrollView"].contains(identifier) { continue }
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
                if inToolbar && (role == kAXButtonRole || identifier == "organize_search_field") {
                    albumEvidence.observe(role: role, identifier: identifier,
                        title: string(element, kAXTitleAttribute), description: string(element, kAXDescriptionAttribute),
                        placeholder: identifier == "organize_search_field" ? string(element, "AXPlaceholderValue") : nil)
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
                    queue.append(contentsOf: children.map { ($0, inToolbar) })
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
                let albumName: String?
                let albumDocID: Int64?
                switch albumEvidence.resolve() {
                case .unknown: albumName = nil; albumDocID = nil
                case .scope(let name, let id): albumName = name; albumDocID = id
                case .conflicting: return LightroomSnapshot(state: .temporarilyUnavailable, windowFrame: frame)
                }
                let document = string(window, kAXDocumentAttribute)
                let path = document.flatMap { URL(string: $0) }.flatMap { $0.isFileURL ? $0.path : nil }
                return LightroomSnapshot(state: .selected(PhotoSelection(filename: filename, documentPath: path, albumName: albumName, source: source, albumDocID: albumDocID)), windowFrame: frame)
            }
        }
        if minimizedCount == windows.count { return LightroomSnapshot(state: .noPhoto, windowFrame: nil) }
        return LightroomSnapshot(state: .temporarilyUnavailable, windowFrame: visibleMainFrame)
    }
}
