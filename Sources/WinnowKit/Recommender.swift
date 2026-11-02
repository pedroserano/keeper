// Suggestions from Apple Photos' own scores: a star rating relative to the rest of your library,
// and reasons a photo might be worth rejecting. Winnow only suggests; you decide.
//
// What the stars rank by:
// - Your taste, once there's enough of it: a RatingModel fitted to the stars you've given in
//   Photos, used only when it beats curation on ratings it wasn't fitted to.
// - Until then, Photos' curation score. Against my Favorites, curation ranked them above other
//   photos 99% of the time; overall aesthetic managed 51%, no better than chance.
// - Libraries without curation fall back to overall.
//
// Curation also protects: it reflects what matters to you (people, favorites, sharing), not just
// how good a photo looks, so a photo Photos ranks highly is never put forward as a reject.

import WinnowCore

public enum Reason: String, Sendable, CaseIterable {
    case screenshot = "Screenshot"
    case failed = "Failed shot"
    case blurry = "Blurry"
    case exposure = "Poor exposure"
    case noisy = "Noisy"
    case lowScore = "Low score"
}

public struct Suggestion: Sendable, Equatable {
    /// 1–5, from where the photo falls in this library. 0 = no score.
    public let stars: Int
    public let reasons: [Reason]
    /// For ordering: the score the stars come from.
    public let keep: Double
    /// Photos ranks this among the photos that matter most to you, so it isn't suggested as a reject.
    public let protected: Bool

    public init(stars: Int, reasons: [Reason], keep: Double, protected: Bool = false) {
        self.stars = stars
        self.reasons = reasons
        self.keep = keep
        self.protected = protected
    }

    public var suggestsReject: Bool { !reasons.isEmpty && !protected }
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
        /// Photos in the top 30% by curation are protected from reject suggestions.
        public static let protectPercentile = 0.70
    }

    /// Percentiles of the score that separate 1★|2★|3★|4★|5★.
    public static let starPercentiles = [0.10, 0.30, 0.70, 0.90]

    public let scores: [String: AppleScores]
    public let screenshots: Set<String>
    /// Your taste, when there's enough of it; nil means stars rank by curation.
    public let model: RatingModel?
    /// Score cut-offs at `starPercentiles`, over analysed photos only.
    public let cutoffs: [Double]
    /// Curation at `protectPercentile`; nil when the library has no curation scores.
    public let protectCutoff: Double?
    public let analysedCount: Int

    public init(scores: [String: AppleScores], screenshots: Set<String> = [], model: RatingModel? = nil) {
        self.scores = scores
        self.screenshots = screenshots
        self.model = model
        let analysed = scores.values.filter(\.isAnalysed)
        func percentiles(_ values: [Double], _ ps: [Double]) -> [Double] {
            let sorted = values.sorted()
            // Nearest-rank: the bottom 10% of photos sit below the first cut-off, and so on.
            return sorted.isEmpty ? [] : ps.map { sorted[min(Int(Double(sorted.count) * $0), sorted.count - 1)] }
        }
        let basis: [Double] = analysed.compactMap { s in model.map { $0.predict(s) } ?? s.curation ?? s.overall }
        analysedCount = basis.count
        cutoffs = percentiles(basis, Self.starPercentiles)
        protectCutoff = percentiles(analysed.compactMap(\.curation), [Threshold.protectPercentile]).first
    }

    /// The score stars and ordering come from.
    public func basis(_ s: AppleScores) -> Double? {
        if let model, s.isAnalysed { return model.predict(s) }
        return s.curation ?? s.overall
    }

    /// False when Photos hasn't analysed the library yet: nothing analysed, or every score the
    /// same placeholder value.
    public var hasScores: Bool {
        guard analysedCount > 0, let lo = cutoffs.first, let hi = cutoffs.last else { return false }
        return lo != hi
    }

    public func suggestion(forUUID uuid: String) -> Suggestion? {
        let isScreenshot = screenshots.contains(uuid)
        guard hasScores, let s = scores[uuid], s.isAnalysed, let score = basis(s) else {
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

        // Screenshots are never protected: they're rarely what anyone means by a keepsake.
        let protected = !isScreenshot && protectCutoff.map { (s.curation ?? -.infinity) >= $0 } == true
        return Suggestion(stars: stars, reasons: reasons, keep: score, protected: protected)
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

    /// Photos to rate so the model can learn your taste: unrated, analysed, not screenshots,
    /// spread evenly across the whole range of scores (an equal number from each tenth), in a
    /// mixed order so good and bad come up alternately rather than in a run.
    public func calibrationSample(count: Int = 150, excluding rated: Set<String>) -> [String] {
        let candidates = scores.compactMap { uuid, s -> (uuid: String, score: Double)? in
            guard s.isAnalysed, !rated.contains(uuid), !screenshots.contains(uuid), let b = basis(s) else { return nil }
            return (uuid, b)
        }
        .sorted { $0.score < $1.score }
        guard !candidates.isEmpty else { return [] }
        let bins = 10, perBin = max(count / bins, 1)
        var picked: [String] = []
        for b in 0..<bins {
            let lo = candidates.count * b / bins, hi = candidates.count * (b + 1) / bins
            guard lo < hi else { continue }
            picked += candidates[lo..<hi].map(\.uuid).sorted { stableHash($0) < stableHash($1) }.prefix(perBin)
        }
        return picked.sorted { stableHash($0 + "order") < stableHash($1 + "order") }
    }
}
