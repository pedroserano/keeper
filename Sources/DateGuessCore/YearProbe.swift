import Foundation

/// "Looks most like your photos from 2002–2004": compares a photo's image fingerprint with the
/// user's own dated photos and takes the years of the closest ones.
///
/// This catches the look of a period in one library (which cameras, what resolution and colors,
/// which places and people) rather than near-copies, which `EventLinks` already handles. Research on
/// dating photos found that a model trained on image features of dated photos does much better than
/// asking a general model what decade something looks like.
public struct YearProbe: Sendable {
    public struct Example: Sendable {
        public var id: String
        public var year: Int
        public var print: [Float]

        public init(id: String, year: Int, print: [Float]) {
            self.id = id
            self.year = year
            self.print = print
        }
    }

    /// How many of the closest dated photos vote.
    public static let neighbors = 15
    /// Fewer dated photos than this aren't enough to learn from.
    public static let minimumExamples = 50

    let ids: [String]
    let years: [Int]
    let matrix: [Float]
    let dim: Int

    public init(_ examples: [Example]) {
        let dim = examples.first?.print.count ?? 0
        let usable = examples.filter { $0.print.count == dim && dim > 0 }
        self.dim = dim
        ids = usable.map(\.id)
        years = usable.map(\.year)
        matrix = usable.flatMap { Self.normalized($0.print) }
    }

    public var count: Int { ids.count }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    /// A clue for each photo whose closest dated photos mostly agree. `maxWeight` is what a clue
    /// gets when all of them are within a year of each other.
    public func evidence(for queries: [String: [Float]], maxWeight: Double = 0.5) -> [String: DateEvidence] {
        guard count >= Self.minimumExamples else { return [:] }
        let queryIDs = queries.keys.filter { queries[$0]?.count == dim }.sorted()
        let n = count
        var out: [String: DateEvidence] = [:]
        let chunk = 256
        for start in stride(from: 0, to: queryIDs.count, by: chunk) {
            if Task.isCancelled { return [:] } // a newer run replaced this one
            let batch = Array(queryIDs[start..<min(queryIDs.count, start + chunk)])
            let rows = batch.flatMap { Self.normalized(queries[$0]!) }
            var dots = [Float](repeating: 0, count: batch.count * n)
            EventLinks.multiplyTransposed(rows, batch.count, matrix, n, dim, into: &dots)
            for (i, id) in batch.enumerated() {
                let best = Self.top(dots, row: i, n: n, k: Self.neighbors) { ids[$0] != id }
                if let e = Self.clue(best.map { (years[$0.index], Double(max(0, $0.dot))) }, maxWeight: maxWeight) {
                    out[id] = e
                }
            }
        }
        return out
    }

    /// The `k` best matches in one row of `dots`, skipping any `allowed` rejects (the photo itself).
    static func top(_ dots: [Float], row: Int, n: Int, k: Int, allowed: (Int) -> Bool) -> [(index: Int, dot: Float)] {
        var best: [(index: Int, dot: Float)] = []
        best.reserveCapacity(k + 1)
        var floor: Float = -.infinity
        let base = row * n
        for j in 0..<n {
            let d = dots[base + j]
            guard d > floor || best.count < k, allowed(j) else { continue }
            let at = best.firstIndex { $0.dot < d } ?? best.count
            best.insert((j, d), at: at)
            if best.count > k { best.removeLast() }
            if best.count == k { floor = best[k - 1].dot }
        }
        return best
    }

    /// Weighted years of the closest dated photos → one soft clue. Closer photos count much more.
    static func clue(_ votes: [(year: Int, similarity: Double)], maxWeight: Double) -> DateEvidence? {
        let weighted = votes.map { ($0.year, pow($0.similarity, 4)) }.filter { $0.1 > 0 }.sorted { $0.0 < $1.0 }
        let total = weighted.reduce(0) { $0 + $1.1 }
        guard weighted.count >= 3, total > 0 else { return nil }
        func quantile(_ q: Double) -> Int {
            var sum = 0.0
            for (year, w) in weighted {
                sum += w
                if sum >= q * total { return year }
            }
            return weighted.last!.0
        }
        let middle = quantile(0.5), low = quantile(0.2), high = quantile(0.8)
        let agreement = weighted.filter { abs($0.0 - middle) <= 1 }.reduce(0) { $0 + $1.1 } / total
        guard agreement >= 0.4 else { return nil }
        let range = low == high ? "\(low)" : "\(low)–\(high)"
        return DateEvidence(source: .scene,
                            summary: "Looks most like your dated photos from \(range)",
                            yearLow: low, yearHigh: high, peakYear: middle,
                            weight: maxWeight * agreement)
    }
}
