// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct SelectionClassificationTests {
    static func main() {
        func classify(_ failed: Bool = false, grid: Bool = false, compare: Bool = false,
                      detail: Bool? = true, candidates: Int = 1, sourceKnown: Bool = true) -> PhotoReadClassification {
            PhotoReadClassification.classify(hasMainContent: true, readFailed: failed, gridSelected: grid,
                compareSelected: compare, detailSelected: detail, candidateCount: candidates, sourceKnown: sourceKnown)
        }
        precondition(classify() == .singlePhoto)
        precondition(classify(true) == .temporarilyUnavailable, "AX transport failure must not become a hide command")
        precondition(classify(candidates: 0) == .temporarilyUnavailable, "A temporarily absent loupe is not proof of grid mode")
        precondition(classify(detail: false) == .temporarilyUnavailable, "All mode buttons can be off during a view transition")
        precondition(classify(sourceKnown: false) == .temporarilyUnavailable, "Unknown Cloud/Local must not masquerade as a source change")
        precondition(classify(grid: true, detail: false, candidates: 0) == .noPhoto)
        precondition(classify(compare: true, detail: false, candidates: 2) == .noPhoto)
        precondition(classify(candidates: 2) == .noPhoto)
        precondition(classify(detail: nil) == .singlePhoto, "Hidden toolbar is allowed when a complete single-image sample exists")
        precondition(PhotoReadClassification.classify(hasMainContent: false, readFailed: false,
            gridSelected: false, compareSelected: false, detailSelected: nil, candidateCount: 0,
            sourceKnown: true) == .temporarilyUnavailable)
        print("PASS: transient AX failures/gaps stay distinct from confirmed grid/compare/no-single-photo states")
    }
}
