// Read-only access to an Apple Photos library's own database (Photos.sqlite).
//
// Two ways in, neither of which ever writes to a library (all changes go through PhotoKit):
// - `PhotosDatabase` copies Photos.sqlite (+ -wal/-shm) to a temporary folder and reads the copy.
//   Thorough but slow for big libraries; winnow-scores uses it to survey every score column.
// - `PhotosDatabase.countPhotos(withUUIDs:inLibrary:)` runs one query on the live file opened
//   read-only (`mode=ro`). Fast at any library size; used when opening a library.

import Foundation
import SQLite3

public struct PhotosDatabaseError: Error, LocalizedError {
    public enum Kind { case notFound, noAccess, unrecognisedSchema, sql }
    public let kind: Kind
    public let message: String
    public var errorDescription: String? { message }

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

// MARK: - SQLite

final class Database {
    private let handle: OpaquePointer

    init(readOnly path: String) throws {
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let h else {
            throw PhotosDatabaseError(kind: .noAccess, message: "Cannot open \(path)")
        }
        handle = h
    }

    /// Opens a database another process is using, read-only. In WAL mode this never blocks Photos.
    init(liveReadOnly path: String) throws {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var h: OpaquePointer?
        guard sqlite3_open_v2("file:\(encoded)?mode=ro", &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let h else {
            throw PhotosDatabaseError(kind: .noAccess, message: "Cannot open \(path)")
        }
        sqlite3_busy_timeout(h, 2000)
        handle = h
    }

    deinit { sqlite3_close(handle) }

    func rows(_ sql: String, _ arguments: [String] = []) throws -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PhotosDatabaseError(kind: .sql, message: "SQL error: \(String(cString: sqlite3_errmsg(handle)))\n\(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in arguments.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient)
        }
        var out: [[String?]] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<n).map { i in
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            })
        }
        return out
    }

    /// Calls `body` with each result row's statement, for typed reads of large results.
    func forEachRow(_ sql: String, _ arguments: [String] = [], _ body: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw PhotosDatabaseError(kind: .sql, message: "SQL error: \(String(cString: sqlite3_errmsg(handle)))\n\(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in arguments.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient) }
        while sqlite3_step(stmt) == SQLITE_ROW { body(stmt) }
    }

    func column(_ sql: String, _ arguments: [String] = []) throws -> [String] {
        try rows(sql, arguments).compactMap { $0.first ?? nil }
    }
}

func q(_ identifier: String) -> String { "\"\(identifier)\"" }

// MARK: - Schema

public struct ScoreTable: Sendable {
    public let name: String
    public let scoreColumns: [String]
    /// Column holding the asset's Z_PK, or nil if the table has more than one row per asset.
    public let assetKey: String?
}

public struct Schema: Sendable {
    public let assetTable: String
    public let assetColumns: Set<String>
    public let tables: [ScoreTable]
}

public struct ColumnStats: Identifiable, Sendable {
    public var id: String { "\(table).\(column)" }
    public let table: String
    public let column: String
    public let joinable: Bool
    public let nonNull: Int
    public let min: Double?
    public let max: Double?
    public let mean: Double?
}

// MARK: - PhotosDatabase

public final class PhotosDatabase {
    public let libraryURL: URL
    public let schema: Schema
    private var db: Database?
    private let snapshotDir: URL

    public var libraryName: String { libraryURL.deletingPathExtension().lastPathComponent }

    public init(library: URL) throws {
        let fm = FileManager.default
        let src = library.appendingPathComponent("database/Photos.sqlite")
        guard fm.fileExists(atPath: library.path) else {
            throw PhotosDatabaseError(kind: .notFound, message: "No Photos library at \(library.path).")
        }
        guard fm.isReadableFile(atPath: src.path) else {
            throw PhotosDatabaseError(kind: .noAccess, message: """
                Winnow can't read this library's database. Give it Full Disk Access in \
                System Settings › Privacy & Security › Full Disk Access, then try again.
                """)
        }

        let dir = fm.temporaryDirectory.appendingPathComponent("winnow-snapshot-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: src.path + suffix) {
                try fm.copyItem(atPath: src.path + suffix, toPath: dir.appendingPathComponent("Photos.sqlite" + suffix).path)
            }
            let db = try Database(readOnly: dir.appendingPathComponent("Photos.sqlite").path)
            self.schema = try Self.discover(db)
            self.db = db
        } catch {
            try? fm.removeItem(at: dir)
            if (error as NSError).domain == NSCocoaErrorDomain {
                throw PhotosDatabaseError(kind: .noAccess, message: """
                    Winnow can't copy this library's database (\(error.localizedDescription)). \
                    Give it Full Disk Access in System Settings › Privacy & Security › Full Disk Access.
                    """)
            }
            throw error
        }
        self.libraryURL = library
        self.snapshotDir = dir
    }

    deinit {
        db = nil // close before deleting the files under it
        try? FileManager.default.removeItem(at: snapshotDir)
    }

    /// How many of these asset UUIDs are in the library's own database. One query on the live
    /// file opened read-only, so it takes milliseconds whatever the library's size.
    public static func countPhotos(withUUIDs uuids: [String], inLibrary library: URL) throws -> Int {
        let path = library.appendingPathComponent("database/Photos.sqlite").path
        guard FileManager.default.fileExists(atPath: library.path) else {
            throw PhotosDatabaseError(kind: .notFound, message: "No Photos library at \(library.path).")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw PhotosDatabaseError(kind: .noAccess, message: """
                Winnow can't read this library's database. Give it Full Disk Access in \
                System Settings › Privacy & Security › Full Disk Access, then try again.
                """)
        }
        guard !uuids.isEmpty else { return 0 }
        let db = try Database(liveReadOnly: path)
        let tables = try db.column("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('ZASSET', 'ZGENERICASSET')")
        guard let table = tables.first else {
            throw PhotosDatabaseError(kind: .unrecognisedSchema,
                                      message: "This library's database has no asset table Winnow recognises.")
        }
        let placeholders = Array(repeating: "?", count: uuids.count).joined(separator: ",")
        let count = try db.column("SELECT COUNT(*) FROM \(q(table)) WHERE ZUUID IN (\(placeholders))", uuids).first
        return Int(count ?? "0") ?? 0
    }

    private var database: Database { db! }

    private static func discover(_ db: Database) throws -> Schema {
        let tables = try db.column("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        guard let assetTable = ["ZASSET", "ZGENERICASSET"].first(where: tables.contains) else {
            throw PhotosDatabaseError(kind: .unrecognisedSchema,
                                      message: "This library's database has no asset table Winnow recognises.")
        }
        var assetColumns: Set<String> = []
        var found: [ScoreTable] = []
        for table in tables {
            let columns = try db.rows("PRAGMA table_info(\(q(table)))").compactMap { $0[1] }
            if table == assetTable { assetColumns = Set(columns) }
            let scores = columns.filter { $0.uppercased().contains("SCORE") }
            guard !scores.isEmpty else { continue }

            var key: String?
            if table == assetTable {
                key = "Z_PK"
            } else if columns.contains("ZASSET") {
                // Only join tables with at most one row per asset, or results would duplicate photos.
                let counts = try db.rows("SELECT COUNT(ZASSET), COUNT(DISTINCT ZASSET) FROM \(q(table))")
                if let row = counts.first, row[0] == row[1] { key = "ZASSET" }
            }
            found.append(ScoreTable(name: table, scoreColumns: scores, assetKey: key))
        }
        return Schema(assetTable: assetTable, assetColumns: assetColumns, tables: found)
    }

    /// WHERE clause limiting rows to still photos not in Recently Deleted.
    private var photoFilter: String {
        var parts: [String] = []
        if schema.assetColumns.contains("ZKIND") { parts.append("a.ZKIND = 0") }
        if schema.assetColumns.contains("ZTRASHEDSTATE") { parts.append("a.ZTRASHEDSTATE = 0") }
        return parts.isEmpty ? "" : "WHERE " + parts.joined(separator: " AND ")
    }

    public func photoCount() throws -> Int {
        Int(try database.column("SELECT COUNT(*) FROM \(q(schema.assetTable)) a \(photoFilter)").first ?? "0") ?? 0
    }

    /// UUIDs of all photos; the part of a PhotoKit localIdentifier before the first "/".
    public func photoUUIDs() throws -> Set<String> {
        Set(try database.column("SELECT a.ZUUID FROM \(q(schema.assetTable)) a \(photoFilter)"))
    }

    public func columnStats() throws -> [ColumnStats] {
        var out: [ColumnStats] = []
        for table in schema.tables {
            for column in table.scoreColumns {
                let c = q(column)
                let s = try database.rows("SELECT COUNT(\(c)), MIN(\(c)), MAX(\(c)), AVG(\(c)) FROM \(q(table.name))").first ?? []
                out.append(ColumnStats(table: table.name, column: column, joinable: table.assetKey != nil,
                                       nonNull: Int(s.first.flatMap { $0 } ?? "0") ?? 0,
                                       min: s.count > 1 ? s[1].flatMap(Double.init) : nil,
                                       max: s.count > 2 ? s[2].flatMap(Double.init) : nil,
                                       mean: s.count > 3 ? s[3].flatMap(Double.init) : nil))
            }
        }
        return out
    }

    /// One row per photo: uuid followed by every score column that joins one row per asset.
    public func exportRows() throws -> (header: [String], rows: [[String?]]) {
        var select = ["a.ZUUID"]
        var header = ["uuid"]
        var joins: [String] = []
        for (i, table) in schema.tables.enumerated() {
            guard let key = table.assetKey else { continue }
            let alias = table.name == schema.assetTable ? "a" : "t\(i)"
            if alias != "a" { joins.append("LEFT JOIN \(q(table.name)) \(alias) ON \(alias).\(q(key)) = a.Z_PK") }
            for column in table.scoreColumns {
                select.append("\(alias).\(q(column))")
                header.append("\(table.name).\(column)")
            }
        }
        let sql = "SELECT \(select.joined(separator: ", ")) FROM \(q(schema.assetTable)) a \(joins.joined(separator: " ")) \(photoFilter)"
        return (header, try database.rows(sql))
    }

    /// The overall aesthetic score column, if this macOS version's schema has one.
    public var overallScoreColumn: String? {
        for table in schema.tables where table.assetKey != nil {
            if let c = table.scoreColumns.first(where: { $0.uppercased().contains("OVERALLAESTHETIC") }) {
                return "\(table.name).\(c)"
            }
        }
        return nil
    }

    /// uuid → a score column's value (default: the overall aesthetic score).
    public func scores(column: String? = nil) throws -> [String: Double] {
        guard let wanted = column ?? overallScoreColumn else { return [:] }
        let export = try exportRows()
        guard let index = export.header.firstIndex(of: wanted) else { return [:] }
        var out: [String: Double] = [:]
        for row in export.rows {
            if let uuid = row[0], let value = row[index].flatMap(Double.init) { out[uuid] = value }
        }
        return out
    }
}

// MARK: - Comparing rankings

/// Spearman rank correlation, with average ranks for ties.
public func spearman(_ pairs: [(Double, Double)]) -> Double {
    func ranks(_ v: [Double]) -> [Double] {
        let order = v.indices.sorted { v[$0] < v[$1] }
        var r = [Double](repeating: 0, count: v.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, v[order[j + 1]] == v[order[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for k in i...j { r[order[k]] = avg }
            i = j + 1
        }
        return r
    }
    let a = ranks(pairs.map(\.0)), b = ranks(pairs.map(\.1))
    let n = Double(pairs.count)
    let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
    var cov = 0.0, va = 0.0, vb = 0.0
    for i in a.indices {
        cov += (a[i] - ma) * (b[i] - mb)
        va += (a[i] - ma) * (a[i] - ma)
        vb += (b[i] - mb) * (b[i] - mb)
    }
    return cov / (va * vb).squareRoot()
}

/// How many of the first ranking's bottom fifth the second ranking also puts in its bottom fifth.
public func bottomFifthOverlap(_ pairs: [(Double, Double)]) -> (hits: Int, of: Int) {
    let k = max(1, pairs.count / 5)
    let a = Set(pairs.indices.sorted { pairs[$0].0 < pairs[$1].0 }.prefix(k))
    let b = Set(pairs.indices.sorted { pairs[$0].1 < pairs[$1].1 }.prefix(k))
    return (a.intersection(b).count, k)
}

// Opened and read off the main thread, then handed to the UI. SQLite runs in serialized mode
// on macOS, and nothing here mutates after init except closing in deinit.
extension PhotosDatabase: @unchecked Sendable {}

// MARK: - Apple's per-photo scores

/// The scores Apple Photos computes for a photo, as stored in its database. nil = not present.
public struct AppleScores: Sendable, Equatable {
    /// 0…1, higher is better. ZASSET.ZOVERALLAESTHETICSCORE.
    public var overall: Double?
    public var curation: Double?
    /// ≤ 0; more negative is more likely a failed shot.
    public var failure: Double?
    /// ≤ 0; more negative is noisier.
    public var noise: Double?
    /// 0…1 from Photos' media analysis.
    public var blurriness: Double?
    public var exposure: Double?
    public var sharpSubject: Double?
    public var composition: Double?
    public var lighting: Double?
    /// Positive when the blur looks intentional, like a portrait's soft background.
    public var tastefullyBlurred: Double?

    public init(overall: Double? = nil, curation: Double? = nil, failure: Double? = nil, noise: Double? = nil,
                blurriness: Double? = nil, exposure: Double? = nil, sharpSubject: Double? = nil,
                composition: Double? = nil, lighting: Double? = nil, tastefullyBlurred: Double? = nil) {
        self.overall = overall
        self.curation = curation
        self.failure = failure
        self.noise = noise
        self.blurriness = blurriness
        self.exposure = exposure
        self.sharpSubject = sharpSubject
        self.composition = composition
        self.lighting = lighting
        self.tastefullyBlurred = tastefullyBlurred
    }

    /// Photos has run its detailed analysis on this photo.
    public var isAnalysed: Bool { failure != nil }
}

extension PhotosDatabase {
    /// Every still photo's Apple scores, keyed by UUID. One query on the live database opened
    /// read-only; columns this macOS version doesn't have come back as nil.
    public static func readAppleScores(inLibrary library: URL) throws -> [String: AppleScores] {
        let path = library.appendingPathComponent("database/Photos.sqlite").path
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw PhotosDatabaseError(kind: .noAccess, message: """
                Winnow can't read this library's database. Give it Full Disk Access in \
                System Settings › Privacy & Security › Full Disk Access.
                """)
        }
        let db = try Database(liveReadOnly: path)
        let tables = Set(try db.column("SELECT name FROM sqlite_master WHERE type = 'table'"))
        func columns(_ table: String) throws -> Set<String> {
            tables.contains(table) ? Set(try db.rows("PRAGMA table_info(\(q(table)))").compactMap { $0[1] }) : []
        }
        guard let assetTable = ["ZASSET", "ZGENERICASSET"].first(where: tables.contains) else {
            throw PhotosDatabaseError(kind: .unrecognisedSchema,
                                      message: "This library's database has no asset table Winnow recognises.")
        }
        let a = try columns(assetTable)
        let c = try columns("ZCOMPUTEDASSETATTRIBUTES")
        let m = try columns("ZMEDIAANALYSISASSETATTRIBUTES")
        func pick(_ alias: String, _ available: Set<String>, _ name: String) -> String {
            available.contains(name) ? "\(alias).\(q(name))" : "NULL"
        }
        var joins = ""
        if c.contains("ZASSET") { joins += " LEFT JOIN ZCOMPUTEDASSETATTRIBUTES c ON c.ZASSET = a.Z_PK" }
        if m.contains("ZASSET") { joins += " LEFT JOIN ZMEDIAANALYSISASSETATTRIBUTES m ON m.ZASSET = a.Z_PK" }
        let cc = c.contains("ZASSET") ? c : [], mm = m.contains("ZASSET") ? m : []
        var filters: [String] = []
        if a.contains("ZKIND") { filters.append("a.ZKIND = 0") }
        if a.contains("ZTRASHEDSTATE") { filters.append("a.ZTRASHEDSTATE = 0") }
        let sql = """
            SELECT a.ZUUID, \(pick("a", a, "ZOVERALLAESTHETICSCORE")), \(pick("a", a, "ZCURATIONSCORE")),
                   \(pick("c", cc, "ZFAILURESCORE")), \(pick("c", cc, "ZNOISESCORE")),
                   \(pick("m", mm, "ZBLURRINESSSCORE")), \(pick("m", mm, "ZEXPOSURESCORE")),
                   \(pick("c", cc, "ZSHARPLYFOCUSEDSUBJECTSCORE")), \(pick("c", cc, "ZPLEASANTCOMPOSITIONSCORE")),
                   \(pick("c", cc, "ZPLEASANTLIGHTINGSCORE")), \(pick("c", cc, "ZTASTEFULLYBLURREDSCORE"))
            FROM \(q(assetTable)) a\(joins)
            \(filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND "))
            """
        var out: [String: AppleScores] = [:]
        try db.forEachRow(sql) { stmt in
            guard let uuid = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { return }
            func d(_ i: Int32) -> Double? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i) }
            out[uuid] = AppleScores(overall: d(1), curation: d(2), failure: d(3), noise: d(4), blurriness: d(5),
                                    exposure: d(6), sharpSubject: d(7), composition: d(8), lighting: d(9),
                                    tastefullyBlurred: d(10))
        }
        return out
    }
}

// MARK: - File details

/// What Photos records about a photo and its original file, for showing file details and for the
/// keeper rules (KeeperRules). nil = not in this macOS version's schema.
public struct FileInfo: Sendable, Equatable {
    public var width: Int?
    public var height: Int?
    public var bytes: Int?
    public var filename: String?
    /// The original is a camera RAW file (CR2, NEF, DNG, ARW…), from its file type in Photos.
    public var isRaw = false
    public var isHEIC = false
    public var favorite = false
    /// Stars in Photos, 0–5.
    public var rating = 0
    public var portrait = false
    public var hdr = false
    public var live = false
    public var hasLocation = false
    public var hasTitle = false
    public var hasCaption = false
    public var hasKeywords = false
    /// In one of your albums (not shared or smart albums, not Winnow's Rejected album).
    public var inAlbum = false
    /// Camera make or model recorded.
    public var hasCameraMetadata = false
    /// The original is a file outside the library.
    public var referenced = false
    /// The original isn't on this Mac (only in iCloud, or a referenced file that's gone).
    public var missing = false
    /// Seconds since 2001, as Photos stores them.
    public var captureDate: Double?
    public var addedDate: Double?
    public var modifiedDate: Double?

    public init(width: Int? = nil, height: Int? = nil, bytes: Int? = nil, filename: String? = nil,
                isRaw: Bool = false) {
        self.width = width
        self.height = height
        self.bytes = bytes
        self.filename = filename
        self.isRaw = isRaw
    }

    public var pixels: Int? { width.flatMap { w in height.map { w * $0 } } }

    /// Photos' file type names RAW formats "….raw-image" (com.canon.cr2-raw-image, com.adobe.raw-image).
    public static func isRawType(_ uti: String) -> Bool {
        uti.hasSuffix("raw-image") || uti == "public.camera-raw-image"
    }
}

extension PhotosDatabase {
    /// Every photo's file details and keeper-rule facts, keyed by ZUUID. One read-only query, about
    /// a second for 200,000 photos. Anything this macOS version's schema lacks is left unknown.
    public static func readFileInfo(inLibrary library: URL) throws -> [String: FileInfo] {
        let path = library.appendingPathComponent("database/Photos.sqlite").path
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw PhotosDatabaseError(kind: .noAccess, message: "Winnow can't read this library's database.")
        }
        let db = try Database(liveReadOnly: path)
        let tables = Set(try db.column("SELECT name FROM sqlite_master WHERE type = 'table'"))
        guard let assetTable = ["ZASSET", "ZGENERICASSET"].first(where: tables.contains) else {
            throw PhotosDatabaseError(kind: .unrecognisedSchema,
                                      message: "This library's database has no asset table Winnow recognises.")
        }
        func columns(_ table: String) throws -> Set<String> {
            tables.contains(table) ? Set(try db.rows("PRAGMA table_info(\(q(table)))").compactMap { $0[1] }) : []
        }
        let a = try columns(assetTable)
        let x = try columns("ZADDITIONALASSETATTRIBUTES")
        let xx = x.contains("ZASSET") ? x : []
        let e = a.contains("ZEXTENDEDATTRIBUTES") ? try columns("ZEXTENDEDATTRIBUTES") : []
        let d = xx.contains("ZASSETDESCRIPTION") ? try columns("ZASSETDESCRIPTION") : []
        let r = try columns("ZINTERNALRESOURCE")
        let g = try columns("ZGENERICALBUM")
        func pick(_ alias: String, _ available: Set<String>, _ name: String) -> String {
            available.contains(name) ? "\(alias).\(q(name))" : "NULL"
        }
        func has(_ alias: String, _ available: Set<String>, _ name: String) -> String {
            available.contains(name) ? "(\(alias).\(q(name)) IS NOT NULL AND \(alias).\(q(name)) != '')" : "0"
        }
        // Join tables are numbered by entity, and the numbers change between macOS versions:
        // find the album↔asset table (Z_nnALBUMS, Z_nASSETS) and the keyword one (Z_nASSETATTRIBUTES).
        var albumJoin: (table: String, album: String, asset: String)?
        var keywordJoin: (table: String, attributes: String)?
        for t in tables.sorted() where t.hasPrefix("Z_") {
            let cols = try columns(t)
            if t.hasSuffix("ASSETS"), let album = cols.first(where: { $0.hasSuffix("ALBUMS") && !$0.hasPrefix("Z_FOK") }),
               let asset = cols.first(where: { $0.hasSuffix("ASSETS") && !$0.hasPrefix("Z_FOK") }) {
                albumJoin = (t, album, asset)
            }
            if t.hasSuffix("KEYWORDS"), let attrs = cols.first(where: { $0.hasSuffix("ASSETATTRIBUTES") }) {
                keywordJoin = (t, attrs)
            }
        }

        var joins = xx.isEmpty ? "" : " LEFT JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK"
        if !e.isEmpty { joins += " LEFT JOIN ZEXTENDEDATTRIBUTES e ON e.Z_PK = a.ZEXTENDEDATTRIBUTES" }
        if !d.isEmpty { joins += " LEFT JOIN ZASSETDESCRIPTION d ON d.Z_PK = x.ZASSETDESCRIPTION" }
        let present = r.contains("ZLOCALAVAILABILITY") && r.contains("ZRESOURCETYPE")
            ? "EXISTS (SELECT 1 FROM ZINTERNALRESOURCE r WHERE r.ZASSET = a.Z_PK AND r.ZRESOURCETYPE = 0 AND r.ZLOCALAVAILABILITY = 1)"
            : "1"
        let referenced = r.contains("ZFILESYSTEMBOOKMARK")
            ? "EXISTS (SELECT 1 FROM ZINTERNALRESOURCE r WHERE r.ZASSET = a.Z_PK AND r.ZFILESYSTEMBOOKMARK IS NOT NULL)"
            : "0"
        let inAlbum = albumJoin.map { j in
            g.contains("ZKIND") && g.contains("ZTITLE")
                ? """
                  EXISTS (SELECT 1 FROM \(q(j.table)) j JOIN ZGENERICALBUM g ON g.Z_PK = j.\(q(j.album))
                          WHERE j.\(q(j.asset)) = a.Z_PK AND g.ZKIND = 2 AND COALESCE(g.ZTRASHEDSTATE, 0) = 0
                            AND COALESCE(g.ZTITLE, '') != ?)
                  """
                : "0"
        } ?? "0"
        let hasKeywords = (keywordJoin.map { j in
            xx.isEmpty ? "0" : "EXISTS (SELECT 1 FROM \(q(j.table)) k WHERE k.\(q(j.attributes)) = x.Z_PK)"
        }) ?? "0"
        let location = a.contains("ZLATITUDE") ? "(a.ZLATITUDE IS NOT NULL AND a.ZLATITUDE != -180)" : "0"
        let camera = e.isEmpty ? "0" : "(\(has("e", e, "ZCAMERAMAKE")) OR \(has("e", e, "ZCAMERAMODEL")))"

        // Original dimensions where recorded (an edit can change the current ones), else current.
        let sql = """
            SELECT a.ZUUID,
                   COALESCE(\(pick("x", xx, "ZORIGINALWIDTH")), \(pick("a", a, "ZWIDTH"))),
                   COALESCE(\(pick("x", xx, "ZORIGINALHEIGHT")), \(pick("a", a, "ZHEIGHT"))),
                   \(pick("x", xx, "ZORIGINALFILESIZE")), \(pick("x", xx, "ZORIGINALFILENAME")),
                   \(pick("a", a, "ZUNIFORMTYPEIDENTIFIER")),
                   \(pick("a", a, "ZFAVORITE")), \(pick("a", a, "ZRATING")), \(pick("a", a, "ZDEPTHTYPE")),
                   \(pick("a", a, "ZHDRTYPE")), \(pick("a", a, "ZKINDSUBTYPE")),
                   \(location), \(has("x", xx, "ZTITLE")), \(has("d", d, "ZLONGDESCRIPTION")), \(hasKeywords),
                   \(inAlbum), \(camera), \(referenced), \(present),
                   \(pick("a", a, "ZDATECREATED")), \(pick("a", a, "ZADDEDDATE")), \(pick("a", a, "ZMODIFICATIONDATE"))
            FROM \(q(assetTable)) a\(joins)
            \(a.contains("ZKIND") ? "WHERE a.ZKIND = 0" : "")
            """
        var out: [String: FileInfo] = [:]
        try db.forEachRow(sql, inAlbum == "0" ? [] : [rejectAlbumTitle]) { stmt in
            guard let uuid = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { return }
            func null(_ c: Int32) -> Bool { sqlite3_column_type(stmt, c) == SQLITE_NULL }
            func i(_ c: Int32) -> Int? { null(c) ? nil : Int(sqlite3_column_int64(stmt, c)) }
            func b(_ c: Int32) -> Bool { (i(c) ?? 0) != 0 }
            func t(_ c: Int32) -> String? { sqlite3_column_text(stmt, c).map { String(cString: $0) } }
            func f(_ c: Int32) -> Double? { null(c) ? nil : sqlite3_column_double(stmt, c) }
            var info = FileInfo(width: i(1), height: i(2), bytes: i(3), filename: t(4),
                                isRaw: t(5).map(FileInfo.isRawType) ?? false)
            info.isHEIC = t(5) == "public.heic"
            info.favorite = b(6)
            info.rating = i(7) ?? 0
            info.portrait = (i(8) ?? 0) > 0
            info.hdr = hdrTypes.contains(i(9) ?? 0)
            info.live = i(10) == 2
            info.hasLocation = b(11)
            info.hasTitle = b(12)
            info.hasCaption = b(13)
            info.hasKeywords = b(14)
            info.inAlbum = b(15)
            info.hasCameraMetadata = b(16)
            info.referenced = b(17)
            info.missing = !b(18)
            info.captureDate = f(19)
            info.addedDate = f(20)
            info.modifiedDate = f(21)
            out[uuid] = info
        }
        return out
    }

    /// Winnow's own album of rejected photos, which doesn't count as "added to an album".
    public static let rejectAlbumTitle = "Winnow – Rejected"
    /// ZHDRTYPE values PhotoKit reports as HDR (checked against mediaSubtypes; 4 and 10 aren't).
    static let hdrTypes: Set<Int> = [2, 3]
}

/// What Photos' face analysis says about a photo's main faces: the biggest one, and any at least
/// half its size (people in the background don't count).
public struct FaceInfo: Sendable, Equatable {
    /// Some main face has its eyes closed or out of sight (a blink, but also looking down or laughing).
    public var eyesClosed: Bool
    /// Photos' face capture quality, 0…1, of the worst main face.
    public var quality: Double?

    public init(eyesClosed: Bool, quality: Double? = nil) {
        self.eyesClosed = eyesClosed
        self.quality = quality
    }
}

extension PhotosDatabase {
    /// Smallest face counted, as a fraction of the photo's width.
    public static let mainFaceSize = 0.03

    /// Faces for every photo Photos has analysed faces in, keyed by UUID. Empty when the library's
    /// database has no face table Winnow recognises.
    public static func readFaceInfo(inLibrary library: URL) throws -> [String: FaceInfo] {
        let path = library.appendingPathComponent("database/Photos.sqlite").path
        let db = try Database(liveReadOnly: path)
        let tables = Set(try db.column("SELECT name FROM sqlite_master WHERE type = 'table'"))
        guard let assetTable = ["ZASSET", "ZGENERICASSET"].first(where: tables.contains),
              tables.contains("ZDETECTEDFACE") else { return [:] }
        let f = Set(try db.rows("PRAGMA table_info(ZDETECTEDFACE)").compactMap { $0[1] })
        guard f.isSuperset(of: ["ZASSETFORFACE", "ZSIZE", "ZEYESSTATE", "ZQUALITY"]) else { return [:] }
        // ZEYESSTATE: 0 not analysed, 1 closed, 2 open. ZDETECTIONTYPE 1 is a person (others are pets).
        let sql = """
            WITH face AS (
                SELECT ZASSETFORFACE AS asset, ZSIZE AS size, ZEYESSTATE AS eyes, ZQUALITY AS quality,
                       MAX(ZSIZE) OVER (PARTITION BY ZASSETFORFACE) AS biggest
                FROM ZDETECTEDFACE
                WHERE ZASSETFORFACE IS NOT NULL\(f.contains("ZDETECTIONTYPE") ? " AND ZDETECTIONTYPE = 1" : "")
            )
            SELECT a.ZUUID, MAX(face.eyes = 1), MIN(CASE WHEN face.quality >= 0 THEN face.quality END)
            FROM face JOIN \(q(assetTable)) a ON a.Z_PK = face.asset
            WHERE face.size >= face.biggest * 0.5 AND face.size >= \(mainFaceSize) AND face.eyes != 0
            GROUP BY a.ZUUID
            """
        var out: [String: FaceInfo] = [:]
        try db.forEachRow(sql) { stmt in
            guard let uuid = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { return }
            out[uuid] = FaceInfo(eyesClosed: sqlite3_column_int(stmt, 1) == 1,
                                 quality: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2))
        }
        return out
    }
}
