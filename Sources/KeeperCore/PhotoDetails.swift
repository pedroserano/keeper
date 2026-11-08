// What Get Info (⌘I) shows beyond PhotoKit: the camera, lens and exposure, the original file's
// name and size, and the title and caption you gave the photo in Photos. One read-only query for
// one photo. Anything this macOS version's database lacks is left out.

import Foundation
import SQLite3

public struct PhotoDetails: Sendable, Equatable {
    public var originalFilename: String?
    public var bytes: Int?
    public var width: Int?
    public var height: Int?
    public var title: String?
    public var caption: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    /// Millimetres.
    public var focalLength: Double?
    public var focalLength35: Double?
    /// f-number.
    public var aperture: Double?
    /// Seconds.
    public var shutterSpeed: Double?
    public var iso: Int?
    public var exposureBias: Double?
    public var flashFired: Bool?
    public var timeZone: String?
    /// Seconds since 2001, as Photos stores them.
    public var addedDate: Double?
    public var importedBy: String?

    public init() {}

    /// "Canon EOS R5", without the make twice ("Canon Canon EOS R5").
    public var camera: String? {
        switch (cameraMake, cameraModel) {
        case let (make?, model?): model.localizedCaseInsensitiveContains(make.split(separator: " ").first.map(String.init) ?? make) ? model : "\(make) \(model)"
        case let (make?, nil): make
        case let (nil, model?): model
        default: nil
        }
    }

    /// "1/250 s", "2 s".
    public var shutterText: String? {
        guard let s = shutterSpeed, s > 0 else { return nil }
        if s >= 1 { return "\(s.formatted(.number.precision(.fractionLength(0...1)))) s" }
        return "1/\(Int((1 / s).rounded())) s"
    }

    /// "26 mm · ƒ/1.6 · 1/120 s · ISO 50".
    public var exposureText: String? {
        var parts: [String] = []
        if let f = focalLength, f > 0 {
            var text = "\(f.formatted(.number.precision(.fractionLength(0...1)))) mm"
            if let f35 = focalLength35, f35 > 0, Int(f35.rounded()) != Int(f.rounded()) { text += " (\(Int(f35.rounded())) mm equiv.)" }
            parts.append(text)
        }
        if let a = aperture, a > 0 { parts.append("ƒ/\(a.formatted(.number.precision(.fractionLength(0...1))))") }
        if let s = shutterText { parts.append(s) }
        if let iso, iso > 0 { parts.append("ISO \(iso)") }
        if let ev = exposureBias, abs(ev) >= 0.05 { parts.append("\(ev > 0 ? "+" : "")\(ev.formatted(.number.precision(.fractionLength(0...1)))) EV") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension PhotosDatabase {
    /// Get Info's details for the photo with this ZUUID, or nil if the database doesn't have it.
    public static func readPhotoDetails(uuid: String, inLibrary library: URL) throws -> PhotoDetails? {
        let path = library.appendingPathComponent("database/Photos.sqlite").path
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw PhotosDatabaseError(kind: .noAccess, message: "Keeper can't read this library's database.")
        }
        let db = try Database(liveReadOnly: path)
        let tables = Set(try db.column("SELECT name FROM sqlite_master WHERE type = 'table'"))
        guard let assetTable = ["ZASSET", "ZGENERICASSET"].first(where: tables.contains) else { return nil }
        func columns(_ table: String) throws -> Set<String> {
            tables.contains(table) ? Set(try db.rows("PRAGMA table_info(\(q(table)))").compactMap { $0[1] }) : []
        }
        let a = try columns(assetTable)
        let x = try columns("ZADDITIONALASSETATTRIBUTES")
        let e = try columns("ZEXTENDEDATTRIBUTES")
        let d = try columns("ZASSETDESCRIPTION")
        guard a.contains("ZUUID") else { return nil }

        // Each wanted value as "table alias.column", or NULL when this schema lacks it.
        var fields: [String] = []
        func pick(_ alias: String, _ have: Set<String>, _ column: String) {
            fields.append(have.contains(column) ? "\(alias).\(q(column))" : "NULL")
        }
        pick("x", x, "ZORIGINALFILENAME"); pick("x", x, "ZORIGINALFILESIZE")
        pick("x", x, "ZORIGINALWIDTH"); pick("x", x, "ZORIGINALHEIGHT")
        pick("x", x, "ZTITLE"); pick("d", d, "ZLONGDESCRIPTION")
        pick("e", e, "ZCAMERAMAKE"); pick("e", e, "ZCAMERAMODEL"); pick("e", e, "ZLENSMODEL")
        pick("e", e, "ZFOCALLENGTH"); pick("e", e, "ZFOCALLENGTHIN35MM"); pick("e", e, "ZAPERTURE")
        pick("e", e, "ZSHUTTERSPEED"); pick("e", e, "ZISO"); pick("e", e, "ZEXPOSUREBIAS")
        pick("e", e, "ZFLASHFIRED"); pick("x", x, "ZTIMEZONENAME"); pick("a", a, "ZADDEDDATE")
        pick("x", x, "ZIMPORTEDBYDISPLAYNAME")

        var joins = ""
        if x.contains("ZASSET") { joins += " LEFT JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK" }
        if e.contains("ZASSET") { joins += " LEFT JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK" }
        if x.contains("ZASSET"), d.contains("ZASSETATTRIBUTES") { joins += " LEFT JOIN ZASSETDESCRIPTION d ON d.ZASSETATTRIBUTES = x.Z_PK" }
        // A column from a table that wasn't joined can't be named.
        if !joins.contains(" x ") { fields = fields.map { $0.hasPrefix("x.") || $0.hasPrefix("d.") ? "NULL" : $0 } }
        if !joins.contains(" e ") { fields = fields.map { $0.hasPrefix("e.") ? "NULL" : $0 } }
        if !joins.contains(" d ") { fields = fields.map { $0.hasPrefix("d.") ? "NULL" : $0 } }

        let sql = "SELECT \(fields.joined(separator: ", ")) FROM \(q(assetTable)) a\(joins) WHERE a.ZUUID = ? LIMIT 1"
        var out: PhotoDetails?
        try db.forEachRow(sql, [uuid]) { stmt in
            func text(_ i: Int32) -> String? {
                guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
                let s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
            func number(_ i: Int32) -> Double? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
            }
            var p = PhotoDetails()
            p.originalFilename = text(0)
            p.bytes = number(1).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            p.width = number(2).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            p.height = number(3).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            p.title = text(4)
            p.caption = text(5)
            p.cameraMake = text(6)
            p.cameraModel = text(7)
            p.lens = text(8)
            p.focalLength = number(9)
            p.focalLength35 = number(10)
            p.aperture = number(11)
            p.shutterSpeed = number(12)
            p.iso = number(13).map { Int($0) }
            p.exposureBias = number(14)
            p.flashFired = number(15).map { $0 != 0 }
            p.timeZone = text(16)
            p.addedDate = number(17)
            p.importedBy = text(18)
            out = p
        }
        return out
    }
}
