import Foundation

/// A spot on Earth.
public struct GeoPoint: Codable, Hashable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    /// Great-circle distance in kilometers.
    public func distanceKm(to other: GeoPoint) -> Double {
        let r = Double.pi / 180
        let dLat = (other.lat - lat) * r, dLon = (other.lon - lon) * r
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat * r) * cos(other.lat * r) * sin(dLon / 2) * sin(dLon / 2)
        return 12_742 * asin(min(1, h.squareRoot()))
    }
}

public enum PlaceSource: String, Codable, Hashable, Sendable {
    /// A geotagged photo taken around the same time.
    case sameTime
    /// Looks like geotagged photos from one place.
    case lookalike
    /// In the same event as a photo with a known place.
    case sameEvent
    /// A photo the user placed in this app, taken around the same time.
    case placedHere
}

/// One reason to think a photo was taken somewhere.
public struct PlaceEvidence: Codable, Hashable, Sendable {
    public var source: PlaceSource
    public var summary: String
    public var point: GeoPoint
    /// 0…1: about how often this kind of clue lands within a kilometer or so.
    public var weight: Double
    /// The photo this clue came from, to show it.
    public var referenceID: String?

    public init(source: PlaceSource, summary: String, point: GeoPoint, weight: Double, referenceID: String? = nil) {
        self.source = source
        self.summary = summary
        self.point = point
        self.weight = weight
        self.referenceID = referenceID
    }
}

public struct PlaceEstimate: Codable, Hashable, Sendable {
    public var point: GeoPoint
    /// 0…1.
    public var confidence: Double
    /// About how far off it might be, in kilometers.
    public var spreadKm: Double

    public init(point: GeoPoint, confidence: Double, spreadKm: Double) {
        self.point = point
        self.confidence = confidence
        self.spreadKm = spreadKm
    }
}

/// Combines place clues: the clues that agree on one area win, and their best clue gives the spot.
public enum PlaceFusion {
    /// Clues within this distance of each other count as the same area.
    public static let areaKm = 25.0

    public static func estimate(_ evidence: [PlaceEvidence]) -> PlaceEstimate? {
        let clues = evidence.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        guard let first = clues.first else { return nil }
        // Greedy areas around the strongest clues.
        var areas: [(seed: PlaceEvidence, members: [PlaceEvidence])] = []
        for clue in clues {
            if let i = areas.firstIndex(where: { $0.seed.point.distanceKm(to: clue.point) < areaKm }) {
                areas[i].members.append(clue)
            } else {
                areas.append((clue, [clue]))
            }
        }
        func total(_ members: [PlaceEvidence]) -> Double { members.reduce(0) { $0 + $1.weight } }
        let best = areas.max { total($0.members) < total($1.members) } ?? (first, [first])
        let all = total(clues)
        // Independent clues for one area add up (each may be wrong on its own); disagreement lowers it.
        let support = 1 - best.members.reduce(1.0) { $0 * (1 - min(0.97, $1.weight)) }
        let confidence = min(0.97, support * total(best.members) / all)
        // The spot itself is the best clue's; averaging spots tends to land between them.
        let center = best.seed.point
        let others = best.members.dropFirst()
        let spread = others.isEmpty
            ? Self.spreadKm(best.seed)
            : others.reduce(0) { $0 + $1.weight * $1.point.distanceKm(to: center) } / max(0.01, total(Array(others)))
        return PlaceEstimate(point: center, confidence: confidence, spreadKm: max(0.1, spread))
    }

    /// How far off one clue on its own tends to be.
    static func spreadKm(_ e: PlaceEvidence) -> Double {
        switch e.source {
        case .lookalike: return areaKm
        case .sameTime, .placedHere, .sameEvent: return min(areaKm, 0.3 / max(0.05, e.weight * e.weight))
        }
    }
}

/// "Taken 12 minutes after a photo from here": geotagged photos taken around the same time.
///
/// Checked on this library: a camera photo taken within 15 minutes of a phone photo was within a
/// kilometer of it 97% of the time, 85% within an hour, about half at 3 hours, and rarely after that
/// (though often still in the same area).
public struct PlaceTimeline: Sendable {
    public struct Reference: Sendable {
        public var id: String
        public var time: Date
        public var point: GeoPoint
        /// Placed in this app rather than geotagged by a camera or phone.
        public var placedHere: Bool

        public init(id: String, time: Date, point: GeoPoint, placedHere: Bool = false) {
            self.id = id
            self.time = time
            self.point = point
            self.placedHere = placedHere
        }
    }

    let references: [Reference]
    let times: [Double]

    /// Further apart than this, the photos were in the same place well under half the time.
    public static let window: TimeInterval = 6 * 3600

    public init(_ references: [Reference]) {
        self.references = references.sorted { $0.time < $1.time }
        times = self.references.map(\.time.timeIntervalSinceReferenceDate)
    }

    public var count: Int { references.count }

    /// How often a photo this far apart in time was taken at about the same spot.
    public static func weight(gap: TimeInterval) -> Double {
        let knots: [(hours: Double, weight: Double)] = [(0, 0.95), (0.25, 0.93), (1, 0.8), (3, 0.5), (6, 0.3), (12, 0.18), (24, 0.1)]
        let h = abs(gap) / 3600
        guard h < knots.last!.hours else { return 0 }
        let i = knots.firstIndex { $0.hours > h }!
        let a = knots[i - 1], b = knots[i]
        return a.weight + (b.weight - a.weight) * (h - a.hours) / (b.hours - a.hours)
    }

    /// The nearest reference photo before and after `time`, each as a clue.
    /// - Parameter reliability: how often this camera's time clues turned out right (0…1, scales the weight).
    public func evidence(at time: Date, excluding id: String? = nil, reliability: Double = 1) -> [PlaceEvidence] {
        let t = time.timeIntervalSinceReferenceDate
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        var out: [PlaceEvidence] = []
        var before = lo - 1
        while before >= 0, references[before].id == id { before -= 1 }
        var after = lo
        while after < references.count, references[after].id == id { after += 1 }
        for index in [before, after] where index >= 0 && index < references.count {
            let ref = references[index]
            let gap = ref.time.timeIntervalSince(time)
            guard abs(gap) < Self.window else { continue }
            let weight = Self.weight(gap: gap) * (ref.placedHere ? 0.8 : 1) * reliability
            out.append(PlaceEvidence(source: ref.placedHere ? .placedHere : .sameTime,
                                     summary: Self.describe(gap: gap, placedHere: ref.placedHere),
                                     point: ref.point, weight: weight, referenceID: ref.id))
        }
        return out
    }

    static func describe(gap: TimeInterval, placedHere: Bool) -> String {
        let minutes = Int((abs(gap) / 60).rounded())
        let amount: String
        if minutes < 1 { amount = "Less than a minute" }
        else if minutes < 90 { amount = minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        else {
            let hours = Int((abs(gap) / 3600).rounded())
            amount = hours == 1 ? "1 hour" : "\(hours) hours"
        }
        let what = placedHere ? "a photo you placed" : "a photo with a location"
        return "\(amount) \(gap < 0 ? "after" : "before") \(what)"
    }
}

/// "Looks like your photos from here": the closest geotagged photos by image fingerprint.
///
/// Checked on this library: when most of the 15 closest photos are from one area, it's within 25 km
/// about three times out of four; when they disagree it's little better than guessing home, so those
/// clues are left out.
public struct PlaceProbe: Sendable {
    public struct Example: Sendable {
        public var id: String
        public var point: GeoPoint
        public var print: [Float]

        public init(id: String, point: GeoPoint, print: [Float]) {
            self.id = id
            self.point = point
            self.print = print
        }
    }

    public static let neighbors = 15
    public static let minimumExamples = 50
    /// Below this the closest photos disagree too often to be worth showing.
    public static let minimumAgreement = 0.8

    let ids: [String]
    let points: [GeoPoint]
    let matrix: [Float]
    let dim: Int

    public init(_ examples: [Example]) {
        let dim = examples.first?.print.count ?? 0
        let usable = examples.filter { $0.print.count == dim && dim > 0 }
        self.dim = dim
        ids = usable.map(\.id)
        points = usable.map(\.point)
        matrix = usable.flatMap { YearProbe.normalized($0.print) }
    }

    public var count: Int { ids.count }

    public func evidence(for queries: [String: [Float]], maxWeight: Double = 0.6) -> [String: PlaceEvidence] {
        guard count >= Self.minimumExamples else { return [:] }
        let queryIDs = queries.keys.filter { queries[$0]?.count == dim }.sorted()
        let n = count
        var out: [String: PlaceEvidence] = [:]
        for start in stride(from: 0, to: queryIDs.count, by: 256) {
            let batch = Array(queryIDs[start..<min(queryIDs.count, start + 256)])
            let rows = batch.flatMap { YearProbe.normalized(queries[$0]!) }
            var dots = [Float](repeating: 0, count: batch.count * n)
            EventLinks.multiplyTransposed(rows, batch.count, matrix, n, dim, into: &dots)
            for (i, id) in batch.enumerated() {
                let best = YearProbe.top(dots, row: i, n: n, k: Self.neighbors) { ids[$0] != id }
                let votes = best.map { (points[$0.index], pow(Double(max(0, $0.dot)), 4), ids[$0.index]) }
                if let e = Self.clue(votes, maxWeight: maxWeight) { out[id] = e }
            }
        }
        return out
    }

    static func clue(_ votes: [(point: GeoPoint, weight: Double, id: String)], maxWeight: Double) -> PlaceEvidence? {
        let total = votes.reduce(0) { $0 + $1.weight }
        guard votes.count >= 3, total > 0 else { return nil }
        // The area with the most weight, around one of the votes.
        var best: (weight: Double, index: Int) = (0, 0)
        for (i, v) in votes.enumerated() {
            let w = votes.filter { $0.point.distanceKm(to: v.point) < PlaceFusion.areaKm }.reduce(0) { $0 + $1.weight }
            if w > best.weight { best = (w, i) }
        }
        let agreement = best.weight / total
        guard agreement >= minimumAgreement else { return nil }
        let seed = votes[best.index]
        return PlaceEvidence(source: .lookalike, summary: "Looks like your photos with a location here",
                             point: seed.point, weight: maxWeight * agreement, referenceID: seed.id)
    }
}

/// How often each camera's "taken around the same time" clues are right, learned from that camera's
/// own photos that have a location. Like `ClueCalibration`, it only ever counts a camera less.
///
/// Correcting each camera's clock (as geotagging tools do with a GPS track) was tried too, but on this
/// library a camera's offset changed from one outing to the next, so an offset learned on some days
/// made other days worse. It isn't used.
public struct PlaceCalibration: Codable, Hashable, Sendable {
    public struct Clock: Codable, Hashable, Sendable {
        /// 0…1: how much of a time clue's weight to keep for this camera.
        public var reliability: Double
        /// Located photos it was checked on.
        public var checked: Int

        public init(reliability: Double, checked: Int) {
            self.reliability = reliability
            self.checked = checked
        }
    }

    /// Camera → how its time clues did.
    public var clocks: [String: Clock] = [:]

    public init() {}

    public struct Photo: Sendable {
        public var camera: String?
        public var time: Date
        public var point: GeoPoint

        public init(camera: String?, time: Date, point: GeoPoint) {
            self.camera = camera
            self.time = time
            self.point = point
        }
    }

    public func reliability(camera: String?) -> Double {
        camera.flatMap { clocks[$0]?.reliability } ?? 1
    }

    static let matchWindow: TimeInterval = 3600
    static let expectedHitRate = 0.87
    static let minimumPhotos = 20
    static let sampleSize = 6000

    public static func learn(_ photos: [Photo]) -> PlaceCalibration {
        var out = PlaceCalibration()
        let byCamera = Dictionary(grouping: photos.indices.filter { photos[$0].camera != nil }) { photos[$0].camera! }
        for (camera, indices) in byCamera where indices.count >= minimumPhotos {
            // Everyone else's photos are the reference.
            let others = photos.filter { $0.camera != camera }
                .map { (t: $0.time.timeIntervalSinceReferenceDate, p: $0.point) }
                .sorted { $0.t < $1.t }
            guard others.count >= minimumPhotos else { continue }
            var own = indices.map { photos[$0] }
            // A few thousand photos are plenty for cameras with tens of thousands.
            if own.count > sampleSize { own = stride(from: 0, to: own.count, by: own.count / sampleSize + 1).map { own[$0] } }
            let result = score(own, times: others.map(\.t), others: others)
            guard result.matched >= 10 else { continue }
            let prior = ClueCalibration.priorCount
            let rate = (Double(result.hits) + prior * expectedHitRate) / (Double(result.matched) + prior)
            out.clocks[camera] = Clock(reliability: min(1, rate / expectedHitRate), checked: result.matched)
        }
        return out
    }

    /// Photos matched to another camera's photo within an hour, and of those, how many were within 1 km.
    static func score(_ photos: [Photo], times: [Double], others: [(t: Double, p: GeoPoint)]) -> (matched: Int, hits: Int) {
        var matched = 0, hits = 0
        for photo in photos {
            let t = photo.time.timeIntervalSinceReferenceDate
            var lo = 0, hi = times.count
            while lo < hi { let mid = (lo + hi) / 2; if times[mid] < t { lo = mid + 1 } else { hi = mid } }
            var best: Int?
            for i in [lo - 1, lo] where i >= 0 && i < times.count {
                if best == nil || abs(times[i] - t) < abs(times[best!] - t) { best = i }
            }
            guard let b = best, abs(times[b] - t) < matchWindow else { continue }
            matched += 1
            if others[b].p.distanceKm(to: photo.point) < 1 { hits += 1 }
        }
        return (matched, hits)
    }
}

/// Photos from one camera taken close together: an outing, placed with one search.
public enum PlaceOutings {
    public struct Photo: Sendable {
        public var id: String
        public var time: Date
        public var camera: String?

        public init(id: String, time: Date, camera: String?) {
            self.id = id
            self.time = time
            self.camera = camera
        }
    }

    /// A longer pause than this starts a new outing.
    public static let gap: TimeInterval = 2 * 3600

    /// Outings, biggest first; each one's photos in time order.
    public static func group(_ photos: [Photo]) -> [[String]] {
        var out: [[String]] = []
        for (_, members) in Dictionary(grouping: photos, by: { $0.camera ?? "" }) {
            var current: [Photo] = []
            for photo in members.sorted(by: { $0.time < $1.time }) {
                if let last = current.last, photo.time.timeIntervalSince(last.time) > gap {
                    out.append(current.map(\.id))
                    current = []
                }
                current.append(photo)
            }
            if !current.isEmpty { out.append(current.map(\.id)) }
        }
        return out.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
    }
}
