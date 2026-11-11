import Foundation
import SQLite3

/// Photos whose date is the day they were recovered, not the day they were taken.
///
/// Data recovery brings files back without their camera dates, and Photos dates each by its file:
/// the day of the recovery. So a recovery batch is one day (or a few days in a row) with many
/// photos that have no capture time from the camera and no location, in a wide mix of sizes from
/// many cameras, usually named alike. Photos genuinely taken that day keep their camera time or
/// location, and screenshots are marked as such, so they're left out.
///
/// Measured on one library: 9,302 recovered photos in 5 batches, matching every recovery its owner
/// knew of, with 1,430 photos really taken on those days (and screenshots and downloads) left out.
public enum RecoveryBatches {
    public struct Photo: Sendable {
        public var uuid: String
        /// Seconds since 2001 (Photos' own clock).
        public var date: Double
        public var hasCameraTime: Bool
        public var hasLocation: Bool
        public var width: Int
        public var height: Int
        public var isScreenshot: Bool
        public var filename: String?

        public init(uuid: String, date: Double, hasCameraTime: Bool, hasLocation: Bool, width: Int, height: Int,
                    isScreenshot: Bool, filename: String?) {
            self.uuid = uuid
            self.date = date
            self.hasCameraTime = hasCameraTime
            self.hasLocation = hasLocation
            self.width = width
            self.height = height
            self.isScreenshot = isScreenshot
            self.filename = filename
        }
    }

    /// One recovery: its days (first and last, seconds since 2001 at the start of each day, UTC) and
    /// how many photos came back then.
    public struct Batch: Codable, Hashable, Sendable {
        public var firstDay: Double
        public var lastDay: Double
        public var count: Int

        public var firstDate: Date { Date(timeIntervalSinceReferenceDate: firstDay) }
        public var lastDate: Date { Date(timeIntervalSinceReferenceDate: lastDay) }

        /// "Dec 15–17, 2013", "Sep 30, 2023".
        public var label: String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let a = calendar.dateComponents([.year, .month, .day], from: firstDate)
            let b = calendar.dateComponents([.year, .month, .day], from: lastDate)
            let style = Date.FormatStyle(timeZone: calendar.timeZone)
            let month = { (d: Date) in d.formatted(style.month(.abbreviated)) }
            if a == b { return firstDate.formatted(style.month(.abbreviated).day().year()) }
            if a.year == b.year && a.month == b.month { return "\(month(firstDate)) \(a.day!)–\(b.day!), \(a.year!)" }
            return "\(firstDate.formatted(style.month(.abbreviated).day())) – \(lastDate.formatted(style.month(.abbreviated).day().year()))"
        }
    }

    /// Each recovered photo (by UUID) and the batch it came back in.
    public struct Result: Sendable {
        public var photos: [String: Batch] = [:]
        public var batches: [Batch] = []
        public init() {}
    }

    static let day = 86400.0

    /// "IMG_1234 (2)" → "a_9 (9)": how a file is named, without the name.
    static func shape(_ filename: String?) -> String {
        guard let name = filename else { return "-" }
        let base = name.split(separator: ".").dropLast().joined(separator: ".")
        var out = "", last: Character? = nil
        for ch in base.isEmpty ? name : base {
            let c: Character = ch.isLetter ? "a" : ch.isNumber ? "9" : ch
            if (c == "a" || c == "9"), c == last { continue }
            out.append(c)
            last = c
        }
        return out
    }

    public static func find(_ photos: [Photo]) -> Result {
        var byDay: [Int: [Int]] = [:]
        for (i, p) in photos.enumerated() { byDay[Int((p.date / day).rounded(.down)), default: []].append(i) }
        /// The day's photos that could be recovered: no camera time, no location, not a screenshot.
        func loose(_ d: Int) -> [Int] {
            (byDay[d] ?? []).filter { !photos[$0].hasCameraTime && !photos[$0].hasLocation && !photos[$0].isScreenshot }
        }
        func sizes(_ l: [Int]) -> Int { Set(l.map { photos[$0].width * 100_000 + photos[$0].height }).count }

        // Days that are plainly a recovery.
        let seeds = byDay.keys.filter { d in
            let all = byDay[d]!.count, l = loose(d)
            return all >= 50 && Double(l.count) >= 0.6 * Double(all) && sizes(l) >= 30
        }.sorted()
        // Seeds up to two days apart are one recovery.
        var runs: [[Int]] = []
        for d in seeds {
            if let last = runs.last?.last, d - last <= 2 { runs[runs.count - 1].append(d) } else { runs.append([d]) }
        }

        var result = Result()
        for run in runs {
            var days = Set(run)
            // Filename styles common in the batch (at least a tenth of its photos).
            var names: [String: Int] = [:]
            for d in run { for i in loose(d) { names[shape(photos[i].filename), default: 0] += 1 } }
            let total = names.values.reduce(0, +)
            let common = Set(names.filter { Double($0.value) >= 0.1 * Double(total) }.keys)
            // Days between seeds belong too.
            if let lo = run.first, let hi = run.last {
                for d in lo...hi where loose(d).count >= 5 { days.insert(d) }
            }
            // The days right before and after: when they hold photos like the batch's.
            var grew = true
            while grew {
                grew = false
                for d in days.sorted() {
                    for nd in [d - 1, d + 1] where !days.contains(nd) {
                        let l = loose(nd)
                        guard l.count >= 5 else { continue }
                        let mixed = Double(sizes(l)) >= 0.5 * Double(l.count)
                        let named = Double(l.filter { common.contains(shape(photos[$0].filename)) }.count) >= 0.6 * Double(l.count)
                        if mixed || named { days.insert(nd); grew = true }
                    }
                }
            }
            let members = days.flatMap { loose($0) }
            guard let first = days.min(), let last = days.max(), !members.isEmpty else { continue }
            let batch = Batch(firstDay: Double(first) * day, lastDay: Double(last) * day, count: members.count)
            result.batches.append(batch)
            for i in members { result.photos[photos[i].uuid] = batch }
        }
        result.batches.sort { $0.firstDay < $1.firstDay }
        return result
    }
}

extension PhotosDatabase {
    /// Finds recovery batches in the library's own records: every photo's date, whether it has a
    /// camera capture time and a location, its size, and how its file is named.
    public static func readRecoveryBatches(inLibrary library: URL) throws -> RecoveryBatches.Result {
        let path = library.appendingPathComponent("database/Photos.sqlite").path
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw PhotosDatabaseError(kind: .noAccess, message: "Keeper can't read this library's database.")
        }
        let db = try Database(liveReadOnly: path)
        let tables = Set(try db.column("SELECT name FROM sqlite_master WHERE type = 'table'"))
        guard let assetTable = ["ZASSET", "ZGENERICASSET"].first(where: tables.contains),
              tables.contains("ZADDITIONALASSETATTRIBUTES") else {
            throw PhotosDatabaseError(kind: .unrecognisedSchema, message: "This library's database has no asset table Keeper recognises.")
        }
        let a = Set(try db.rows("PRAGMA table_info(\(q(assetTable)))").compactMap { $0[1] })
        let b = Set(try db.rows("PRAGMA table_info(ZADDITIONALASSETATTRIBUTES)").compactMap { $0[1] })
        guard a.isSuperset(of: ["ZUUID", "ZDATECREATED", "ZLATITUDE", "ZLONGITUDE", "ZWIDTH", "ZHEIGHT"]),
              b.isSuperset(of: ["ZASSET", "ZEXIFTIMESTAMPSTRING"]) else {
            throw PhotosDatabaseError(kind: .unrecognisedSchema, message: "This library's database stores capture times differently.")
        }
        let subtype = a.contains("ZKINDSUBTYPE") ? "a.ZKINDSUBTYPE" : "0"
        let kind = a.contains("ZKIND") ? "a.ZKIND = 0 AND " : ""
        let trashed = a.contains("ZTRASHEDSTATE") ? "a.ZTRASHEDSTATE = 0 AND " : ""
        let filename = b.contains("ZORIGINALFILENAME") ? "b.ZORIGINALFILENAME" : "NULL"
        var photos: [RecoveryBatches.Photo] = []
        try db.forEachRow("""
            SELECT a.ZUUID, a.ZDATECREATED, b.ZEXIFTIMESTAMPSTRING, a.ZLATITUDE, a.ZLONGITUDE, a.ZWIDTH, a.ZHEIGHT, \(subtype), \(filename)
            FROM \(q(assetTable)) a LEFT JOIN ZADDITIONALASSETATTRIBUTES b ON b.ZASSET = a.Z_PK
            WHERE \(kind)\(trashed)a.ZDATECREATED IS NOT NULL
            """) { stmt in
            guard let uuid = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { return }
            func text(_ c: Int32) -> String? { sqlite3_column_text(stmt, c).map { String(cString: $0) } }
            func f(_ c: Int32) -> Double? { sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, c) }
            let located = f(3).flatMap { lat in f(4).map { isRealLocation(lat: lat, lon: $0) } } ?? false
            photos.append(.init(uuid: uuid, date: sqlite3_column_double(stmt, 1), hasCameraTime: !(text(2) ?? "").isEmpty,
                                hasLocation: located, width: Int(sqlite3_column_int64(stmt, 5)), height: Int(sqlite3_column_int64(stmt, 6)),
                                isScreenshot: sqlite3_column_int64(stmt, 7) == 10, filename: text(8)))
        }
        return RecoveryBatches.find(photos)
    }
}
