import Foundation
import SQLite3

/// How sure Photos is that a photo shows a painting, from its own scene labels, and how big the
/// largest face in it is (a photo mostly of someone isn't a photo of a painting).
public struct PaintingScore: Sendable, Equatable {
    /// 0…1, Photos' confidence in its "painting" scene label.
    public var painting: Double
    /// The largest face's size as Photos records it (ZSIZE), 0 without one.
    public var largestFace: Double

    public init(painting: Double, largestFace: Double) {
        self.painting = painting
        self.largestFace = largestFace
    }
}

extension PhotosDatabase {
    /// Photos' scene identifier for paintings. Found by matching Photos' stored labels with
    /// Vision's "painting" label on one library's photos: no other scene followed it as closely.
    public static let paintingSceneID = 15716

    /// Every photo Photos labelled as showing a painting, by UUID. One query, read-only.
    public static func readPaintingScores(inLibrary library: URL, atLeast minimum: Double = 0.3) throws -> [String: PaintingScore] {
        let path = library.appendingPathComponent("database/Photos.sqlite").path
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw PhotosDatabaseError(kind: .noAccess, message: "Keeper can't read this library's database.")
        }
        let db = try Database(liveReadOnly: path)
        let tables = Set(try db.column("SELECT name FROM sqlite_master WHERE type = 'table'"))
        guard let assetTable = ["ZASSET", "ZGENERICASSET"].first(where: tables.contains),
              tables.contains("ZSCENECLASSIFICATION"), tables.contains("ZADDITIONALASSETATTRIBUTES") else {
            throw PhotosDatabaseError(kind: .unrecognisedSchema, message: "This library's database has no scene labels Keeper recognises.")
        }
        func columns(_ t: String) throws -> Set<String> {
            tables.contains(t) ? Set(try db.rows("PRAGMA table_info(\(q(t)))").compactMap { $0[1] }) : []
        }
        let a = try columns(assetTable), s = try columns("ZSCENECLASSIFICATION"), f = try columns("ZDETECTEDFACE")
        guard s.isSuperset(of: ["ZSCENEIDENTIFIER", "ZCONFIDENCE", "ZASSETATTRIBUTES"]) else {
            throw PhotosDatabaseError(kind: .unrecognisedSchema, message: "This library's database stores scene labels differently.")
        }
        var filters = ["s.ZSCENEIDENTIFIER = \(paintingSceneID)", "s.ZCONFIDENCE >= \(minimum)"]
        if s.contains("ZCLASSIFICATIONTYPE") { filters.append("s.ZCLASSIFICATIONTYPE = 0") }
        if a.contains("ZKIND") { filters.append("a.ZKIND = 0") }
        if a.contains("ZTRASHEDSTATE") { filters.append("a.ZTRASHEDSTATE = 0") }
        let face = f.isSuperset(of: ["ZASSETFORFACE", "ZSIZE"])
            ? "(SELECT MAX(f.ZSIZE) FROM ZDETECTEDFACE f WHERE f.ZASSETFORFACE = a.Z_PK\(f.contains("ZHIDDEN") ? " AND COALESCE(f.ZHIDDEN, 0) = 0" : ""))"
            : "NULL"
        var out: [String: PaintingScore] = [:]
        try db.forEachRow("""
            SELECT a.ZUUID, MAX(s.ZCONFIDENCE), \(face)
            FROM ZSCENECLASSIFICATION s
            JOIN ZADDITIONALASSETATTRIBUTES b ON s.ZASSETATTRIBUTES = b.Z_PK
            JOIN \(q(assetTable)) a ON b.ZASSET = a.Z_PK
            WHERE \(filters.joined(separator: " AND "))
            GROUP BY a.Z_PK
            """) { stmt in
            guard let uuid = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { return }
            out[uuid] = PaintingScore(painting: sqlite3_column_double(stmt, 1), largestFace: sqlite3_column_double(stmt, 2))
        }
        return out
    }
}
