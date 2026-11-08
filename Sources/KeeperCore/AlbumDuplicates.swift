// Albums holding more than one exact copy of a photo: the same original file (Photos' own
// fingerprint of it, ZORIGINALSTABLEHASH), the same edit (ZADJUSTEDSTABLEHASH, or none), and the
// same rating and Favorite. Photos' Duplicates
// album isn't used: it also groups look-alikes (resized or edited versions), which aren't copies.
// Read-only: removing a copy from an album goes through PhotoKit, and never deletes a photo.

import Foundation
import SQLite3

/// One album and the copies it holds twice or more.
public struct AlbumDuplicates: Sendable, Hashable, Identifiable {
    /// The album's ZUUID (PhotoKit's local identifier is this plus "/L0/040").
    public var albumUUID: String
    public var title: String
    /// Each group's photos (ZUUIDs) in the album's own order: the first stays in the album, the
    /// rest come later in it and are the ones to remove.
    public var groups: [[String]]
    public var id: String { albumUUID }

    public init(albumUUID: String, title: String, groups: [[String]]) {
        self.albumUUID = albumUUID
        self.title = title
        self.groups = groups
    }

    /// The copies that would come out of the album.
    public var extras: [String] { groups.flatMap { $0.dropFirst() } }
}

extension PhotosDatabase {
    /// Your own albums that hold two or more exact copies of a photo. Empty if this library's
    /// database doesn't record original-file fingerprints.
    public static func readAlbumDuplicates(inLibrary library: URL) throws -> [AlbumDuplicates] {
        let path = library.appendingPathComponent("database/Photos.sqlite").path
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw PhotosDatabaseError(kind: .noAccess, message: "Keeper can't read this library's database.")
        }
        let db = try Database(liveReadOnly: path)
        let tables = Set(try db.column("SELECT name FROM sqlite_master WHERE type = 'table'"))
        guard let assetTable = ["ZASSET", "ZGENERICASSET"].first(where: tables.contains),
              tables.contains("ZGENERICALBUM") else { return [] }
        func columns(_ table: String) throws -> Set<String> {
            Set(try db.rows("PRAGMA table_info(\(q(table)))").compactMap { $0[1] })
        }
        let a = try columns(assetTable)
        let g = try columns("ZGENERICALBUM")
        let x = tables.contains("ZADDITIONALASSETATTRIBUTES") ? try columns("ZADDITIONALASSETATTRIBUTES") : []
        guard x.isSuperset(of: ["ZASSET", "ZORIGINALSTABLEHASH"]), a.contains("ZUUID"),
              g.isSuperset(of: ["ZKIND", "ZTITLE", "ZUUID"]) else { return [] }

        // The album↔asset join table is numbered by entity, and its order column (Z_FOK_…) gives
        // each photo's place in the album.
        var join: (table: String, album: String, asset: String, order: String)?
        for t in tables.sorted() where t.hasPrefix("Z_") && t.hasSuffix("ASSETS") {
            let cols = try columns(t)
            if let album = cols.first(where: { $0.hasSuffix("ALBUMS") && !$0.hasPrefix("Z_FOK") }),
               let asset = cols.first(where: { $0.hasSuffix("ASSETS") && !$0.hasPrefix("Z_FOK") }),
               let order = cols.first(where: { $0.hasPrefix("Z_FOK") && $0.hasSuffix("ASSETS") }) {
                join = (t, album, asset, order)
            }
        }
        guard let join else { return [] }

        // Same file, and the same rating and Favorite: copies Photos treats identically.
        let rating = a.contains("ZRATING") ? "COALESCE(a.ZRATING, 0)" : "0"
        let favorite = a.contains("ZFAVORITE") ? "COALESCE(a.ZFAVORITE, 0)" : "0"
        let size = x.contains("ZORIGINALFILESIZE") ? "COALESCE(x.ZORIGINALFILESIZE, 0)" : "0"
        // …and the same edit: crops of one scanned page share an original but are different
        // photos. Edited copies match only when Photos' fingerprint of the edited version is the
        // same; an edit Photos hasn't fingerprinted yet matches nothing.
        let edited = a.contains("ZADJUSTMENTSSTATE") ? "COALESCE(a.ZADJUSTMENTSSTATE, 0) > 0" : "0"
        let edit = x.contains("ZADJUSTEDSTABLEHASH")
            ? "CASE WHEN COALESCE(x.ZADJUSTEDSTABLEHASH, '') != '' THEN x.ZADJUSTEDSTABLEHASH WHEN \(edited) THEN 'unknown-' || a.ZUUID ELSE 'unedited' END"
            : "CASE WHEN \(edited) THEN 'unknown-' || a.ZUUID ELSE 'unedited' END"
        let orientation = a.contains("ZORIENTATION") ? "COALESCE(a.ZORIENTATION, 0)" : "0"
        let key = "x.ZORIGINALSTABLEHASH || '|' || \(size) || '|' || \(rating) || '|' || \(favorite) || '|' || \(edit) || '|' || \(orientation)"
        let trashed = a.contains("ZTRASHEDSTATE") ? " AND COALESCE(a.ZTRASHEDSTATE, 0) = 0" : ""
        let albumTrashed = g.contains("ZTRASHEDSTATE") ? " AND COALESCE(g.ZTRASHEDSTATE, 0) = 0" : ""
        let sql = """
            SELECT g.ZUUID, g.ZTITLE, \(key) AS dup, a.ZUUID
            FROM \(q(join.table)) j
            JOIN ZGENERICALBUM g ON g.Z_PK = j.\(q(join.album))
            JOIN \(q(assetTable)) a ON a.Z_PK = j.\(q(join.asset))
            JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK
            WHERE g.ZKIND = 2\(albumTrashed)\(trashed) AND x.ZORIGINALSTABLEHASH IS NOT NULL
              AND x.ZORIGINALSTABLEHASH != ''
              AND COALESCE(g.ZTITLE, '') NOT IN (?, ?)
            ORDER BY g.ZUUID, dup, j.\(q(join.order))
            """
        var titles: [String: String] = [:]
        var groups: [String: [String: [String]]] = [:]
        var albumOrder: [String] = []
        try db.forEachRow(sql, [rejectAlbumTitle, legacyRejectAlbumTitle]) { stmt in
            guard let album = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let asset = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) else { return }
            if titles[album] == nil {
                titles[album] = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "Untitled album"
                albumOrder.append(album)
            }
            guard let dup = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) else { return }
            groups[album, default: [:]][dup, default: []].append(asset)
        }
        return albumOrder.compactMap { album in
            let found = (groups[album] ?? [:]).values.filter { $0.count > 1 }
                .sorted { ($0.first ?? "") < ($1.first ?? "") }
            guard !found.isEmpty else { return nil }
            return AlbumDuplicates(albumUUID: album, title: titles[album] ?? "Untitled album", groups: found)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
