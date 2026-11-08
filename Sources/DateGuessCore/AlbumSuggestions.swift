// Album suggestions: photos taken in one place over a stretch of days, named "2026-08 Hartford".
//
// Photos with a location are walked in time order. A run continues while each photo is within
// `areaKm` of where the run started and no more than `maxGapDays` after the one before; anything
// else starts a new run. A run becomes a suggestion when it has at least `minPhotos` photos and
// spans no more than `maxSpanDays` (so everyday photos at home, which run on for months, aren't
// suggested). It isn't suggested if an album with a year and month in its name already holds at
// least half of its photos.

import Foundation

public enum AlbumSuggestions {
    public static let areaKm = 25.0
    public static let maxGapDays = 2.0
    public static let maxSpanDays = 30.0
    public static let minPhotos = 10
    /// Share of a run's photos an existing year-and-month album must hold to count as covering it.
    public static let coveredShare = 0.5

    public struct Photo: Sendable, Hashable {
        public var id: String
        public var time: Date
        public var point: GeoPoint
        public init(id: String, time: Date, point: GeoPoint) {
            self.id = id
            self.time = time
            self.point = point
        }
    }

    public struct Album: Sendable {
        public var title: String
        public var ids: Set<String>
        public init(title: String, ids: Set<String>) {
            self.title = title
            self.ids = ids
        }
    }

    public struct Suggestion: Sendable, Hashable, Identifiable {
        /// Oldest and newest photo, which stay the same while the run does.
        public var id: String { (ids.first ?? "") + "|" + (ids.last ?? "") }
        /// In time order.
        public var ids: [String]
        public var start: Date
        public var end: Date
        /// The photo nearest the middle of the run's spot: where its name comes from.
        public var center: GeoPoint
    }

    /// Runs worth an album, newest first.
    public static func suggest(_ photos: [Photo], existing: [Album], calendar: Calendar = .current) -> [Suggestion] {
        let sorted = photos.sorted { $0.time != $1.time ? $0.time < $1.time : $0.id < $1.id }
        var runs: [[Photo]] = []
        var current: [Photo] = []
        for photo in sorted {
            if let first = current.first, let last = current.last,
               photo.point.distanceKm(to: first.point) <= areaKm,
               photo.time.timeIntervalSince(last.time) <= maxGapDays * 86_400 {
                current.append(photo)
            } else {
                if !current.isEmpty { runs.append(current) }
                current = [photo]
            }
        }
        if !current.isEmpty { runs.append(current) }
        runs = mergeByMonth(runs, calendar: calendar)

        let dated = existing.filter { hasYearAndMonth($0.title) }
        var out: [Suggestion] = []
        for run in runs where run.count >= minPhotos {
            guard let start = run.first?.time, let end = run.last?.time,
                  end.timeIntervalSince(start) <= maxSpanDays * 86_400 else { continue }
            let ids = run.map(\.id)
            let covered = dated.contains { album in
                Double(ids.filter(album.ids.contains).count) >= coveredShare * Double(ids.count)
            }
            if covered { continue }
            out.append(Suggestion(ids: ids, start: start, end: end, center: medoid(run.map(\.point))))
        }
        return out.sorted { $0.start > $1.start }
    }

    /// Runs in one place that start in the same month become one, while it stays within
    /// `maxSpanDays`: a month of everyday photos at home, or a trip with a quiet day in it.
    static func mergeByMonth(_ runs: [[Photo]], calendar: Calendar) -> [[Photo]] {
        var groups: [[Photo]] = []
        var keys: [(month: DateComponents, center: GeoPoint)] = []
        for run in runs {
            guard let first = run.first else { continue }
            let month = calendar.dateComponents([.year, .month], from: first.time)
            let center = medoid(run.map(\.point))
            if let i = groups.indices.last(where: { keys[$0].month == month && keys[$0].center.distanceKm(to: center) <= areaKm }),
               let start = groups[i].first?.time, let end = run.last?.time,
               end.timeIntervalSince(start) <= maxSpanDays * 86_400 {
                groups[i] += run
            } else {
                groups.append(run)
                keys.append((month, center))
            }
        }
        return groups
    }

    /// "2026-08 Hartford": the month the run starts in, then the town.
    public static func title(start: Date, town: String?, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: start)
        let month = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        guard let town = town.map(shortTown), !town.isEmpty else { return month }
        return "\(month) \(town)"
    }

    /// "Hartford, CT" → "Hartford".
    public static func shortTown(_ name: String) -> String {
        name.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
    }

    /// Whether an album's name has a year and a month: "2026-08", "2026.08", "08/2026", "Aug 2026",
    /// "August 2026", "2026 August".
    public static func hasYearAndMonth(_ title: String) -> Bool {
        let t = title.lowercased()
        let year = "(?:19|20)\\d{2}"
        let num = "(?:0?[1-9]|1[0-2])"
        let months = "(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*"
        let patterns = [
            "(?<!\\d)\(year)[-_./ ]\(num)(?!\\d)",
            "(?<!\\d)\(num)[-_./ ]\(year)(?!\\d)",
            "\\b\(months)\\.?,?\\s*\(year)(?!\\d)",
            "(?<!\\d)\(year),?\\s*\(months)\\b",
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    /// The point with the most others within a short walk: where the run mostly was.
    static func medoid(_ points: [GeoPoint]) -> GeoPoint {
        let sample = points.count <= 80 ? points : stride(from: 0, to: points.count, by: points.count / 80).map { points[$0] }
        var best = sample[0], bestCount = -1
        for p in sample {
            let n = sample.reduce(0) { $0 + (p.distanceKm(to: $1) <= 2 ? 1 : 0) }
            if n > bestCount { best = p; bestCount = n }
        }
        return best
    }
}
