// When an undated photo has a location: the dated photos taken within a kilometre of it. If most of
// them fall in one month (a one-time trip, not a place you photograph all the time), the photo was
// probably taken then.
//
// Measured on a library of 127,000 dated photos with a location, dates hidden one at a time: with
// 90% of the nearby photos in one month, the month was right for 82% of photos with no other photo
// from the same day, and 99% when there were (a trip's other photos). So it counts for a lot.

import Foundation

public enum PlaceDateClues {
    public static let radiusKm = 1.0
    public static let windowDays = 31.0
    public static let minNearby = 3
    /// Share of the nearby photos that must fall in one month.
    public static let minShare = 0.7
    public static let strongShare = 0.9

    public struct Reference: Sendable {
        public var time: Date
        public var point: GeoPoint
        public init(time: Date, point: GeoPoint) {
            self.time = time
            self.point = point
        }
    }

    /// A clue for each target the nearby dated photos agree on.
    public static func evidence(for targets: [String: GeoPoint], references: [Reference],
                                calendar: Calendar = .current) -> [String: DateEvidence] {
        guard !targets.isEmpty, !references.isEmpty else { return [:] }
        // A grid of about 1 km cells.
        let cell = 0.01
        func key(_ p: GeoPoint) -> Int64 { Int64((p.lat / cell).rounded(.down)) * 1_000_000 + Int64((p.lon / cell).rounded(.down)) }
        var grid: [Int64: [Int]] = [:]
        for (i, r) in references.enumerated() { grid[key(r.point), default: []].append(i) }

        var out: [String: DateEvidence] = [:]
        for (id, point) in targets {
            let ci = Int64((point.lat / cell).rounded(.down)), cj = Int64((point.lon / cell).rounded(.down))
            var times: [Date] = []
            // A degree of longitude is less than 111 km away from the equator: look two cells across.
            for a in (ci - 1)...(ci + 1) {
                for b in (cj - 2)...(cj + 2) {
                    for j in grid[a * 1_000_000 + b] ?? [] where references[j].point.distanceKm(to: point) <= radiusKm {
                        times.append(references[j].time)
                    }
                }
            }
            guard times.count >= minNearby else { continue }
            times.sort()
            // The month-long window holding the most of them.
            var best = 0, start = 0, k = 0
            for s in times.indices {
                while times[s].timeIntervalSince(times[k]) > windowDays * 86_400 { k += 1 }
                if s - k + 1 > best { best = s - k + 1; start = k }
            }
            let share = Double(best) / Double(times.count)
            guard share >= minShare else { continue }
            let middle = times[start + best / 2]
            let c = calendar.dateComponents([.year, .month], from: middle)
            guard let year = c.year, let month = c.month else { continue }
            let strong = share >= strongShare
            let when = "\(DateEstimate.monthNames[month - 1]) \(year)"
            var e = DateEvidence(source: .location,
                                 summary: "Taken within 1 km of \(times.count) dated photos, \(Int((share * 100).rounded()))% of them from \(when): likely the same trip",
                                 yearLow: year, yearHigh: year, peakYear: year,
                                 weight: strong ? 0.85 : 0.6,
                                 season: Season.from(month: month), seasonWeight: strong ? 0.8 : 0.5,
                                 exactMonth: strong ? month : nil)
            e.calibrationKey = strong ? "location:strong" : "location:likely"
            out[id] = e
        }
        return out
    }
}
