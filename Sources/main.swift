// SPDX-License-Identifier: GPL-3.0-only
import AppKit

if CommandLine.arguments.contains("--diagnose") {
    DispatchQueue.global(qos: .userInitiated).async {
        switch LightroomSelectionReader().read() {
        case .permissionRequired: print("permissionRequired")
        case .notRunning: print("notRunning")
        case .noPhoto: print("noPhoto")
        case .temporarilyUnavailable: print("temporarilyUnavailable")
        case .selected(let selection):
            if let data = try? JSONEncoder().encode(selection) { print(String(decoding: data, as: UTF8.self)) }
            guard selection.source == .cloud else { print("Unsupported source: \(selection.source.rawValue)"); exit(0) }
            switch MetadataStore().lookup(filename: selection.filename, albumName: selection.albumName,
                albumTokenTexts: selection.albumTokenTexts, albumCapturePermissionNeeded: selection.albumCapturePermissionNeeded) {
            case .found(let photo):
                if let data = try? JSONEncoder().encode(photo) { print(String(decoding: data, as: UTF8.self)) }
            case .unavailable(let reason): print(reason)
            }
        }
        exit(0)
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
