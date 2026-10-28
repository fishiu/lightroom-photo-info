// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SQLite3

struct PhotoMetadata: Codable, Equatable {
    let filename: String
    let camera: String
    let lens: String
    let focalLength: String
    let shutter: String
    let aperture: String
    let iso: String
    let captureDate: String
    let assetID: String
    var matchNote: String? = nil
    var focalLengthMM: Double? = nil
    var equivalentFocalLengthMM: Double? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil

    fileprivate var displayedValues: [String] {
        [filename, camera, lens, focalLength, shutter, aperture, iso, captureDate,
         focalLengthMM.map { String($0) } ?? "", equivalentFocalLengthMM.map { String($0) } ?? "",
         pixelWidth.map { String($0) } ?? "", pixelHeight.map { String($0) } ?? ""]
    }
}

enum MetadataLookup {
    case found(PhotoMetadata)
    case unavailable(String)
}

/// Lightroom cache adapter, verified against desktop 9.6. All connections are read-only.
/// A filename alone is never used to choose between multiple matching assets.
final class MetadataStore {
    struct Statistics: Codable {
        let resolutionCacheHits: Int
        let metadataCacheHits: Int
        let metadataDecodes: Int
        let cachedResolutionCount: Int
        let cachedMetadataCount: Int
        let cachedMetadataBytes: Int
    }
    private let lock = NSLock()
    private let libraryURL: URL
    private let cacheCapacity: Int
    private let metadataByteLimit = 2 * 1024 * 1024
    private var catalogs: [Catalog] = []
    private var lastDiscovery = Date.distantPast
    private var indexVersions: [Int64] = []
    private var resolutionCache: [ResolutionKey: ResolutionEntry] = [:]
    private var metadataCache: [MetadataKey: MetadataEntry] = [:]
    private var metadataBytes = 0
    private var accessCounter: UInt64 = 0
    private var resolutionHits = 0
    private var metadataHits = 0
    private var decodes = 0
    private let missing = "未记录"
    private static let fractionRegex = try? NSRegularExpression(pattern: #"\.(\d+)(?=Z$|[+-]\d{2}:?\d{2}$|$)"#)
    private let formatter: NumberFormatter = {
        let value = NumberFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.minimumFractionDigits = 0
        value.maximumFractionDigits = 2
        value.usesGroupingSeparator = false
        return value
    }()

    init(libraryURL: URL? = nil, cacheCapacity: Int = 256) {
        self.libraryURL = libraryURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Lightroom Library.lrlibrary", isDirectory: true)
        self.cacheCapacity = max(0, min(cacheCapacity, 4096))
    }

    func cacheStatistics() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(resolutionCacheHits: resolutionHits, metadataCacheHits: metadataHits,
            metadataDecodes: decodes, cachedResolutionCount: resolutionCache.count,
            cachedMetadataCount: metadataCache.count, cachedMetadataBytes: metadataBytes)
    }

    func lookup(filename: String, albumName: String? = nil) -> MetadataLookup {
        lock.lock()
        defer { lock.unlock() }
        do {
            try discoverIfNeeded()
            guard !catalogs.isEmpty else { return .unavailable("未找到 Lightroom CC 本地图库") }
            let versions = try catalogs.map { try $0.synchronize() }
            let currentIndexVersions = versions.map { $0.index }
            if currentIndexVersions != indexVersions {
                resolutionCache.removeAll(keepingCapacity: true)
                indexVersions = currentIndexVersions
            }
            let matches = try resolve(filename: filename, albumName: albumName)
            guard !matches.isEmpty else { return .unavailable("无法确认当前照片的图库记录") }
            let results = try matches.map { try metadata(catalog: $0.0, candidate: $0.1) }
            // Either database may change during the lookup. Never publish a mixed-generation result.
            guard try catalogs.map({ try $0.versions() }) == versions else {
                resolutionCache.removeAll(keepingCapacity: true)
                return .unavailable("图库正在更新，稍后自动重试")
            }
            guard let first = results.first else { return .unavailable("无法确认当前照片的图库记录") }
            if results.count > 1 {
                guard results.allSatisfy({ $0.displayedValues == first.displayedValues }) else {
                    return .unavailable("同名照片 \(matches.count) 张且参数不同，无法唯一匹配")
                }
                // Identity remains ambiguous, but every displayed value is common to all candidates.
                // Never assign one candidate's assetID to this aggregate result.
                var common = PhotoMetadata(filename: first.filename, camera: first.camera, lens: first.lens,
                    focalLength: first.focalLength, shutter: first.shutter, aperture: first.aperture,
                    iso: first.iso, captureDate: first.captureDate, assetID: "",
                    focalLengthMM: first.focalLengthMM, equivalentFocalLengthMM: first.equivalentFocalLengthMM,
                    pixelWidth: first.pixelWidth, pixelHeight: first.pixelHeight)
                common.matchNote = "同名照片的拍摄参数一致"
                return .found(common)
            }
            return .found(first)
        } catch CatalogError.ambiguousAlbum {
            return .unavailable("存在多个同名相册，无法确认当前范围")
        } catch CatalogError.noCaptureMetadata {
            return .unavailable("这张照片尚无可读取的拍摄参数")
        } catch CatalogError.unsupportedSchema {
            return .unavailable("Lightroom 图库结构已变化，需要更新工具")
        } catch {
            // Do not leak database paths, account identifiers, or raw metadata into user-facing errors.
            return .unavailable("图库暂时无法读取，稍后自动重试")
        }
    }

    private func resolve(filename: String, albumName: String?) throws -> [(Catalog, Candidate)] {
        accessCounter &+= 1
        let key = ResolutionKey(filename: filename, album: albumName ?? "")
        if var cached = resolutionCache[key] {
            resolutionHits += 1
            cached.access = accessCounter
            resolutionCache[key] = cached
            return cached.matches
        }
        var matches: [(Catalog, Candidate)] = []
        for catalog in catalogs {
            matches += try catalog.candidates(filename: filename).map { (catalog, $0) }
        }
        if let albumName, !albumName.isEmpty {
            var albums: [(Catalog, String)] = []
            for catalog in catalogs {
                albums += try catalog.albumIDs(named: albumName).map { (catalog, $0) }
            }
            guard albums.count <= 1 else { throw CatalogError.ambiguousAlbum }
            if let (albumCatalog, albumID) = albums.first {
                var scoped: [(Catalog, Candidate)] = []
                for (catalog, candidate) in matches where catalog === albumCatalog {
                    if try catalog.contains(candidate: candidate, albumID: albumID) { scoped.append((catalog, candidate)) }
                }
                matches = scoped
            }
        }
        // Bound both the number of keys and the size of unusually ambiguous names.
        if cacheCapacity > 0, matches.count <= 64, filename.utf8.count + (albumName?.utf8.count ?? 0) <= 4096 {
            resolutionCache[key] = ResolutionEntry(matches: matches, access: accessCounter)
            if resolutionCache.count > cacheCapacity,
               let oldest = resolutionCache.min(by: { $0.value.access < $1.value.access })?.key {
                resolutionCache.removeValue(forKey: oldest)
            }
        }
        return matches
    }

    private func metadata(catalog: Catalog, candidate: Candidate) throws -> PhotoMetadata {
        accessCounter &+= 1
        let key = MetadataKey(catalog: ObjectIdentifier(catalog), docID: candidate.docID,
                              assetID: candidate.assetID, filename: candidate.filename)
        let revision = try catalog.revision(docID: candidate.docID)
        if var cached = metadataCache[key], cached.revision == revision,
           cached.dataVersion == catalog.documentDataVersion {
            metadataHits += 1
            cached.access = accessCounter
            metadataCache[key] = cached
            return cached.photo
        }
        if let previous = metadataCache.removeValue(forKey: key) { metadataBytes -= previous.cost }
        let content = try catalog.document(docID: candidate.docID, revision: revision)
        decodes += 1
        var decoder = try MessagePackDecoder(data: content)
        guard let document = try decoder.decode() as? [String: Any],
              let xmp = document["xmp"] as? [String: Any] else {
            throw CatalogError.noCaptureMetadata
        }
        let tiff = xmp["tiff"] as? [String: Any] ?? [:]
        let exif = xmp["exif"] as? [String: Any] ?? [:]
        let aux = xmp["aux"] as? [String: Any] ?? [:]
        let exifEX = xmp["exifEX"] as? [String: Any] ?? [:]
        let make = text(tiff["Make"])
        let model = text(tiff["Model"])
        let camera = [make, model].compactMap { $0 }.reduce("") { current, value in
            if current.isEmpty { return value }
            if value.localizedCaseInsensitiveContains(current) { return value }
            return current + " " + value
        }
        let lens = text(aux["Lens"]) ?? text(exifEX["LensModel"]) ?? text(exif["LensModel"]) ?? missing
        let focalMM = rational(exif["FocalLength"]).flatMap { $0 > 0 ? $0 : nil }
        // A zero EXIF value means unknown. Never infer this value from Camera Raw crop edits.
        let equivalentMM = rational(exif["FocalLengthIn35mmFilm"]).flatMap { $0 > 0 ? $0 : nil }
        let focal = focalMM.map { format($0) + " mm" } ?? missing
        let aperture = rational(exif["FNumber"]).map { "f/" + format($0) } ?? missing
        let exposure = rational(exif["ExposureTime"])
        let shutter = exposure.map { seconds -> String in
            guard seconds > 0 else { return missing }
            if seconds < 1 { return "1/" + format(1 / seconds) + " s" }
            return format(seconds) + " s"
        } ?? missing
        let isoValue: Any? = (exif["ISOSpeedRatings"] as? [Any])?.first ?? exif["ISOSpeedRatings"]
        let iso = number(isoValue).map { format($0) } ?? missing
        let capture = canonicalCaptureDate(text(exif["DateTimeOriginal"]) ?? text(document["captureDate"]) ?? missing)
        // These are the imported source's pixel dimensions, including its recorded orientation.
        // Never substitute develop.croppedWidth/Height: those describe Lightroom's later crop.
        let original = document["importSource"] as? [String: Any] ?? [:]
        let pixelWidth = positiveInteger(original["originalWidth"])
        let pixelHeight = positiveInteger(original["originalHeight"])
        let photo = PhotoMetadata(filename: candidate.filename,
            camera: camera.isEmpty ? missing : camera, lens: lens,
            focalLength: focal, shutter: shutter, aperture: aperture, iso: iso,
            captureDate: capture, assetID: candidate.assetID,
            focalLengthMM: focalMM, equivalentFocalLengthMM: equivalentMM,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let cost = photo.displayedValues.reduce(512) { $0 + $1.utf8.count } + photo.assetID.utf8.count
        if cacheCapacity > 0, cost <= 16 * 1024 {
            metadataCache[key] = MetadataEntry(revision: revision, dataVersion: catalog.documentDataVersion,
                                              photo: photo, cost: cost, access: accessCounter)
            metadataBytes += cost
            while metadataCache.count > cacheCapacity || metadataBytes > metadataByteLimit {
                guard let oldest = metadataCache.min(by: { $0.value.access < $1.value.access })?.key,
                      let removed = metadataCache.removeValue(forKey: oldest) else { break }
                metadataBytes -= removed.cost
            }
        }
        return photo
    }

    private func discoverIfNeeded() throws {
        guard catalogs.isEmpty || Date().timeIntervalSince(lastDiscovery) > 60 else { return }
        lastDiscovery = Date()
        let directories = (try? FileManager.default.contentsOfDirectory(at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var discovered: [Catalog] = []
        for directory in directories {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Managed Catalog.wfindex").path),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent("Managed Catalog.mcat").path) {
                discovered.append(try Catalog(directory: directory))
            }
        }
        catalogs = discovered
        indexVersions = []
        resolutionCache.removeAll(keepingCapacity: true)
        metadataCache.removeAll(keepingCapacity: true)
        metadataBytes = 0
    }

    private func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Lightroom versions can encode the same subsecond as .28 or .280.
    /// Remove only insignificant trailing zeros, preserving all time and timezone information.
    private func canonicalCaptureDate(_ value: String) -> String {
        guard let regex = Self.fractionRegex,
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let fractionRange = Range(match.range(at: 1), in: value),
              let replacementRange = Range(match.range, in: value) else { return value }
        var fraction = String(value[fractionRange])
        while fraction.last == "0" { fraction.removeLast() }
        return value.replacingCharacters(in: replacementRange, with: fraction.isEmpty ? "" : "." + fraction)
    }

    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = Int(exactly: number.doubleValue), result > 0 else { return nil }
        return result
    }

    private func rational(_ value: Any?) -> Double? {
        if let values = value as? [Any], values.count == 2,
           let numerator = number(values[0]), let denominator = number(values[1]), denominator != 0 {
            let result = numerator / denominator
            return result.isFinite ? result : nil
        }
        return number(value)
    }

    private func format(_ value: Double) -> String {
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

private enum CatalogError: Error { case open, query, missingDocument, unsupportedSchema, noCaptureMetadata, ambiguousAlbum }
private struct Candidate { let docID: Int64; let filename: String; let assetID: String }
private struct ResolutionKey: Hashable { let filename: String; let album: String }
private struct ResolutionEntry { let matches: [(Catalog, Candidate)]; var access: UInt64 }
private struct MetadataKey: Hashable { let catalog: ObjectIdentifier; let docID: Int64; let assetID: String; let filename: String }
private struct MetadataEntry { let revision: Int64; let dataVersion: Int64; let photo: PhotoMetadata; let cost: Int; var access: UInt64 }
private struct CatalogVersion: Equatable { let index: Int64; let documents: Int64 }

private final class ReadOnlyDatabase {
    let handle: OpaquePointer
    init(url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw CatalogError.open
        }
        handle = db
        sqlite3_busy_timeout(db, 200)
        sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil)
    }
    deinit { sqlite3_close(handle) }
    func statement(_ sql: String, _ bindings: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CatalogError.query
        }
        for (index, value) in bindings.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            if result != SQLITE_OK { sqlite3_finalize(statement); throw CatalogError.query }
        }
        return statement
    }
    func version() throws -> Double {
        let statement = try statement("SELECT currentVersion FROM schemaVersion LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CatalogError.query }
        return sqlite3_column_double(statement, 0)
    }
    func dataVersion() throws -> Int64 {
        let statement = try statement("PRAGMA data_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CatalogError.query }
        return sqlite3_column_int64(statement, 0)
    }
    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}

private final class Catalog {
    let index: ReadOnlyDatabase
    let documents: ReadOnlyDatabase
    private var lastVersions: CatalogVersion?
    var documentDataVersion: Int64 { lastVersions?.documents ?? -1 }
    init(directory: URL) throws {
        index = try ReadOnlyDatabase(url: directory.appendingPathComponent("Managed Catalog.wfindex"))
        documents = try ReadOnlyDatabase(url: directory.appendingPathComponent("Managed Catalog.mcat"))
        _ = try synchronize()
    }
    func versions() throws -> CatalogVersion {
        CatalogVersion(index: try index.dataVersion(), documents: try documents.dataVersion())
    }
    /// External commits invalidate the relevant cache layer, including in-place private-format changes.
    func synchronize() throws -> CatalogVersion {
        let current = try versions()
        if lastVersions != current {
            guard abs(try index.version() - 1.0) < 0.0001,
                  abs(try documents.version() - 1.2) < 0.0001 else { throw CatalogError.unsupportedSchema }
            lastVersions = current
        }
        return current
    }
    func candidates(filename: String) throws -> [Candidate] {
        let statement = try index.statement("SELECT docId, filename, assetId FROM assets WHERE filename=? AND subtype IN ('image','video')", [filename])
        defer { sqlite3_finalize(statement) }
        var candidates: [Candidate] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            candidates.append(Candidate(docID: sqlite3_column_int64(statement, 0),
                filename: ReadOnlyDatabase.text(statement, 1), assetID: ReadOnlyDatabase.text(statement, 2)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CatalogError.query }
        return candidates
    }
    func albumIDs(named name: String) throws -> [String] {
        let albums = try index.statement("SELECT albumId FROM albums WHERE name=? AND hidden=0", [name])
        defer { sqlite3_finalize(albums) }
        var result: [String] = []
        var status = sqlite3_step(albums)
        while status == SQLITE_ROW {
            result.append(ReadOnlyDatabase.text(albums, 0))
            status = sqlite3_step(albums)
        }
        guard status == SQLITE_DONE else { throw CatalogError.query }
        return result
    }
    func contains(candidate: Candidate, albumID: String) throws -> Bool {
        let membership = try index.statement("SELECT 1 FROM album_asset_v2 WHERE assetId=? AND albumId=? LIMIT 1", [candidate.assetID, albumID])
        defer { sqlite3_finalize(membership) }
        let status = sqlite3_step(membership)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw CatalogError.query }
        return status == SQLITE_ROW
    }
    func revision(docID: Int64) throws -> Int64 {
        let statement = try documents.statement("SELECT winningRevSequence FROM docs WHERE localDocId=? AND deleted=0")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, docID)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CatalogError.missingDocument }
        return sqlite3_column_int64(statement, 0)
    }
    func document(docID: Int64, revision: Int64) throws -> Data {
        let statement = try documents.statement("SELECT r.content FROM docs d JOIN revs r ON r.sequence=d.winningRevSequence WHERE d.localDocId=? AND d.deleted=0 AND d.winningRevSequence=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, docID)
        sqlite3_bind_int64(statement, 2, revision)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { throw CatalogError.missingDocument }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, count <= 8 * 1024 * 1024 else { throw CatalogError.missingDocument }
        return Data(bytes: bytes, count: count)
    }
}
