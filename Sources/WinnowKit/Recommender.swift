// Suggestions from Apple Photos' own scores: a star rating relative to the rest of your library,
// and reasons a photo might be worth rejecting. Winnow only suggests; you decide.
//
// Stars come from Photos' curation score. Measured against the Favorites in a large
// library, curation ranked Favorites above other photos 99% of the time; the overall aesthetic
// score managed 51%, no better than chance. (Curation likely counts favoriting itself, so the 99%
// overstates it, but nothing else came close.) Libraries without curation fall back to overall.

import WinnowCore

public enum Reason: String, Sendable, CaseIterable {
    case screenshot = "Screenshot"
    case failed = "Failed shot"
    case blurry = "Blurry"
    case exposure = "Poor exposure"
    case noisy = "Noisy"
    case lowScore = "Low Photos score"
}

public struct Suggestion: Sendable, Equatable {
    /// 1–5, from where the photo's curation score falls in this library. 0 = no score.
    public let stars: Int
    public let reasons: [Reason]
    /// For ordering: the score the stars come from, 0…1.
    public let keep: Double

    public var suggestsReject: Bool { !reasons.isEmpty }
}

public struct Recommender: Sendable {
    /// First-guess thresholds on Apple's scores. Raw values show in the app (I) so they can be tuned.
    public enum Threshold {
        public static let failure = -0.25    // ZFAILURESCORE, 0 = fine, −1 = failed
        public static let blurriness = 0.3   // ZBLURRINESSSCORE, library average is about 0.88
        /// A photo whose subject scores at least this sharp isn't blurry, however soft the rest is.
        public static let sharpSubject = 0.2 // ZSHARPLYFOCUSEDSUBJECTSCORE, 0…0.88
        /// Nor is one whose blur Photos considers deliberate (bokeh, motion pans).
        public static let tastefulBlur = 0.1 // ZTASTEFULLYBLURREDSCORE, −1…1
        public static let exposure = 0.3     // ZEXPOSURESCORE, library average is about 0.86
        public static let noise = -0.5       // ZNOISESCORE, 0 = clean, −1 = noisy
    }

    /// Percentiles of the score that separate 1★|2★|3★|4★|5★.
    public static let starPercentiles = [0.10, 0.30, 0.70, 0.90]

    public let scores: [String: AppleScores]
    public let screenshots: Set<String>
    /// Score cut-offs at `starPercentiles`, over analysed photos only.
    public let cutoffs: [Double]
    public let analysedCount: Int

    /// The score stars and ordering come from: curation, or overall where there's no curation.
    public static func basis(_ s: AppleScores) -> Double? { s.curation ?? s.overall }

    public init(scores: [String: AppleScores], screenshots: Set<String> = []) {
        self.scores = scores
        self.screenshots = screenshots
        let values = scores.values.filter(\.isAnalysed).compactMap(Self.basis).sorted()
        analysedCount = values.count
        // Nearest-rank: the bottom 10% of photos sit below the first cut-off, and so on.
        cutoffs = values.isEmpty ? [] : Self.starPercentiles.map {
            values[min(Int(Double(values.count) * $0), values.count - 1)]
        }
    }

    /// False when Photos hasn't analysed the library yet: nothing analysed, or every score the
    /// same placeholder value.
    public var hasScores: Bool {
        guard analysedCount > 0, let lo = cutoffs.first, let hi = cutoffs.last else { return false }
        return lo != hi
    }

    public func suggestion(forUUID uuid: String) -> Suggestion? {
        let isScreenshot = screenshots.contains(uuid)
        guard hasScores, let s = scores[uuid], s.isAnalysed, let score = Self.basis(s) else {
            return isScreenshot ? Suggestion(stars: 0, reasons: [.screenshot], keep: 0) : nil
        }
        let stars = 1 + cutoffs.filter { score >= $0 }.count

        var reasons: [Reason] = []
        if isScreenshot { reasons.append(.screenshot) }
        if let f = s.failure, f <= Threshold.failure { reasons.append(.failed) }
        // Blurriness measures the whole frame, so a portrait's soft background reads as blurry.
        // Only call it blurry when the subject isn't sharp and the blur doesn't look intentional.
        if let b = s.blurriness, b <= Threshold.blurriness,
           (s.sharpSubject ?? 0) < Threshold.sharpSubject,
           (s.tastefullyBlurred ?? 0) < Threshold.tastefulBlur {
            reasons.append(.blurry)
        }
        if let e = s.exposure, e <= Threshold.exposure { reasons.append(.exposure) }
        if let n = s.noise, n <= Threshold.noise { reasons.append(.noisy) }
        if score < cutoffs[0] { reasons.append(.lowScore) }
        return Suggestion(stars: stars, reasons: reasons, keep: score)
    }

    /// How many photos have a reject suggestion, and how many are suggested 5★.
    public func counts() -> (rejects: Int, best: Int) {
        var rejects = 0, best = 0
        for uuid in Set(scores.keys).union(screenshots) {
            guard let s = suggestion(forUUID: uuid) else { continue }
            if s.suggestsReject { rejects += 1 }
            if s.stars == 5 && !s.suggestsReject { best += 1 }
        }
        return (rejects, best)
    }
}
