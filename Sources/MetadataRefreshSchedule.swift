// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Selection still polls at interactive speed; unchanged capture data is revalidated once per second.
/// This schedule belongs to the serial reader queue, including the matching cached lookup result.
struct MetadataRefreshSchedule {
    let interval: TimeInterval = 1
    private var selection: PhotoSelection?
    private var completedAt: TimeInterval?

    func needsLookup(for candidate: PhotoSelection, at now: TimeInterval) -> Bool {
        guard candidate == selection, let completedAt else { return true }
        return now - completedAt >= interval || now < completedAt
    }

    mutating func complete(_ candidate: PhotoSelection, at now: TimeInterval) {
        selection = candidate
        completedAt = now
    }
}
