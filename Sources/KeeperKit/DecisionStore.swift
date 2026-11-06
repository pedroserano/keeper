// Keeper's own database: one per Photos library, under Application Support.
// Photos is never written here; this only holds what Photos has no field for (stars, flags, progress).

import Foundation
import GRDB

public final class DecisionStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// For tests.
    public init() throws {
        dbQueue = try DatabaseQueue()
        try Self.migrator.migrate(dbQueue)
    }

    /// The store for a library, named after it plus a hash of its path so two libraries never share one.
    /// The app's folder under Application Support (and Caches).
    public static let folderName = "Keeper"

    /// Where every library's store lives.
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public static func url(forLibrary library: URL) -> URL {
        let name = library.deletingPathExtension().lastPathComponent
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a, stable across launches unlike hashValue
        for byte in library.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return directory.appendingPathComponent("\(name)-\(String(hash, radix: 16)).sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "decision") { t in
                t.primaryKey("assetID", .text)
                t.column("cloudID", .text)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("flag", .text).notNull().defaults(to: Flag.none.rawValue)
                t.column("hidden", .boolean).notNull().defaults(to: false)
                t.column("originalFavorite", .boolean)
                t.column("seenAt", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "decision_flag", on: "decision", columns: ["flag"])
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
        }
        m.registerMigration("v2-feature-prints") { db in
            // Vision feature prints for duplicate and similar-shot detection, computed once per photo.
            try db.create(table: "featurePrint") { t in
                t.primaryKey("uuid", .text)
                t.column("vector", .blob).notNull()
            }
        }
        m.registerMigration("v3-merged-albums") { db in
            // Albums a merge added a photo to (JSON), so undo can take it out of exactly those.
            try db.alter(table: "decision") { t in t.add(column: "addedAlbums", .text) }
        }
        m.registerMigration("v4-orientation") { db in
            // Sideways Photos: each photo's orientation check, so a scan picks up where it stopped.
            try db.create(table: "orientation") { t in
                t.primaryKey("assetID", .text)
                t.column("modDate", .double).notNull()
                t.column("status", .integer).notNull()
                t.column("rotation", .integer).notNull()
                t.column("confidence", .double).notNull()
                t.column("evidence", .text).notNull()
                t.column("hidden", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "orientation_status", on: "orientation", columns: ["status"])
        }
        return m
    }

    public func all() throws -> [String: Decision] {
        try dbQueue.read { db in
            Dictionary(uniqueKeysWithValues: try Decision.fetchAll(db).map { ($0.assetID, $0) })
        }
    }

    public func save(_ decisions: [Decision]) throws {
        try dbQueue.write { db in
            for d in decisions { try d.save(db) }
        }
    }

    public func rejected() throws -> [Decision] {
        try dbQueue.read { db in
            try Decision.filter(Column("flag") == Flag.reject.rawValue).fetchAll(db)
        }
    }

    public func remove(_ assetIDs: [String]) throws {
        _ = try dbQueue.write { db in try Decision.deleteAll(db, keys: assetIDs) }
    }

    // MARK: Feature prints

    public func featurePrintUUIDs() throws -> Set<String> {
        try dbQueue.read { db in Set(try String.fetchAll(db, sql: "SELECT uuid FROM featurePrint")) }
    }

    public func saveFeaturePrints(_ prints: [String: FeatureVector]) throws {
        try dbQueue.write { db in
            for (uuid, v) in prints {
                try db.execute(sql: "INSERT OR REPLACE INTO featurePrint (uuid, vector) VALUES (?, ?)",
                               arguments: [uuid, v.quantized])
            }
        }
    }

    public func featurePrints(for uuids: Set<String>) throws -> [String: FeatureVector] {
        try dbQueue.read { db in
            var out: [String: FeatureVector] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT uuid, vector FROM featurePrint")
            while let row = try rows.next() {
                let uuid: String = row["uuid"]
                guard uuids.contains(uuid), let v = FeatureVector(quantized: row["vector"]) else { continue }
                out[uuid] = v
            }
            return out
        }
    }

    // MARK: Orientation (Sideways Photos)

    /// Photos already checked, with the modification date they had then.
    public func orientationScanned() throws -> [String: Double] {
        try dbQueue.read { db in
            var out: [String: Double] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT assetID, modDate FROM orientation")
            while let row = try rows.next() { out[row["assetID"]] = row["modDate"] }
            return out
        }
    }

    /// A new check replaces the old one, and shows the photo again if it still looks sideways.
    public func saveOrientation(_ records: [OrientationRecord]) throws {
        try dbQueue.write { db in
            for r in records { try r.save(db) }
        }
    }

    /// Photos that look sideways and haven't been rotated or dismissed, surest first.
    public func orientationProposals(minConfidence: Double = 0) throws -> [OrientationRecord] {
        try dbQueue.read { db in
            try OrientationRecord
                .filter(Column("status") == ScanStatus.needsRotation.rawValue && Column("hidden") == false
                        && Column("confidence") >= minConfidence)
                .order(Column("confidence").desc)
                .fetchAll(db)
        }
    }

    public func orientationCounts() throws -> (checked: Int, sideways: Int) {
        try dbQueue.read { db in
            (try OrientationRecord.fetchCount(db),
             try OrientationRecord.filter(Column("status") == ScanStatus.needsRotation.rawValue).fetchCount(db))
        }
    }

    /// Hides photos from Sideways Photos (rotated, or not sideways after all), or shows them again.
    /// `modDates` updates the date a check was made against, for a photo turned back to how it was checked.
    public func setOrientationHidden(_ hidden: [String: Bool], modDates: [String: Double] = [:]) throws {
        try dbQueue.write { db in
            for (id, h) in hidden {
                try db.execute(sql: "UPDATE orientation SET hidden = ? WHERE assetID = ?", arguments: [h, id])
            }
            for (id, date) in modDates {
                try db.execute(sql: "UPDATE orientation SET modDate = ? WHERE assetID = ?", arguments: [date, id])
            }
        }
    }

    // MARK: Starting over

    /// Forgets the look-alike fingerprints and orientation checks, so both scans run again from the
    /// start. Rejects, picks and ticks stay.
    public func clearScans() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM featurePrint")
            try db.execute(sql: "DELETE FROM orientation")
        }
    }

    /// Deletes a store's files (the database and its journal), e.g. to start a library over.
    public static func deleteFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    public func setting(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
        }
    }

    public func setSetting(_ key: String, to value: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO setting (key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }
}

/// One photo's orientation check, keyed by its PhotoKit local identifier.
public struct OrientationRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "orientation"

    public var assetID: String
    /// The photo's modification date when it was checked; a different one later means it's out of date.
    public var modDate: Double
    public var status: ScanStatus
    public var rotation: Rotation
    public var confidence: Double
    /// Which cues decided, e.g. "faces 90°:0.97 · network 90°:0.71".
    public var evidence: String
    public var hidden: Bool

    public init(assetID: String, modDate: Double, status: ScanStatus, rotation: Rotation = .none,
                confidence: Double = 0, evidence: String = "", hidden: Bool = false) {
        self.assetID = assetID
        self.modDate = modDate
        self.status = status
        self.rotation = rotation
        self.confidence = confidence
        self.evidence = evidence
        self.hidden = hidden
    }
}
