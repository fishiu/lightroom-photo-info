// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct DisplayTransitionTests {
    static func main() {
        var window = MetadataTransitionWindow()
        window.begin(at: 10)
        let generation = window.generation
        precondition(window.phase(at: 10.10) == .grace)
        precondition(window.phase(at: 10.20) == .pending, "A slow read must mark old data, not clear/hide the panel")
        precondition(window.phase(at: 11.19) == .pending)
        window.begin(at: 10.25)
        window.begin(at: 10.9)
        precondition(window.startedAt == 10 && window.generation == generation, "Rapid candidates cannot reset stale-data bounds")
        precondition(window.phase(at: 11.21) == .unavailable, "Old numbers must not remain visible indefinitely")
        precondition(window.nextDeadline(at: 11.21) == nil)
        window.finish()
        precondition(window.startedAt == nil && window.generation != generation, "Commit cancels all old pending callbacks")
        window.begin(at: 20)
        precondition(window.nextDeadline(at: 20) == 20.15)
        precondition(window.nextDeadline(at: 20.2) == 21.2)
        print("PASS: short gaps hold one snapshot; slow reads are explicitly pending; stale data expires; no transient hide phase")
    }
}
