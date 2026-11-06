// Learns your taste from the star ratings you've given in Photos: which mix of Apple's scores
// best predicts the rating you'd give. Measured on ratings it wasn't fitted to, and only used
// when it beats Photos' curation score on its own.

import Foundation
import KeeperCore

public struct RatedPhoto: Sendable {
    public let uuid: String
    public let scores: AppleScores
    public let rating: Int

    public init(uuid: String, scores: AppleScores, rating: Int) {
        self.uuid = uuid
        self.scores = scores
        self.rating = rating
    }
}

public struct RatingModel: Sendable {
    /// Fewer ratings than this, or fewer than 3 different star values, and the model isn't used.
    public static let minimumRatings = 50
    public static let features = Calibration.signals

    let means: [Double]
    let deviations: [Double]
    /// One per feature, on standardised scores: which of Apple's scores move your rating, and which way.
    public let weights: [Double]
    let bias: Double

    /// Standardised feature vector. A missing score counts as average.
    func vector(_ s: AppleScores) -> [Double] {
        Self.features.indices.map { i in
            let v = s[keyPath: Self.features[i].1] ?? means[i]
            return deviations[i] > 0 ? (v - means[i]) / deviations[i] : 0
        }
    }

    /// The rating this model expects you'd give, on your 1–5 scale (not rounded).
    public func predict(_ s: AppleScores) -> Double {
        bias + zip(weights, vector(s)).map(*).reduce(0, +)
    }

    /// Ridge regression on standardised scores; `ridge` keeps weights modest when ratings are few.
    public static func fit(_ photos: [RatedPhoto], ridge: Double = 5) -> RatingModel? {
        guard photos.count >= 10 else { return nil }
        let k = features.count
        var means = [Double](repeating: 0, count: k)
        var deviations = [Double](repeating: 0, count: k)
        for i in 0..<k {
            let values = photos.compactMap { $0.scores[keyPath: features[i].1] }
            guard !values.isEmpty else { continue }
            let m = values.reduce(0, +) / Double(values.count)
            means[i] = m
            deviations[i] = (values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(values.count)).squareRoot()
        }
        let shape = RatingModel(means: means, deviations: deviations, weights: [], bias: 0)
        let x = photos.map { shape.vector($0.scores) }
        let yMean = Double(photos.map(\.rating).reduce(0, +)) / Double(photos.count)
        let y = photos.map { Double($0.rating) - yMean }

        // (XᵀX + λI) w = Xᵀy
        var a = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var b = [Double](repeating: 0, count: k)
        for (row, target) in zip(x, y) {
            for i in 0..<k {
                b[i] += row[i] * target
                for j in 0..<k { a[i][j] += row[i] * row[j] }
            }
        }
        for i in 0..<k { a[i][i] += ridge }
        guard let w = solve(a, b) else { return nil }
        return RatingModel(means: means, deviations: deviations, weights: w, bias: yMean)
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var a = a, b = b
        let n = b.count
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }),
                  abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            b.swapAt(col, pivot)
            for r in (col + 1)..<n {
                let f = a[r][col] / a[col][col]
                for c in col..<n { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for c in (r + 1)..<n { s -= a[r][c] * x[c] }
            x[r] = s / a[r][r]
        }
        return x
    }
}

/// How well each way of ranking photos agrees with the ratings you actually gave.
/// Rank agreement (Spearman): 1 = same order as yours, 0 = unrelated.
public struct RatingEvaluation: Sendable, Equatable {
    public let rated: Int
    public let distinctRatings: Int
    /// The fitted model, measured only on ratings it wasn't fitted to (5-fold cross-validation).
    public let model: Double
    public let curation: Double
    public let overall: Double

    public var enoughRatings: Bool { rated >= RatingModel.minimumRatings && distinctRatings >= 3 }
    /// Use the model only when it clearly beats curation alone.
    public var modelWins: Bool { enoughRatings && model > curation + 0.02 }

    public static func evaluate(_ photos: [RatedPhoto], folds: Int = 5) -> RatingEvaluation {
        let distinct = Set(photos.map(\.rating)).count
        func agreement(_ pairs: [(Double, Double)]) -> Double {
            guard pairs.count >= 3 else { return 0 }
            let r = spearman(pairs)
            return r.isNaN ? 0 : r
        }
        // Deterministic folds from each photo's UUID, so the same ratings give the same answer.
        var predicted: [(Double, Double)] = []
        for fold in 0..<folds {
            let train = photos.filter { stableHash($0.uuid) % UInt64(folds) != UInt64(fold) }
            let test = photos.filter { stableHash($0.uuid) % UInt64(folds) == UInt64(fold) }
            guard let model = RatingModel.fit(train) else { continue }
            predicted += test.map { (model.predict($0.scores), Double($0.rating)) }
        }
        return RatingEvaluation(
            rated: photos.count,
            distinctRatings: distinct,
            model: agreement(predicted),
            curation: agreement(photos.compactMap { p in p.scores.curation.map { ($0, Double(p.rating)) } }),
            overall: agreement(photos.compactMap { p in p.scores.overall.map { ($0, Double(p.rating)) } }))
    }
}

/// FNV-1a: stable across launches, unlike `hashValue`.
public func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
    return h
}
