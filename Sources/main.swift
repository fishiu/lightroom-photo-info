// SPDX-License-Identifier: GPL-3.0-only
import AppKit

if CommandLine.arguments.contains("--diagnose") {
    switch LightroomSelectionReader().read() {
    case .permissionRequired: print("permissionRequired")
    case .notRunning: print("notRunning")
    case .noPhoto: print("noPhoto")
    case .temporarilyUnavailable: print("temporarilyUnavailable")
    case .selected(let selection):
        print(String(data: try JSONEncoder().encode(selection), encoding: .utf8)!)
        guard selection.source == .cloud else { print("Unsupported source: \(selection.source.rawValue)"); exit(0) }
        switch MetadataStore().lookup(filename: selection.filename, albumName: selection.albumName) {
        case .found(let photo): print(String(data: try JSONEncoder().encode(photo), encoding: .utf8)!)
        case .unavailable(let reason): print(reason)
        }
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
