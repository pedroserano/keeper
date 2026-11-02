// Winnow's own database: one per Photos library, under Application Support.
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
    public static func url(forLibrary library: URL) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = library.deletingPathExtension().lastPathComponent
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a, stable across launches unlike hashValue
        for byte in library.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return support.appendingPathComponent("Winnow/\(name)-\(String(hash, radix: 16)).sqlite")
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
