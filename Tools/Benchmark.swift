// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Darwin

@main
struct Benchmark {
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func measure(_ name: String, count: Int, _ action: () -> Void) -> [String: Any] {
        var times: [Double] = []
        let cpuBefore = cpuSeconds()
        for _ in 0..<count {
            let start = ProcessInfo.processInfo.systemUptime
            action()
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        times.sort()
        return ["name": name, "samples": count, "median_ms": times[count / 2],
                "p95_ms": times[min(count - 1, Int(Double(count) * 0.95))],
                "mean_ms": times.reduce(0, +) / Double(count),
                "process_cpu_ms": (cpuSeconds() - cpuBefore) * 1000]
    }

    static func main() throws {
        func argument(_ key: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: key), index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        let reader = LightroomSelectionReader()
        let snapshot = reader.readSnapshot()
        var output: [String: Any] = ["frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"]
        var metrics: [[String: Any]] = []
        var validReads = 0
        metrics.append(measure("selection_read", count: 40) {
            if case .selected = reader.readSnapshot().state { validReads += 1 }
        })
        output["valid_selection_reads"] = validReads
        var target: PhotoSelection?
        if case .selected(let selected) = snapshot.state { target = selected }
        if let filename = argument("--filename") {
            target = PhotoSelection(filename: filename, documentPath: nil, albumName: argument("--album"), source: .cloud)
            output["metadata_target"] = "explicit sample; independent of UI selection"
        }
        if let selected = target {
            output["filename"] = selected.filename
            output["album"] = selected.albumName ?? ""
            var successful = 0
            metrics.append(measure("metadata_new_store", count: 10) {
                if case .found = MetadataStore().lookup(filename: selected.filename, albumName: selected.albumName) { successful += 1 }
            })
            let store = MetadataStore()
            _ = store.lookup(filename: selected.filename, albumName: selected.albumName)
            metrics.append(measure("metadata_repeat", count: 100) {
                if case .found = store.lookup(filename: selected.filename, albumName: selected.albumName) { successful += 1 }
            })
            if validReads == 40 {
                metrics.append(measure("old_poll_work", count: 30) {
                    _ = reader.readSnapshot()
                    _ = store.lookup(filename: selected.filename, albumName: selected.albumName)
                    _ = reader.readSnapshot()
                })
#if OPTIMIZED
                var schedule = MetadataRefreshSchedule()
                var tick = 0
                var metadataLookups = 0
                metrics.append(measure("scheduled_poll_work", count: 100) {
                    let state = reader.readSnapshot().state
                    let now = Double(tick) / 10
                    tick += 1
                    guard case .selected(let current) = state else { return }
                    if schedule.needsLookup(for: current, at: now) {
                        _ = store.lookup(filename: current.filename, albumName: current.albumName)
                        if case .selected(let verified) = reader.readSnapshot().state, current == verified {
                            schedule.complete(current, at: now)
                        }
                        metadataLookups += 1
                    }
                })
                output["scheduled_metadata_lookups_per_100_ticks"] = metadataLookups
                output["scheduled_tick_interval_ms"] = 100
#endif
            }
#if OPTIMIZED
            output["cache_statistics"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.cacheStatistics()))
#endif
            output["successful_metadata_reads"] = successful
        }
        output["measurements"] = metrics
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
