// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

/// A small fixture encoder, deliberately restricted to the values used by these tests.
private func pack(_ value: Any) throws -> Data {
    if let string = value as? String {
        let utf8 = Data(string.utf8)
        try expect(utf8.count < 256, "Fixture string too long")
        return (utf8.count < 32 ? Data([0xa0 | UInt8(utf8.count)]) : Data([0xd9, UInt8(utf8.count)])) + utf8
    }
    if let integer = value as? Int {
        try expect((0...65535).contains(integer), "Fixture integer out of range")
        if integer < 128 { return Data([UInt8(integer)]) }
        return Data([0xcd, UInt8(integer >> 8), UInt8(integer & 255)])
    }
    if let array = value as? [Any] {
        try expect(array.count < 16, "Fixture array too long")
        return try array.reduce(Data([0x90 | UInt8(array.count)])) { try $0 + pack($1) }
    }
    if let dictionary = value as? [String: Any] {
        try expect(dictionary.count < 16, "Fixture map too long")
        return try dictionary.keys.sorted().reduce(Data([0x80 | UInt8(dictionary.count)])) {
            try $0 + pack($1) + pack(dictionary[$1]!)
        }
    }
    throw TestFailure(description: "Unsupported fixture value")
}

private func execute(_ database: OpaquePointer, _ sql: String) throws {
    try expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK, "Fixture SQL failed")
}

private func createFixtures(at library: URL) throws {
    let catalog = library.appendingPathComponent("test-catalog", isDirectory: true)
    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
    var index: OpaquePointer?
    var documents: OpaquePointer?
    let indexResult = sqlite3_open(catalog.appendingPathComponent("Managed Catalog.wfindex").path, &index)
    let documentsResult = sqlite3_open(catalog.appendingPathComponent("Managed Catalog.mcat").path, &documents)
    defer { if let index { sqlite3_close(index) }; if let documents { sqlite3_close(documents) } }
    guard indexResult == SQLITE_OK, documentsResult == SQLITE_OK, let index, let documents else {
        throw TestFailure(description: "Unable to create temporary fixture databases")
    }
    try execute(index, """
        CREATE TABLE schemaVersion(currentVersion);
        INSERT INTO schemaVersion VALUES(1.0);
        CREATE TABLE assets(docId,filename,assetId,subtype);
        CREATE TABLE albums(albumId,name,hidden);
        CREATE TABLE album_asset_v2(assetId,albumId);
        INSERT INTO albums VALUES('album-a','Album A',0),('album-b','Album B',0),
                                 ('duplicate-a','Same Name',0),('duplicate-b','Same Name',0),('literal-close','Album B ×',0);
        INSERT INTO album_asset_v2 VALUES('test-1','album-a'),('test-2','album-a'),
                                        ('test-3','album-a'),('test-4','album-a'),('test-5','album-b'),('test-4','literal-close');
        """)
    try execute(documents, """
        CREATE TABLE schemaVersion(currentVersion);
        INSERT INTO schemaVersion VALUES(1.2);
        CREATE TABLE docs(localDocId,winningRevSequence,deleted);
        CREATE TABLE revs(sequence,content);
        """)

    let samples: [(String, Int, String, Int?)] = [
        ("unique.RAF", 160, "2026-01-01T10:00:00.28+08:00", 28),
        ("same.RAF", 160, "2026-01-01T10:00:00.28+08:00", 28),
        ("same.RAF", 160, "2026-01-01T10:00:00.280+08:00", 28),
        ("conflict.RAF", 100, "2026-01-01T10:00:00Z", nil),
        ("conflict.RAF", 200, "2026-01-01T10:00:00Z", nil),
        ("broken.RAF", 160, "2026-01-01T10:00:00Z", nil),
        ("equivalent-conflict.RAF", 160, "2026-01-01T10:00:00Z", 28),
        ("equivalent-conflict.RAF", 160, "2026-01-01T10:00:00Z", 50),
        ("size-conflict.RAF", 160, "2026-01-01T10:00:00Z", 28),
        ("size-conflict.RAF", 160, "2026-01-01T10:00:00Z", 28),
        ("no-size.RAF", 160, "2026-01-01T10:00:00Z", 28),
        ("invalid-size.RAF", 160, "2026-01-01T10:00:00Z", 28)
    ]
    for (offset, sample) in samples.enumerated() {
        let id = offset + 1
        // Names and IDs below are fixed test constants, never external SQL input.
        try execute(index, "INSERT INTO assets VALUES(\(id),'\(sample.0)','test-\(id)','image')")
        try execute(documents, "INSERT INTO docs VALUES(\(id),\(id),0)")
        let payload: Data
        if sample.0 == "broken.RAF" {
            payload = Data([0x81, 0xa1, 0x78]) // map key without its value
        } else {
            var exif: [String: Any] = ["ExposureTime": [1, 900], "FNumber": [4, 1], "FocalLength": [3500, 100],
                                      "ISOSpeedRatings": sample.1, "DateTimeOriginal": sample.2]
            if let equivalent = sample.3 { exif["FocalLengthIn35mmFilm"] = equivalent }
            var document: [String: Any] = ["xmp": [
                "tiff": ["Make": "FUJIFILM", "Model": "GFX100RF"],
                "exif": exif
            ], "develop": ["croppedWidth": 3000, "croppedHeight": 2000]]
            if sample.0 == "invalid-size.RAF" {
                document["importSource"] = ["originalWidth": "11648", "originalHeight": 0]
            } else if sample.0 != "no-size.RAF" {
                document["importSource"] = ["originalWidth": sample.0 == "size-conflict.RAF" && id == 10 ? 6000 : 11648,
                                            "originalHeight": 8736]
            }
            payload = try pack(document)
        }
        var statement: OpaquePointer?
        try expect(sqlite3_prepare_v2(documents, "INSERT INTO revs VALUES(?,?)", -1, &statement, nil) == SQLITE_OK,
                   "Unable to prepare fixture insert")
        guard let statement else { throw TestFailure(description: "Missing fixture statement") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(id))
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        try expect(sqlite3_step(statement) == SQLITE_DONE, "Unable to insert fixture payload")
    }
}

private func withWriter(_ library: URL, name: String, _ body: (OpaquePointer) throws -> Void) throws {
    let url = library.appendingPathComponent("test-catalog").appendingPathComponent(name)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw TestFailure(description: "Unable to open isolated external-writer fixture")
    }
    defer { sqlite3_close(database) }
    try body(database)
}

private func insertRevision(_ database: OpaquePointer, sequence: Int64, iso: Int) throws {
    let payload = try pack(["xmp": ["tiff": ["Make": "FUJIFILM", "Model": "GFX100RF"],
                                    "exif": ["ISOSpeedRatings": iso, "FocalLength": [35, 1]]]])
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "INSERT INTO revs VALUES(?,?)", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw TestFailure(description: "Cannot prepare external revision") }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, sequence)
    _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    try expect(sqlite3_step(statement) == SQLITE_DONE, "Cannot write external fixture revision")
}

@main
struct MetadataStoreTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw TestFailure(description: "Run through test.sh to provide an isolated temporary directory")
        }
        let library = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent("fixture-library", isDirectory: true)
        try createFixtures(at: library)
        let store = MetadataStore(libraryURL: library)

        guard case let .found(unique) = store.lookup(filename: "unique.RAF") else {
            throw TestFailure(description: "Unique fixture must return metadata")
        }
        try expect(unique.shutter == "1/900 s" && unique.iso == "160", "Incorrect metadata decoding")
        try expect(unique.matchNote == nil && unique.assetID == "test-1", "Unique fixture identity must be preserved")
        try expect(unique.focalLengthMM == 35 && unique.equivalentFocalLengthMM == 28, "Actual and equivalent focal metadata must decode separately")
        try expect(unique.pixelWidth == 11648 && unique.pixelHeight == 8736, "Original dimensions must ignore the later develop crop")

        guard case let .found(common) = store.lookup(filename: "same.RAF") else {
            throw TestFailure(description: "Equal duplicate metadata must return consensus")
        }
        try expect(common.matchNote != nil && common.assetID.isEmpty, "Consensus must not claim a unique asset identity")
        try expect(common.captureDate == "2026-01-01T10:00:00.28+08:00", "Timestamp normalization lost precision or timezone")
        try expect(common.focalLengthMM == 35 && common.equivalentFocalLengthMM == 28, "Consensus must preserve both focal values")
        try expect(common.pixelWidth == 11648 && common.pixelHeight == 8736, "Consensus must preserve original dimensions")

        for filename in ["no-size.RAF", "invalid-size.RAF"] {
            guard case let .found(photo) = store.lookup(filename: filename) else {
                throw TestFailure(description: "Unknown dimensions must not hide otherwise valid metadata")
            }
            try expect(photo.pixelWidth == nil && photo.pixelHeight == nil, "Missing/invalid original dimensions must not fall back to cropped dimensions")
        }

        for filename in ["conflict.RAF", "equivalent-conflict.RAF", "size-conflict.RAF", "broken.RAF", "missing.RAF"] {
            if case .found = store.lookup(filename: filename) {
                throw TestFailure(description: "Unsafe metadata accepted for \(filename)")
            }
        }

        // A newly visible photo in B may not be indexed yet; the sole same-name asset
        // currently indexed in A must never be treated as B's photo.
        guard case .found = store.lookup(filename: "unique.RAF", albumName: "Album A") else {
            throw TestFailure(description: "Matching known album should accept its asset")
        }
        if case .found = store.lookup(filename: "unique.RAF", albumName: "Album B") {
            throw TestFailure(description: "Single global match outside current album was accepted")
        }
        if case .found = store.lookup(filename: "unique.RAF", albumName: "Same Name") {
            throw TestFailure(description: "Duplicate album names must not choose an arbitrary album")
        }
        guard case let .found(scoped) = store.lookup(filename: "conflict.RAF", albumName: "Album B") else {
            throw TestFailure(description: "Unique album should resolve global filename conflict")
        }
        try expect(scoped.iso == "200" && scoped.assetID == "test-5", "Album resolution selected the wrong asset")
        // Search pills omit album labels from AX, regardless of which filter activated them.
        for tokens in [["Album B"], ["Album B ✕", "已选取"], ["Album B", "相机: X100VI"]] {
            guard case let .found(photo) = store.lookup(filename: "conflict.RAF", albumTokenTexts: tokens) else {
                throw TestFailure(description: "Search-token album was not resolved")
            }
            try expect(photo.assetID == "test-5", "Token scope selected another album's photo")
        }
        guard case let .found(other) = store.lookup(filename: "conflict.RAF", albumTokenTexts: ["Album A"]) else {
            throw TestFailure(description: "Switching album tokens reused an old resolution")
        }
        try expect(other.assetID == "test-4", "Previous album result leaked across a same-name photo switch")
        guard case let .found(literal) = store.lookup(filename: "conflict.RAF", albumTokenTexts: ["Album B ×"]) else {
            throw TestFailure(description: "Literal album suffix must be matched first")
        }
        try expect(literal.assetID == "test-4", "An album suffix was mistaken for a close glyph")
        for tokens in [["Album"], ["Album B X"], ["Album B…"], ["", "Album B"], ["已选取", "Album B"], ["Album A", "Album B"], ["Same Name"], ["已选取"], []] {
            if case .found = store.lookup(filename: "conflict.RAF", albumTokenTexts: tokens) {
                throw TestFailure(description: "Ambiguous, missing, or partial token scope was guessed")
            }
            if case .found = store.lookup(filename: "unique.RAF", albumTokenTexts: tokens) {
                throw TestFailure(description: "An unknown scope fell back to a unique global candidate")
            }
        }
        guard case .found = store.lookup(filename: "same.RAF", albumName: "所有照片") else {
            throw TestFailure(description: "Non-album scope should retain global consensus")
        }
        if case .found = store.lookup(filename: "conflict.RAF", albumName: "所有照片") {
            throw TestFailure(description: "Non-album scope must preserve global conflict rejection")
        }

        // Hot reads must reuse parsed metadata, not repeatedly decode MessagePack.
        _ = store.lookup(filename: "unique.RAF", albumName: "Album A")
        let warm = store.cacheStatistics()
        for _ in 0..<20 { _ = store.lookup(filename: "unique.RAF", albumName: "Album A") }
        let hot = store.cacheStatistics()
        try expect(hot.metadataDecodes == warm.metadataDecodes && hot.metadataCacheHits >= warm.metadataCacheHits + 20,
                   "Hot reads decoded metadata again")
        try expect(hot.resolutionCacheHits >= warm.resolutionCacheHits + 20, "Hot reads repeated scope resolution")

        // A separate writer changes the winning revision while the reader stays open.
        try withWriter(library, name: "Managed Catalog.mcat") { database in
            try insertRevision(database, sequence: 101, iso: 320)
            try execute(database, "UPDATE docs SET winningRevSequence=101 WHERE localDocId=1")
        }
        guard case let .found(updated) = store.lookup(filename: "unique.RAF", albumName: "Album A") else {
            throw TestFailure(description: "Changed winning revision must remain readable")
        }
        try expect(updated.iso == "320", "Cached metadata ignored external revision update")

        // The private cache format does not promise immutable revision rows. Data-version changes
        // must also cover a writer replacing a payload without changing winningRevSequence.
        try withWriter(library, name: "Managed Catalog.mcat") { database in
            try insertRevision(database, sequence: 102, iso: 640)
            try execute(database, "UPDATE revs SET content=(SELECT content FROM revs WHERE sequence=102) WHERE sequence=101")
        }
        guard case let .found(inPlace) = store.lookup(filename: "unique.RAF", albumName: "Album A") else {
            throw TestFailure(description: "Changed payload must remain readable")
        }
        try expect(inPlace.iso == "640", "Same-revision payload update remained cached")

        // Both positive and negative membership caches must follow external index commits.
        _ = store.lookup(filename: "unique.RAF", albumName: "Album B")
        try withWriter(library, name: "Managed Catalog.wfindex") { database in
            try execute(database, "UPDATE album_asset_v2 SET albumId='album-b' WHERE assetId='test-1'")
        }
        if case .found = store.lookup(filename: "unique.RAF", albumName: "Album A") {
            throw TestFailure(description: "Cached membership accepted a removed photo")
        }
        guard case .found = store.lookup(filename: "unique.RAF", albumName: "Album B") else {
            throw TestFailure(description: "Cached negative membership ignored new membership")
        }

        // A rename must not reuse the filename embedded in an old formatted-metadata entry.
        try withWriter(library, name: "Managed Catalog.wfindex") { database in
            try execute(database, "UPDATE assets SET filename='renamed.RAF' WHERE docId=1")
        }
        if case .found = store.lookup(filename: "unique.RAF") {
            throw TestFailure(description: "Old filename remained cached after rename")
        }
        guard case let .found(renamed) = store.lookup(filename: "renamed.RAF") else {
            throw TestFailure(description: "Renamed photo unavailable")
        }
        try expect(renamed.filename == "renamed.RAF", "Formatted cache returned old filename")

        // Introducing a conflicting same-name asset must invalidate a formerly unique resolution.
        try withWriter(library, name: "Managed Catalog.wfindex") { database in
            try execute(database, "UPDATE assets SET filename='renamed.RAF' WHERE docId=5")
        }
        if case .found = store.lookup(filename: "renamed.RAF") {
            throw TestFailure(description: "Cached unique resolution ignored a new conflicting duplicate")
        }

        let small = MetadataStore(libraryURL: library, cacheCapacity: 2)
        for name in ["renamed.RAF", "same.RAF", "conflict.RAF", "missing-one.RAF", "missing-two.RAF"] {
            _ = small.lookup(filename: name)
        }
        let bounded = small.cacheStatistics()
        try expect(bounded.cachedMetadataCount <= 2 && bounded.cachedResolutionCount <= 2,
                   "Cache exceeded its entry bound")
        try expect(bounded.cachedMetadataBytes <= 2 * 1024 * 1024, "Metadata cache exceeded its byte bound")
        let noCache = MetadataStore(libraryURL: library, cacheCapacity: 0)
        _ = noCache.lookup(filename: "same.RAF")
        try expect(noCache.cacheStatistics().cachedMetadataCount == 0 && noCache.cacheStatistics().cachedResolutionCount == 0,
                   "Disabling cache must keep it empty")
        print("PASS: metadata and scope correctness; bounded hot caches; external revisions, membership, renames and duplicates invalidate correctly")
    }
}
