// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ApplicationServices

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

        var plain = AlbumScopeEvidence()
        plain.observe(role: kAXTextFieldRole, identifier: "organize_search_field", title: "搜索 Album A")
        precondition(plain.resolve() == .scope(name: "Album A", docID: nil))
        // The text field's own semantic label takes precedence over a legacy button.
        plain.observe(role: kAXButtonRole, identifier: "old_search", title: "Search Old Album")
        precondition(plain.resolve() == .scope(name: "Album A", docID: nil))

        var placeholder = AlbumScopeEvidence()
        placeholder.observe(role: kAXTextFieldRole, identifier: "organize_search_field", title: "", placeholder: "Search Album B")
        precondition(placeholder.resolve() == .scope(name: "Album B", docID: nil))
        var legacy = AlbumScopeEvidence()
        legacy.observe(role: kAXButtonRole, identifier: "legacy", title: "", description: "搜索 Album C")
        precondition(legacy.resolve() == .scope(name: "Album C", docID: nil))

        var filtered = AlbumScopeEvidence()
        filtered.observe(role: kAXTextFieldRole, identifier: "organize_search_field", title: "搜索照片", description: "Search Wrong")
        filtered.observe(role: kAXButtonRole, identifier: "accessibility_id_15/FlagsFilter:1/title", title: "旗标: 已选取")
        precondition(filtered.resolve() == .unknown, "Generic text and filter labels are not album names")
        filtered.observe(role: kAXButtonRole, identifier: "accessibility_id_15/CollectionSource:42/title", title: "相册: Album D")
        precondition(filtered.resolve() == .scope(name: "Album D", docID: 42))
        filtered.observe(role: kAXButtonRole, identifier: "accessibility_id_15/CollectionSource:42/thumbnail_image", title: "相册: Album D 2")
        precondition(filtered.resolve() == .scope(name: "Album D", docID: 42), "Only token title carries identity")
        filtered.observe(role: kAXButtonRole, identifier: "accessibility_id_15/CollectionSource:43/title", title: "相册: Album E")
        precondition(filtered.resolve() == .conflicting, "Multiple active albums must not select an arbitrary one")

        var mismatch = AlbumScopeEvidence()
        mismatch.observe(role: kAXTextFieldRole, identifier: "organize_search_field", title: "Search Album A")
        mismatch.observe(role: kAXButtonRole, identifier: "tokens/CollectionSource:42/title", title: "Album: Album B")
        precondition(mismatch.resolve() == .conflicting, "A mixed-frame scope must not be published")
        for id in ["0", "-1", "042", "42suffix", "42,43", "9223372036854775808"] {
            var invalid = AlbumScopeEvidence()
            invalid.observe(role: kAXButtonRole, identifier: "tokens/CollectionSource:\(id)/title", title: "Album: Album B")
            precondition(invalid.resolve() == .conflicting, "Malformed token IDs must fail closed")
        }
        var arbitrary = AlbumScopeEvidence()
        arbitrary.observe(role: kAXTextFieldRole, identifier: "unrelated_field", title: "Search Album A")
        arbitrary.observe(role: kAXButtonRole, identifier: "tokens/Keyword:CollectionSource:42/title", title: "Album: Album B")
        precondition(arbitrary.resolve() == .unknown, "Unrelated fields and free-text tokens are not album scopes")
        var partial = AlbumScopeEvidence()
        partial.observe(role: kAXButtonRole, identifier: "tokens/CollectionSource:42/closebox", title: "Remove Album: Album B")
        precondition(partial.resolve() == .conflicting, "A partially published album token is not an unscoped view")
        partial.observe(role: kAXButtonRole, identifier: "tokens/CollectionSource:42/title", title: "Album: Album B")
        precondition(partial.resolve() == .scope(name: "Album B", docID: 42))
        partial.observe(role: kAXButtonRole, identifier: "tokens/CollectionSource:43/thumbnail_image", title: "Album: Album C 2")
        precondition(partial.resolve() == .conflicting, "Every observed album token needs its own complete title")
        print("PASS: transient AX failures/gaps stay distinct from confirmed grid/compare/no-single-photo states")
        print("PASS: native album field labels and typed album IDs; filters, malformed IDs and conflicting scopes fail closed")
    }
}
