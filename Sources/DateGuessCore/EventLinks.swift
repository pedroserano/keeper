import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Finds undated photos that are probably from the same event (same day, same clothes, same room)
/// so their dates can agree, even when nobody grouped them.
///
/// Photos are compared by an image "fingerprint" (Vision's feature print: a unit-length vector, where
/// the Euclidean distance between two prints measures how different they look). Calibrated on a real
/// library: of photos taken on the same day, 17% are closer than 0.5 and 31% closer than 0.7; of photos
/// taken in different years, only 0.01% are closer than 0.5 and 0.44% closer than 0.7.
public enum EventLinks {
    public struct Link: Hashable, Sendable {
        public var assetID: String
        public var distance: Float
        /// 0…1: how strongly the other photo's clues should count for this one.
        public var weight: Double

        public init(assetID: String, distance: Float, weight: Double) {
            self.assetID = assetID
            self.distance = distance
            self.weight = weight
        }
    }

    // MARK: Fingerprints

    /// Packs a unit vector into one byte per element plus a scale (a 768-element print → 772 bytes).
    public static func pack(_ vector: [Float]) -> Data {
        let scale = max(vector.map(abs).max() ?? 0, 1e-9)
        var data = Data(count: 4 + vector.count)
        data.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: scale.bitPattern.littleEndian, as: UInt32.self)
            for (i, v) in vector.enumerated() {
                raw[4 + i] = UInt8(bitPattern: Int8(max(-127, min(127, (v / scale * 127).rounded()))))
            }
        }
        return data
    }

    public static func unpack(_ data: Data) -> [Float] {
        guard data.count > 4 else { return [] }
        return data.withUnsafeBytes { raw in
            let scale = Float(bitPattern: UInt32(littleEndian: raw.load(as: UInt32.self)))
            return (4..<data.count).map { Float(Int8(bitPattern: raw[$0])) / 127 * scale }
        }
    }

    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum: Float = 0
        for i in a.indices {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }

    /// How much a match counts, from the calibration above. Sharing a recognized person makes a
    /// looser visual match believable.
    public static func weight(distance: Float, sharesPerson: Bool) -> Double? {
        switch distance {
        case ..<0.45: return 0.9
        case ..<0.6: return 0.7
        case ..<0.72: return 0.45
        case ..<0.82 where sharesPerson: return 0.35
        default: return nil
        }
    }

    // MARK: Finding links

    /// - Parameters:
    ///   - order: undated photos in library order (import time, then filename): scans of one roll or
    ///     album usually sit next to each other.
    ///   - prints: unpacked fingerprints.
    ///   - people: face groups or people seen in each photo; photos sharing someone are also compared.
    /// - Returns: up to `maxLinks` matches per photo, best first.
    public static func find(order: [String], prints: [String: [Float]], people: [String: Set<String>] = [:],
                            window: Int = 40, maxPeopleGroup: Int = 300, maxLinks: Int = 8) -> [String: [Link]] {
        var best: [String: [String: Link]] = [:]
        func consider(_ a: String, _ b: String) {
            guard a != b, best[a]?[b] == nil, let pa = prints[a], let pb = prints[b] else { return }
            let d = distance(pa, pb)
            let shared = !(people[a] ?? []).isDisjoint(with: people[b] ?? [])
            guard let w = weight(distance: d, sharesPerson: shared) else { return }
            best[a, default: [:]][b] = Link(assetID: b, distance: d, weight: w)
            best[b, default: [:]][a] = Link(assetID: a, distance: d, weight: w)
        }
        let withPrints = order.filter { prints[$0] != nil }
        for (i, a) in withPrints.enumerated() {
            for j in (i + 1)..<min(withPrints.count, i + 1 + window) { consider(a, withPrints[j]) }
        }
        var byPerson: [String: [String]] = [:]
        for (asset, who) in people where prints[asset] != nil {
            for p in who { byPerson[p, default: []].append(asset) }
        }
        // Someone who's in thousands of photos says little about which ones go together.
        for (_, assets) in byPerson where assets.count <= maxPeopleGroup {
            for i in assets.indices { for j in (i + 1)..<assets.count { consider(assets[i], assets[j]) } }
        }
        return best.mapValues { links in
            Array(links.values.sorted { $0.distance < $1.distance }.prefix(maxLinks))
        }
    }

    /// Each undated photo's closest reference, if it's within the near-duplicate cutoff. Compares
    /// every pair (tens of thousands each way), so it uses a matrix multiply: for unit vectors,
    /// distance² = 2 − 2 · dot product.
    static func nearestDuplicates(undated: [String: [Float]], references: [String: Reference]) -> [String: (id: String, distance: Float)] {
        let refIDs = Array(references.keys)
        guard let dim = references.values.first?.print.count, dim > 0, !undated.isEmpty else { return [:] }
        let refs = refIDs.compactMap { references[$0]?.print.count == dim ? references[$0]!.print : nil }
        guard refs.count == refIDs.count else { return [:] }
        let refMatrix = refs.flatMap { $0 }
        let undatedIDs = undated.keys.filter { undated[$0]?.count == dim }
        // A little slack: packed prints are only nearly unit length; the exact check below decides.
        let maxDot = 1 - nearDuplicateCutoff * nearDuplicateCutoff / 2 - 0.02
        var out: [String: (id: String, distance: Float)] = [:]
        let chunk = 256
        for start in stride(from: 0, to: undatedIDs.count, by: chunk) {
            if Task.isCancelled { return [:] }
            let ids = Array(undatedIDs[start..<min(undatedIDs.count, start + chunk)])
            let rows = ids.flatMap { undated[$0]! }
            var dots = [Float](repeating: 0, count: ids.count * refs.count)
            multiplyTransposed(rows, ids.count, refMatrix, refs.count, dim, into: &dots)
            for (i, id) in ids.enumerated() {
                var bestDot: Float = -2, bestJ = -1
                for j in 0..<refs.count where dots[i * refs.count + j] > bestDot {
                    bestDot = dots[i * refs.count + j]
                    bestJ = j
                }
                guard bestJ >= 0, bestDot >= maxDot, refIDs[bestJ] != id else { continue }
                // Confirm with the exact distance (packed prints are only nearly unit length).
                let d = distance(undated[id]!, refs[bestJ])
                if d < nearDuplicateCutoff { out[id] = (refIDs[bestJ], d) }
            }
        }
        return out
    }

    /// c = a · bᵀ, where a is m×k and b is n×k (row-major).
    static func multiplyTransposed(_ a: [Float], _ m: Int, _ b: [Float], _ n: Int, _ k: Int, into c: inout [Float]) {
        #if canImport(Accelerate)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(m), Int32(n), Int32(k), 1, a, Int32(k), b, Int32(k), 0, &c, Int32(n))
        #else
        for i in 0..<m { for j in 0..<n {
            var s: Float = 0
            for t in 0..<k { s += a[i * k + t] * b[j * k + t] }
            c[i * n + j] = s
        }}
        #endif
    }

    // MARK: Using links

    /// What a photo's matches add to it: their clues as extra log-likelihood, season votes, and dates.
    public struct Pull: Sendable {
        public var logLikelihood: [Double]
        public var seasonVotes: [Season: Double]
        public var exactDates: [DateEvidence]
        public var matchCount: Int
    }

    /// Each linked photo's pull from its matches, tempered so several near-copies don't count as several
    /// independent witnesses. Hard limits (a scan date, a birth year) stay with the photo they belong
    /// to, so one wrong match can't make a date impossible.
    public static func pulls(evidence: [String: [DateEvidence]], links: [String: [Link]],
                             options: EvidenceFusion.Options = .init()) -> [String: Pull] {
        var soft: [String: [Double]] = [:]
        func softLL(_ id: String) -> [Double]? {
            if let cached = soft[id] { return cached }
            guard let e = evidence[id] else { return nil }
            let ll = EvidenceFusion.combinedLogLikelihood(e.filter { !$0.isHardConstraint }, options: options)
            soft[id] = ll
            return ll
        }
        var out: [String: Pull] = [:]
        for (id, matches) in links where evidence[id] != nil {
            let usable = matches.filter { evidence[$0.assetID] != nil }
            guard !usable.isEmpty else { continue }
            let temper = 1 / Double(usable.count).squareRoot()
            var pull = Pull(logLikelihood: [Double](repeating: 0, count: options.maxYear - options.minYear + 1),
                            seasonVotes: [:], exactDates: [], matchCount: usable.count)
            for m in usable {
                guard let ll = softLL(m.assetID), let theirs = evidence[m.assetID] else { continue }
                let s = m.weight * temper
                for i in ll.indices { pull.logLikelihood[i] += ll[i] * s }
                for e in theirs where e.seasonWeight > 0 {
                    if let season = e.season { pull.seasonVotes[season, default: 0] += e.seasonWeight * s }
                }
                // A printed date on one photo of a roll is good for its close matches too.
                if m.weight >= 0.7 { pull.exactDates += theirs.filter { $0.exactMonth != nil && $0.hasYearInfo } }
            }
            out[id] = pull
        }
        return out
    }

    /// Estimates for linked photos (photos without links aren't returned).
    public static func estimates(evidence: [String: [DateEvidence]], links: [String: [Link]],
                                 options: EvidenceFusion.Options = .init()) -> [String: DateEstimate] {
        var out: [String: DateEstimate] = [:]
        for (id, pull) in pulls(evidence: evidence, links: links, options: options) {
            guard let own = evidence[id] else { continue }
            out[id] = EvidenceFusion.estimate(from: own, extraLogLikelihood: pull.logLikelihood,
                                              extraSeasonVotes: pull.seasonVotes,
                                              extraExactDateCandidates: pull.exactDates, options: options)
        }
        return out
    }
}

// MARK: - Matching dated photos

extension EventLinks {
    /// A photo with a trustworthy date that undated photos can be compared with.
    public struct Reference: Sendable {
        public var print: [Float]
        public var year: Int
        public var month: Int?
        /// Photos face groups (or people) in it.
        public var people: Set<String>
        /// Dated by the user with this app (a guess they approved) rather than by a camera.
        public var datedHere: Bool

        public init(print: [Float], year: Int, month: Int?, people: Set<String>, datedHere: Bool) {
            self.print = print
            self.year = year
            self.month = month
            self.people = people
            self.datedHere = datedHere
        }
    }

    /// Cutoffs measured on a real library (6,000 dated photos, 15.7 million pairs taken ≥2 years apart):
    /// none of those pairs came closer than 0.35, while 157 same-year pairs did (duplicates, burst
    /// shots). At 0.40, about one false match per 6 photos would appear against a 180,000-photo pool.
    public static let nearDuplicateCutoff: Float = 0.35
    /// A looser match counts only when the same person is in both photos.
    public static let samePersonCutoff: Float = 0.5

    /// The best dated match for each undated photo, as a clue. Only near-duplicates, or close matches
    /// that share a person, are used: anything looser is mostly coincidence at library scale.
    ///
    /// The same rule as comparing each photo with each candidate in turn, but the distances come
    /// from one matrix multiply per 256 photos (shared with the near-duplicate search): candidates
    /// that can't be close enough are skipped on that, and the rest are confirmed with `distance`,
    /// so the clues are exactly the same. Tens of times faster on a big library.
    public static func referenceEvidence(undated: [String: [Float]], people: [String: Set<String>],
                                         references: [String: Reference]) -> [String: DateEvidence] {
        let refIDs = Array(references.keys)
        let refs = refIDs.map { references[$0]! }
        var byPerson: [String: [Int]] = [:]
        var datedHere: [Int] = []
        for (j, ref) in refs.enumerated() {
            for p in ref.people { byPerson[p, default: []].append(j) }
            if ref.datedHere { datedHere.append(j) }
        }
        // The matrix needs every print the same length (as `nearestDuplicates` does); otherwise
        // there are no near-duplicates and every candidate is measured directly.
        let dim = refs.first?.print.count ?? 0
        let useMatrix = dim > 0 && refs.allSatisfy { $0.print.count == dim }
        let refMatrix = useMatrix ? refs.flatMap(\.print) : []
        let refNorms = refs.map { r in r.print.reduce(0) { $0 + $1 * $1 } }
        let maxDot = 1 - nearDuplicateCutoff * nearDuplicateCutoff / 2 - 0.02
        // Nothing farther than the looser cutoff can count; the slack covers rounding in the multiply.
        let reach = samePersonCutoff * samePersonCutoff + 0.01

        var out: [String: DateEvidence] = [:]
        var seen = [Int](repeating: -1, count: refs.count) // which photo last looked at each candidate
        var photoNumber = 0

        /// One photo, with its dot products against every reference (nil: measure each directly).
        func decide(_ id: String, _ print: [Float], dots: ArraySlice<Float>?) {
            photoNumber += 1
            let who = people[id] ?? []
            var best: (distance: Float, ref: Reference)?
            // A dated duplicate counts even when nobody recognizable is in it (a landscape, a pet):
            // the reference with the largest dot product, as `nearestDuplicates` picks it.
            if let dots {
                var bestDot: Float = -2, bestJ = -1
                for j in 0..<refs.count where dots[dots.startIndex + j] > bestDot {
                    bestDot = dots[dots.startIndex + j]
                    bestJ = j
                }
                if bestJ >= 0, bestDot >= maxDot, refIDs[bestJ] != id {
                    let d = distance(print, refs[bestJ].print)
                    if d < nearDuplicateCutoff { best = (d, refs[bestJ]) }
                }
            }
            let norm = print.reduce(0) { $0 + $1 * $1 }
            func consider(_ j: Int) {
                guard seen[j] != photoNumber else { return }
                seen[j] = photoNumber
                guard refIDs[j] != id else { return }
                if let dots, norm + refNorms[j] - 2 * dots[dots.startIndex + j] > reach { return }
                let ref = refs[j]
                let d = distance(print, ref.print)
                let shared = !who.isDisjoint(with: ref.people)
                guard d < nearDuplicateCutoff || (shared && d < samePersonCutoff) else { return }
                if best == nil || d < best!.distance { best = (d, ref) }
            }
            for j in datedHere { consider(j) }
            for p in who { for j in byPerson[p] ?? [] { consider(j) } }
            guard let best else { return }
            let ref = best.ref
            let when = ref.month.map { "\(DateEstimate.monthNames[max(1, min(12, $0)) - 1]) \(ref.year)" } ?? "\(ref.year)"
            let source = ref.datedHere ? " (a date you applied)" : ""
            if best.distance < nearDuplicateCutoff {
                out[id] = DateEvidence(source: .group,
                                       summary: "Almost identical to a dated photo from \(when)\(source): likely the same picture",
                                       yearLow: ref.year, yearHigh: ref.year, peakYear: ref.year,
                                       weight: ref.datedHere ? 0.6 : 0.9,
                                       season: ref.month.map(Season.from(month:)), seasonWeight: ref.month == nil ? 0 : 0.8,
                                       exactMonth: ref.datedHere ? nil : ref.month)
            } else {
                out[id] = DateEvidence(source: .group,
                                       summary: "Looks a lot like a dated photo of the same person from \(when)\(source)",
                                       yearLow: ref.year - 1, yearHigh: ref.year + 1, peakYear: ref.year,
                                       weight: ref.datedHere ? 0.3 : 0.45)
            }
        }

        let matched = useMatrix ? undated.keys.filter { undated[$0]?.count == dim } : []
        let chunk = 256
        for start in stride(from: 0, to: matched.count, by: chunk) {
            // A newer run replaced this one: stop (the caller throws the result away).
            if Task.isCancelled { return [:] }
            let ids = Array(matched[start..<min(matched.count, start + chunk)])
            let rows = ids.flatMap { undated[$0]! }
            var dots = [Float](repeating: 0, count: ids.count * refs.count)
            multiplyTransposed(rows, ids.count, refMatrix, refs.count, dim, into: &dots)
            for (i, id) in ids.enumerated() {
                decide(id, undated[id]!, dots: dots[(i * refs.count)..<((i + 1) * refs.count)])
            }
        }
        let inMatrix = Set(matched)
        for (id, print) in undated where !inMatrix.contains(id) {
            if Task.isCancelled { return [:] }
            decide(id, print, dots: nil)
        }
        return out
    }

    /// The first version of `referenceEvidence`, one photo and one distance at a time (about 45 s on
    /// 15,000 undated photos). Kept only so the tests can check the fast version gives the same clues.
    static func referenceEvidenceOneByOne(undated: [String: [Float]], people: [String: Set<String>],
                                         references: [String: Reference]) -> [String: DateEvidence] {
        var byPerson: [String: [String]] = [:]
        var datedHere: [String] = []
        for (id, ref) in references {
            for p in ref.people { byPerson[p, default: []].append(id) }
            if ref.datedHere { datedHere.append(id) }
        }
        let duplicates = nearestDuplicates(undated: undated, references: references)
        var out: [String: DateEvidence] = [:]
        for (id, print) in undated {
            // A newer run replaced this one: stop (the caller throws the result away).
            if Task.isCancelled { return [:] }
            let who = people[id] ?? []
            var candidates = Set(datedHere)
            for p in who { candidates.formUnion(byPerson[p] ?? []) }
            var best: (distance: Float, ref: Reference)?
            // A dated duplicate counts even when nobody recognizable is in it (a landscape, a pet).
            if let dup = duplicates[id], let ref = references[dup.id] { best = (dup.distance, ref) }
            for c in candidates where c != id {
                guard let ref = references[c] else { continue }
                let d = distance(print, ref.print)
                let shared = !who.isDisjoint(with: ref.people)
                guard d < nearDuplicateCutoff || (shared && d < samePersonCutoff) else { continue }
                if best == nil || d < best!.distance { best = (d, ref) }
            }
            guard let best else { continue }
            let ref = best.ref
            let when = ref.month.map { "\(DateEstimate.monthNames[max(1, min(12, $0)) - 1]) \(ref.year)" } ?? "\(ref.year)"
            let source = ref.datedHere ? " (a date you applied)" : ""
            if best.distance < nearDuplicateCutoff {
                out[id] = DateEvidence(source: .group,
                                       summary: "Almost identical to a dated photo from \(when)\(source): likely the same picture",
                                       yearLow: ref.year, yearHigh: ref.year, peakYear: ref.year,
                                       weight: ref.datedHere ? 0.6 : 0.9,
                                       season: ref.month.map(Season.from(month:)), seasonWeight: ref.month == nil ? 0 : 0.8,
                                       exactMonth: ref.datedHere ? nil : ref.month)
            } else {
                out[id] = DateEvidence(source: .group,
                                       summary: "Looks a lot like a dated photo of the same person from \(when)\(source)",
                                       yearLow: ref.year - 1, yearHigh: ref.year + 1, peakYear: ref.year,
                                       weight: ref.datedHere ? 0.3 : 0.45)
            }
        }
        return out
    }
}
