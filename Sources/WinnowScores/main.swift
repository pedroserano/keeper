// winnow-scores — Phase 0 spike for reading Apple Photos' own scores.
//
// Never opens the live library database: it copies Photos.sqlite (+ -wal/-shm) to a
// temporary folder, opens the copy read-only, and deletes the copy when done.
//
//   winnow-scores schema  [--library PATH]                 list score columns + stats, save a schema map
//   winnow-scores export  [--library PATH] [--out FILE]    CSV of uuid + every per-asset score column
//   winnow-scores compare PHOTOS.csv VISION.csv [--column NAME]   rank agreement with Vision scores

import Foundation
import SQLite3

struct Fail: Error, CustomStringConvertible { let description: String }

// MARK: - SQLite

final class Database {
    private let handle: OpaquePointer

    init(readOnly path: String) throws {
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let h else {
            throw Fail(description: "Cannot open \(path)")
        }
        handle = h
    }

    deinit { sqlite3_close(handle) }

    func rows(_ sql: String) throws -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Fail(description: "SQL error: \(String(cString: sqlite3_errmsg(handle)))\n\(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        var out: [[String?]] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<n).map { i in
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            })
        }
        return out
    }

    func column(_ sql: String) throws -> [String] { try rows(sql).compactMap { $0.first ?? nil } }
}

func q(_ identifier: String) -> String { "\"\(identifier)\"" }

// MARK: - Library snapshot

func defaultLibrary() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Photos Library.photoslibrary")
}

/// Copies the database files so the live library is never opened.
func snapshot(library: URL) throws -> (db: URL, cleanup: () -> Void) {
    let fm = FileManager.default
    let src = library.appendingPathComponent("database/Photos.sqlite")
    guard fm.fileExists(atPath: library.path) else {
        throw Fail(description: "No library at \(library.path). Pass --library PATH.")
    }
    guard fm.isReadableFile(atPath: src.path) else {
        throw Fail(description: """
            Can't read \(src.path).
            Give Full Disk Access to the app running this tool \
            (System Settings › Privacy & Security › Full Disk Access).
            """)
    }
    let dir = fm.temporaryDirectory.appendingPathComponent("winnow-snapshot-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: src.path + suffix) {
        try fm.copyItem(atPath: src.path + suffix, toPath: dir.appendingPathComponent("Photos.sqlite" + suffix).path)
    }
    return (dir.appendingPathComponent("Photos.sqlite"), { try? fm.removeItem(at: dir) })
}

// MARK: - Schema discovery

struct ScoreTable {
    let name: String
    let scoreColumns: [String]
    /// Column holding the asset's Z_PK, or nil if the table can't be joined one row per asset.
    let assetKey: String?
}

struct Schema {
    let assetTable: String
    let assetColumns: Set<String>
    let tables: [ScoreTable]
}

func discover(_ db: Database) throws -> Schema {
    let tables = try db.column("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    guard let assetTable = ["ZASSET", "ZGENERICASSET"].first(where: tables.contains) else {
        throw Fail(description: "No asset table (ZASSET / ZGENERICASSET) — unrecognised schema.")
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
            // Only join tables with at most one row per asset, or the export would duplicate rows.
            let counts = try db.rows("SELECT COUNT(ZASSET), COUNT(DISTINCT ZASSET) FROM \(q(table))")
            if let row = counts.first, row[0] == row[1] { key = "ZASSET" }
        }
        found.append(ScoreTable(name: table, scoreColumns: scores, assetKey: key))
    }
    return Schema(assetTable: assetTable, assetColumns: assetColumns, tables: found)
}

/// WHERE clause limiting rows to live still photos, using whichever columns this schema has.
func photoFilter(_ schema: Schema) -> String {
    var parts: [String] = []
    if schema.assetColumns.contains("ZKIND") { parts.append("a.ZKIND = 0") }
    if schema.assetColumns.contains("ZTRASHEDSTATE") { parts.append("a.ZTRASHEDSTATE = 0") }
    return parts.isEmpty ? "" : "WHERE " + parts.joined(separator: " AND ")
}

// MARK: - Commands

func osVersion() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

func runSchema(library: URL) throws {
    let snap = try snapshot(library: library)
    defer { snap.cleanup() }
    let db = try Database(readOnly: snap.db.path)
    let schema = try discover(db)

    let photoCount = try db.column("SELECT COUNT(*) FROM \(q(schema.assetTable)) a \(photoFilter(schema))").first ?? "?"
    print("macOS \(osVersion()) · asset table \(schema.assetTable) · \(photoCount) photos\n")

    var map: [[String: Any]] = []
    for table in schema.tables {
        let joinNote = table.assetKey.map { "joins on \($0)" } ?? "not one row per asset — skipped in export"
        print("\(table.name)  (\(joinNote))")
        for column in table.scoreColumns {
            let c = q(column)
            let stats = try db.rows("SELECT COUNT(\(c)), MIN(\(c)), MAX(\(c)), AVG(\(c)) FROM \(q(table.name))").first ?? []
            let s = stats.map { $0 ?? "–" }
            print("  \(column.padding(toLength: 40, withPad: " ", startingAt: 0)) n=\(s[0])  min=\(s[1])  max=\(s[2])  avg=\(s[3])")
            map.append(["table": table.name, "column": column, "assetKey": table.assetKey ?? NSNull(),
                        "nonNull": Int(s[0]) ?? 0])
        }
    }

    let out = URL(fileURLWithPath: "out/score-schema-macos-\(osVersion()).json")
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    let json: [String: Any] = ["macOS": osVersion(), "assetTable": schema.assetTable, "columns": map]
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: out)
    print("\nSaved schema map to \(out.path)")
}

func runExport(library: URL, out: URL) throws {
    let snap = try snapshot(library: library)
    defer { snap.cleanup() }
    let db = try Database(readOnly: snap.db.path)
    let schema = try discover(db)

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
    let sql = "SELECT \(select.joined(separator: ", ")) FROM \(q(schema.assetTable)) a \(joins.joined(separator: " ")) \(photoFilter(schema))"
    let rows = try db.rows(sql)

    var csv = header.joined(separator: ",") + "\n"
    for row in rows { csv += row.map { $0 ?? "" }.joined(separator: ",") + "\n" }
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try csv.write(to: out, atomically: true, encoding: .utf8)
    print("Exported \(rows.count) photos × \(header.count - 1) score columns to \(out.path)")
}

func readCSV(_ path: String) throws -> (header: [String], rows: [[String]]) {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var lines = text.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    guard !lines.isEmpty else { throw Fail(description: "\(path) is empty") }
    let header = lines.removeFirst()
    return (header, lines)
}

/// Spearman rank correlation (average ranks for ties).
func spearman(_ pairs: [(Double, Double)]) -> Double {
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

func runCompare(photosCSV: String, visionCSV: String, column: String?) throws {
    let photos = try readCSV(photosCSV)
    let vision = try readCSV(visionCSV)
    guard let pc = column.flatMap({ photos.header.firstIndex(of: $0) })
            ?? photos.header.firstIndex(where: { $0.uppercased().contains("OVERALLAESTHETIC") }) else {
        throw Fail(description: "No overall aesthetic column in \(photosCSV); pass --column. Columns: \(photos.header.dropFirst().joined(separator: ", "))")
    }
    guard let vc = vision.header.firstIndex(of: "overall") else {
        throw Fail(description: "\(visionCSV) has no 'overall' column")
    }

    var photoScore: [String: Double] = [:]
    for row in photos.rows where row.count > pc { photoScore[row[0]] = Double(row[pc]) }
    var pairs: [(Double, Double)] = []
    for row in vision.rows where row.count > vc {
        if let p = photoScore[row[0]], let v = Double(row[vc]) { pairs.append((p, v)) }
    }
    guard pairs.count >= 10 else {
        throw Fail(description: "Only \(pairs.count) photos appear in both files with scores; need at least 10.")
    }

    // How many of Photos' bottom 20% Vision also puts in its bottom 20% — the "suggested rejects" overlap.
    let k = max(1, pairs.count / 5)
    let byPhotos = Set(pairs.indices.sorted { pairs[$0].0 < pairs[$1].0 }.prefix(k))
    let byVision = Set(pairs.indices.sorted { pairs[$0].1 < pairs[$1].1 }.prefix(k))

    print("Column: \(photos.header[pc])")
    print("Photos in both files: \(pairs.count)")
    print(String(format: "Spearman rank correlation: %.2f", spearman(pairs)))
    print(String(format: "Bottom-20%% overlap: %d of %d (%.0f%%)", byPhotos.intersection(byVision).count, k,
                 100 * Double(byPhotos.intersection(byVision).count) / Double(k)))
}

// MARK: - Entry point

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
let library = option("--library", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultLibrary()

do {
    switch args.first {
    case "schema":
        try runSchema(library: library)
    case "export":
        try runExport(library: library, out: URL(fileURLWithPath: option("--out", in: args) ?? "out/photos-scores.csv"))
    case "compare" where args.count >= 3:
        try runCompare(photosCSV: args[1], visionCSV: args[2], column: option("--column", in: args))
    default:
        print("""
            usage: winnow-scores schema  [--library PATH]
                   winnow-scores export  [--library PATH] [--out FILE]
                   winnow-scores compare PHOTOS.csv VISION.csv [--column TABLE.COLUMN]
            """)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
