// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct MetadataRefreshTests {
    static func main() {
        let a = PhotoSelection(filename: "a.RAF", documentPath: nil, albumName: "Album A", source: .cloud)
        let b = PhotoSelection(filename: "b.RAF", documentPath: nil, albumName: "Album A", source: .cloud)
        var schedule = MetadataRefreshSchedule()
        precondition(schedule.needsLookup(for: a, at: 0))
        schedule.complete(a, at: 0)
        precondition(!schedule.needsLookup(for: a, at: 0.1))
        precondition(!schedule.needsLookup(for: a, at: 0.999))
        precondition(schedule.needsLookup(for: a, at: 1))
        precondition(schedule.needsLookup(for: b, at: 0.1), "Switching a photo must bypass the refresh interval")
        let anotherAlbum = PhotoSelection(filename: "a.RAF", documentPath: nil, albumName: "Album B", source: .cloud)
        precondition(schedule.needsLookup(for: anotherAlbum, at: 0.1), "Album scope is part of the key")
        let local = PhotoSelection(filename: "a.RAF", documentPath: nil, albumName: "Album A", source: .local)
        precondition(schedule.needsLookup(for: local, at: 0.1), "Local must never reuse a cloud result")
        // Ten seconds at 10Hz: every tick still checks selection, but an unchanged photo resolves ten times.
        schedule = MetadataRefreshSchedule()
        var lookups = 0
        for tick in 0..<100 {
            let time = Double(tick) / 10
            if schedule.needsLookup(for: a, at: time) { lookups += 1; schedule.complete(a, at: time) }
        }
        precondition(lookups == 10, "Unchanged 10Hz polling should perform 1Hz metadata validation")
        print("PASS: unchanged photo 100 ticks -> 10 lookups; photo, album and source changes refresh immediately")
    }
}
