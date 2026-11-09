import Foundation

/// Groups undated photos into likely events (one day, one party, one trip), even when their scans or
/// imports are scattered across the library.
///
/// Photos are linked when they look alike (Vision image fingerprints), with a stricter cutoff the less
/// else connects them:
/// - anywhere in the library: only very close matches (`Options.anywhere`);
/// - next to each other in import order (same roll or album page) or showing the same person: closer
///   matches are believable, so the cutoff is looser.
/// Links are taken closest first, and two groups merge only if their photos look alike on average
/// (average linkage), so one chain of so-so matches can't sweep unrelated photos together.
///
/// Calibrated on 2,568 GPS-dated phone photos from 319 days, shuffled to mimic scattered scans: with
/// the defaults, 45% of photos land in a group and 86% of each photo's group-mates are from within
/// three days of it. Without the average-linkage check, single long chains pulled up to 40 unrelated
/// photos together. Groups are usually pieces of an event (13% of same-day pairs end up together),
/// so `candidates(for:)` offers likely extra photos for the user to confirm.
/// The years a photo could possibly be from, given only firm facts (scan date, birth years, file
/// format, the user's "no photos before"). Soft clues never go in here.
public struct YearLimits: Hashable, Sendable {
    public var low: Int?
    public var high: Int?

    public init(low: Int? = nil, high: Int? = nil) {
        self.low = low
        self.high = high
    }

    /// From a photo's clues: hard constraints only.
    public init(_ evidence: [DateEvidence]) {
        for e in evidence where e.isHardConstraint {
            if let lo = e.yearLow { low = max(low ?? lo, lo) }
            if let hi = e.yearHigh { high = min(high ?? hi, hi) }
        }
    }

    /// Both could be true at once (their ranges overlap).
    public func overlaps(_ other: YearLimits) -> Bool { !intersection(other).isImpossible }

    public func intersection(_ other: YearLimits) -> YearLimits {
        YearLimits(low: [low, other.low].compactMap { $0 }.max(), high: [high, other.high].compactMap { $0 }.min())
    }

    public var isImpossible: Bool {
        if let low, let high { return low > high }
        return false
    }
}

public enum EventClusters {
    public struct Options: Sendable {
        public var anywhere: Float
        public var neighbors: Float
        public var samePerson: Float
        /// How far apart (in import order) counts as "next to each other".
        public var window: Int
        /// Two groups merge only if the average distance between their photos is below this.
        public var averageCutoff: Float
        public var maxSize: Int
        /// Taken in the same place (within `placeKm`) around the same time (guessed dates within
        /// `placeYears`): as believable as the same person.
        public var samePlace: Float
        public var placeKm: Double
        public var placeYears: Double
        /// The average-likeness cutoff for joining groups along a same-place link.
        public var placeAverageCutoff: Float

        public init(anywhere: Float = 0.5, neighbors: Float = 0.65, samePerson: Float = 0.7,
                    window: Int = 40, averageCutoff: Float = 0.55, maxSize: Int = 60,
                    samePlace: Float = 0.7, placeKm: Double = 1, placeYears: Double = 1,
                    placeAverageCutoff: Float = 0.65) {
            self.placeAverageCutoff = placeAverageCutoff
            self.samePlace = samePlace
            self.placeKm = placeKm
            self.placeYears = placeYears
            self.anywhere = anywhere
            self.neighbors = neighbors
            self.samePerson = samePerson
            self.window = window
            self.averageCutoff = averageCutoff
            self.maxSize = maxSize
        }
    }

    struct Edge { let a: Int; let b: Int; let d: Float; var cutoff: Float? = nil }

    /// - Returns: groups of two or more photos, biggest first, each in import order.
    /// - Parameter limits: firm year limits per photo. Photos whose limits can't overlap (scanned in 1985
    ///   vs. showing someone born in 1990) are never put in the same event, however alike they look.
    /// - Parameters:
    ///   - places: where photos were taken (their location in Photos, or the place given in Places).
    ///   - times: each photo's guessed date as a year with a fraction. A place only links photos
    ///     whose guesses are close: the same spot years apart isn't one event.
    public static func find(order: [String], prints: [String: [Float]], people: [String: Set<String>] = [:],
                            limits: [String: YearLimits] = [:], places: [String: GeoPoint] = [:],
                            times: [String: Double] = [:], options: Options = .init()) -> [[String]] {
        let ids = order.filter { prints[$0] != nil }
        guard ids.count > 1, let dim = prints[ids[0]]?.count, dim > 0 else { return [] }
        let vectors = ids.map { prints[$0]! }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var edges: [Edge] = []
        var seen: [Int64: Int] = [:]
        func add(_ i: Int, _ j: Int, _ d: Float, cutoff: Float? = nil) {
            let key = Int64(min(i, j)) << 32 | Int64(max(i, j))
            if let e = seen[key] {
                if let cutoff { edges[e].cutoff = max(edges[e].cutoff ?? 0, cutoff) }
            } else {
                seen[key] = edges.count
                edges.append(Edge(a: i, b: j, d: d, cutoff: cutoff))
            }
        }

        // Anywhere: all pairs, via matrix multiplication (distance² = 2 − 2·dot for unit vectors).
        let flat = vectors.flatMap { $0 }
        let minDot = 1 - options.anywhere * options.anywhere / 2 - 0.02
        let chunk = 256
        for start in stride(from: 0, to: ids.count, by: chunk) {
            if Task.isCancelled { return [] } // a newer run replaced this one
            let rows = min(chunk, ids.count - start)
            var dots = [Float](repeating: 0, count: rows * ids.count)
            EventLinks.multiplyTransposed(Array(flat[(start * dim)..<((start + rows) * dim)]), rows, flat, ids.count, dim, into: &dots)
            for r in 0..<rows {
                let i = start + r
                for j in (i + 1)..<ids.count where dots[r * ids.count + j] >= minDot {
                    let d = EventLinks.distance(vectors[i], vectors[j])
                    if d < options.anywhere { add(i, j, d) }
                }
            }
        }
        // Neighbors in import order.
        for i in 0..<ids.count {
            for j in (i + 1)..<min(ids.count, i + 1 + options.window) {
                let d = EventLinks.distance(vectors[i], vectors[j])
                if d < options.neighbors { add(i, j, d) }
            }
        }
        // Same person (skip people in so many photos that they say little).
        var byPerson: [String: [Int]] = [:]
        for (id, who) in people { if let i = index[id] { for p in who { byPerson[p, default: []].append(i) } } }
        for (_, members) in byPerson where members.count <= 300 {
            for x in 0..<members.count { for y in (x + 1)..<members.count {
                let i = members[x], j = members[y]
                let d = EventLinks.distance(vectors[i], vectors[j])
                if d < options.samePerson { add(i, j, d) }
            }}
        }

        // Same place around the same time. Buckets of about 2 km, compared with their neighbours.
        let located = places.compactMap { id, p -> (Int, GeoPoint, Double)? in
            guard let i = index[id], let t = times[id] else { return nil }
            return (i, p, t)
        }
        if located.count > 1 {
            let cell = 0.02
            func key(_ p: GeoPoint) -> (Int, Int) { (Int((p.lat / cell).rounded(.down)), Int((p.lon / cell).rounded(.down))) }
            var buckets: [Int64: [Int]] = [:]
            func code(_ k: (Int, Int)) -> Int64 { Int64(k.0) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: k.1))) }
            for (n, l) in located.enumerated() { buckets[code(key(l.1)), default: []].append(n) }
            for (n, l) in located.enumerated() {
                if n % 512 == 0, Task.isCancelled { return [] }
                let k = key(l.1)
                for dy in -1...1 { for dx in -1...1 {
                    for m in buckets[code((k.0 + dy, k.1 + dx))] ?? [] where m > n {
                        let o = located[m]
                        guard abs(l.2 - o.2) <= options.placeYears,
                              l.1.distanceKm(to: o.1) <= options.placeKm else { continue }
                        let d = EventLinks.distance(vectors[l.0], vectors[o.0])
                        if d < options.samePlace { add(l.0, o.0, d, cutoff: options.placeAverageCutoff) }
                    }
                }}
            }
        }

        // Closest links first; merge two groups only if they look alike on average.
        edges.sort { $0.d < $1.d }
        var parent = Array(0..<ids.count)
        var members = (0..<ids.count).map { [$0] }
        var groupLimits = ids.map { limits[$0] ?? YearLimits() }
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for (n, e) in edges.enumerated() {
            if n % 1024 == 0, Task.isCancelled { return [] }
            let a = root(e.a), b = root(e.b)
            guard a != b, members[a].count + members[b].count <= options.maxSize else { continue }
            let combined = groupLimits[a].intersection(groupLimits[b])
            guard !combined.isImpossible else { continue }
            var total: Float = 0
            for x in members[a] { for y in members[b] { total += EventLinks.distance(vectors[x], vectors[y]) } }
            guard total / Float(members[a].count * members[b].count) < max(options.averageCutoff, e.cutoff ?? 0) else { continue }
            parent[a] = b
            members[b] += members[a]
            members[a] = []
            groupLimits[b] = combined
        }
        return (0..<ids.count).filter { root($0) == $0 && members[$0].count >= 2 }
            .map { members[$0].sorted().map { ids[$0] } }
            .sorted { $0.count > $1.count }
    }

    /// Connected groups (of two or more) among `count` items.
    static func components(count: Int, edges: [Edge]) -> [[Int]] {
        var parent = Array(0..<count)
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for e in edges {
            let a = root(e.a), b = root(e.b)
            if a != b { parent[a] = b }
        }
        var groups: [Int: [Int]] = [:]
        for e in edges { for v in [e.a, e.b] { groups[root(v), default: []].append(v) } }
        return groups.values.map { Array(Set($0)) }.filter { $0.count >= 2 }
    }

    /// Photos that might also belong to an event, closest first: their average distance to the event's
    /// photos is under `cutoff` (looser than grouping, since the user confirms each one).
    public static func candidates(for members: [String], prints: [String: [Float]], people: [String: Set<String>] = [:],
                                  limits: [String: YearLimits] = [:], cutoff: Float = 0.7, limit: Int = 40) -> [String] {
        let inEvent = Set(members)
        let eventLimits = members.reduce(YearLimits()) { $0.intersection(limits[$1] ?? YearLimits()) }
        let vectors = members.compactMap { prints[$0] }
        guard !vectors.isEmpty else { return [] }
        let who = members.reduce(into: Set<String>()) { $0.formUnion(people[$1] ?? []) }
        var scored: [(String, Float)] = []
        for (id, v) in prints where !inEvent.contains(id) && eventLimits.overlaps(limits[id] ?? YearLimits()) {
            // Cheap first check against one member keeps this fast across thousands of photos.
            guard EventLinks.distance(v, vectors[0]) < cutoff + 0.25 else { continue }
            let avg = vectors.reduce(Float(0)) { $0 + EventLinks.distance(v, $1) } / Float(vectors.count)
            let shared = !who.isDisjoint(with: people[id] ?? [])
            if avg < cutoff || (shared && avg < cutoff + 0.05) { scored.append((id, avg)) }
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }
}
