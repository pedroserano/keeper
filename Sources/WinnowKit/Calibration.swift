// Which of Apple's scores agree with your own taste? Your Favorites are photos you've already
// said you love, so for each score, measure how well it ranks Favorites above everything else.

import WinnowCore

public struct SignalAgreement: Sendable, Equatable {
    public let signal: String
    /// Chance that a random Favorite scores higher than a random other photo.
    /// 0.5 = no better than a coin flip, 1 = perfect; below 0.5, the score runs the other way.
    public let auc: Double
    public let favorites: Int
    public let others: Int
    public let favoritesMean: Double
    public let othersMean: Double
}

public enum Calibration {
    public static let signals: [(String, KeyPath<AppleScores, Double?>)] = [
        ("overall", \.overall), ("curation", \.curation), ("failure", \.failure), ("noise", \.noise),
        ("blurriness", \.blurriness), ("exposure", \.exposure), ("sharpSubject", \.sharpSubject),
        ("composition", \.composition), ("lighting", \.lighting), ("tastefullyBlurred", \.tastefullyBlurred),
    ]

    /// One row per signal, best agreement first. Only analysed photos count.
    public static func agreement(scores: [String: AppleScores], favorites: Set<String>) -> [SignalAgreement] {
        signals.compactMap { name, path in
            var values: [(value: Double, favorite: Bool)] = []
            for (uuid, s) in scores where s.isAnalysed {
                if let v = s[keyPath: path] { values.append((v, favorites.contains(uuid))) }
            }
            return auc(name, values)
        }
        .sorted { abs($0.auc - 0.5) > abs($1.auc - 0.5) }
    }

    /// Mann–Whitney: AUC from the rank sum of the Favorites, with average ranks for ties.
    static func auc(_ name: String, _ values: [(value: Double, favorite: Bool)]) -> SignalAgreement? {
        let nFav = values.filter(\.favorite).count
        let nOther = values.count - nFav
        guard nFav > 0, nOther > 0 else { return nil }
        let sorted = values.sorted { $0.value < $1.value }
        var rankSum = 0.0
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1].value == sorted[i].value { j += 1 }
            let rank = Double(i + j) / 2 + 1
            for k in i...j where sorted[k].favorite { rankSum += rank }
            i = j + 1
        }
        let auc = (rankSum - Double(nFav) * Double(nFav + 1) / 2) / (Double(nFav) * Double(nOther))
        let favMean = values.filter(\.favorite).map(\.value).reduce(0, +) / Double(nFav)
        let otherMean = values.filter { !$0.favorite }.map(\.value).reduce(0, +) / Double(nOther)
        return SignalAgreement(signal: name, auc: auc, favorites: nFav, others: nOther,
                               favoritesMean: favMean, othersMean: otherMean)
    }
}
