// Read-only access to an Apple Photos library's own database (Photos.sqlite).
//
// Two ways in, neither of which ever writes to a library (all changes go through PhotoKit):
// - `PhotosDatabase` copies Photos.sqlite (+ -wal/-shm) to a temporary folder and reads the copy.
//   Thorough but slow for big libraries; the spike uses it to survey every score column.
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
