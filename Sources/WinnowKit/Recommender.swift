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
// The exception is duplicates and similar shots: the best of each group is kept, so the others
// are suggested even when they're precious.
//
// How readily photos are suggested as rejects is one setting, aggressiveness (0…1, 0.5 the
// default), which moves every reject threshold and how much curation protects together.

import WinnowCore

public enum Reason: String, Sendable, CaseIterable {
    case screenshot = "Screenshot"
    case failed = "Failed shot"
    case blurry = "Blurry"
    case exposure = "Poor exposure"
    case noisy = "Noisy"
    case lowScore = "Low score"
    case duplicate = "Duplicate"
    case similar = "Similar shot"
    /// Someone's eyes are closed, and another take of the moment has them open.
    case eyesClosed = "Eyes closed"
}

/// Where a photo sits in its look-alike group.
public struct GroupInfo: Sendable, Equatable {
    /// .duplicate when this photo is a near-identical copy of another in the group.
    public let kind: SimilarGroup.Kind
    public let size: Int
    /// The one to keep (see LookAlikes).
    public let isBest: Bool
}

public struct Suggestion: Sendable, Equatable {
    /// 1–5, from where the photo falls in this library. 0 = no score.
    public let stars: Int
    public let reasons: [Reason]
    /// For ordering: the score the stars come from.
    public let keep: Double
    /// Photos ranks this among the photos that matter most to you, so it isn't suggested as a reject.
    public let protected: Bool
    /// Set when the photo has duplicates or similar shots.
    public let group: GroupInfo?

    public init(stars: Int, reasons: [Reason], keep: Double, protected: Bool = false, group: GroupInfo? = nil) {
        self.stars = stars
        self.reasons = reasons
        self.keep = keep
        self.protected = protected
        self.group = group
    }

    /// Protection never covers a weaker copy: the best of its group is kept instead.
    public var suggestsReject: Bool {
        !reasons.isEmpty && (!protected || reasons.contains(.duplicate) || reasons.contains(.similar))
    }
}

public struct Recommender: Sendable {
    /// Cut-offs on Apple's scores for suggesting a reject. Raw values show in the app (I) so they can
    /// be tuned. Each moves with aggressiveness: conservative at 0, the defaults at 0.5, aggressive at 1.
    public struct Thresholds: Sendable, Equatable {
        public let failure: Double          // ZFAILURESCORE, 0 = fine, −1 = failed
        public let blurriness: Double       // ZBLURRINESSSCORE, library average is about 0.88
        /// A photo whose subject scores at least this sharp isn't blurry, however soft the rest is.
        public let sharpSubject = 0.2       // ZSHARPLYFOCUSEDSUBJECTSCORE, 0…0.88
        /// Nor is one whose blur Photos considers deliberate (bokeh, motion pans).
        public let tastefulBlur = 0.1       // ZTASTEFULLYBLURREDSCORE, −1…1
        public let exposure: Double         // ZEXPOSURESCORE, library average is about 0.86
        public let noise: Double            // ZNOISESCORE, 0 = clean, −1 = noisy
        /// Photos in the bottom this-fraction of the library are a "Low score".
        public let lowScorePercentile: Double
        /// Photos above this percentile by curation are protected from reject suggestions.
        public let protectPercentile: Double

        public init(aggressiveness a: Double = 0.5) {
            let a = min(max(a, 0), 1)
            func scale(_ conservative: Double, _ normal: Double, _ aggressive: Double) -> Double {
                a < 0.5 ? conservative + (normal - conservative) * a * 2 : normal + (aggressive - normal) * (a - 0.5) * 2
            }
            failure = scale(-0.4, -0.25, -0.1)
            blurriness = scale(0.15, 0.3, 0.45)
            exposure = scale(0.15, 0.3, 0.45)
            noise = scale(-0.7, -0.5, -0.3)
            lowScorePercentile = scale(0.03, 0.10, 0.25)
            protectPercentile = scale(0.55, 0.70, 0.90)
        }
    }

    /// Percentiles of the score that separate 1★|2★|3★|4★|5★.
    public static let starPercentiles = [0.10, 0.30, 0.70, 0.90]

    public let scores: [String: AppleScores]
    public let screenshots: Set<String>
    /// 0 = suggest rejects only when sure, 1 = suggest freely; 0.5 is the default.
    public let aggressiveness: Double
    public let thresholds: Thresholds
    public let faces: [String: FaceInfo]
    /// Your taste, when there's enough of it; nil means stars rank by curation.
    public let model: RatingModel?
    /// Score cut-offs at `starPercentiles`, over analysed photos only.
    public let cutoffs: [Double]
    /// Score below which a photo is a "Low score"; nil without scores.
    let lowScoreCutoff: Double?
    /// Curation at `protectPercentile`; nil when the library has no curation scores.
    public let protectCutoff: Double?
    public let analysedCount: Int
    public let groups: [SimilarGroup]
    public let files: [String: FileInfo]
    /// Duplicates and similar shots, the photo to keep first. A photo can be in one group of each kind.
    public let lookAlikes: [LookAlikeGroup]
    let duplicateIndex: [String: Int]
    let similarIndex: [String: Int]

    public init(scores: [String: AppleScores], screenshots: Set<String> = [], model: RatingModel? = nil,
                groups: [SimilarGroup] = [], files: [String: FileInfo] = [:], faces: [String: FaceInfo] = [:],
                aggressiveness: Double = 0.5) {
        self.scores = scores
        self.screenshots = screenshots
        self.faces = faces
        self.aggressiveness = aggressiveness
        let thresholds = Thresholds(aggressiveness: aggressiveness)
        self.thresholds = thresholds
        self.model = model
        self.groups = groups
        self.files = files
        let analysed = scores.values.filter(\.isAnalysed)
        func percentiles(_ values: [Double], _ ps: [Double]) -> [Double] {
            let sorted = values.sorted()
            // Nearest-rank: the bottom 10% of photos sit below the first cut-off, and so on.
            return sorted.isEmpty ? [] : ps.map { sorted[min(Int(Double(sorted.count) * $0), sorted.count - 1)] }
        }
        let basis: [Double] = analysed.compactMap { s in model.map { $0.predict(s) } ?? s.curation ?? s.overall }
        analysedCount = basis.count
        cutoffs = percentiles(basis, Self.starPercentiles)
        lowScoreCutoff = percentiles(basis, [thresholds.lowScorePercentile]).first
        protectCutoff = percentiles(analysed.compactMap(\.curation), [thresholds.protectPercentile]).first

        func score(_ uuid: String) -> Double {
            guard let s = scores[uuid], s.isAnalysed else { return -.infinity }
            return model.map { $0.predict(s) } ?? s.curation ?? s.overall ?? -.infinity
        }
        lookAlikes = LookAlikes.build(groups: groups, score: score, files: files, faces: faces)
        var duplicates: [String: Int] = [:], similar: [String: Int] = [:]
        for (i, g) in lookAlikes.enumerated() {
            for m in g.members {
                if g.kind == .duplicate { duplicates[m] = i } else { similar[m] = i }
            }
        }
        duplicateIndex = duplicates
        similarIndex = similar
    }

    /// The same suggestions with something changed; scores, screenshots, files and faces carry over.
    public func with(model: RatingModel?? = nil, groups: [SimilarGroup]? = nil, aggressiveness: Double? = nil) -> Recommender {
        Recommender(scores: scores, screenshots: screenshots, model: model ?? self.model, groups: groups ?? self.groups,
                    files: files, faces: faces, aggressiveness: aggressiveness ?? self.aggressiveness)
    }

    /// The photo's group of the given kind, if it has one.
    public func lookAlike(forUUID uuid: String, kind: SimilarGroup.Kind) -> LookAlikeGroup? {
        (kind == .duplicate ? duplicateIndex : similarIndex)[uuid].map { lookAlikes[$0] }
    }

    /// The groups of one kind.
    public func lookAlikes(_ kind: SimilarGroup.Kind) -> [LookAlikeGroup] {
        lookAlikes.filter { $0.kind == kind }
    }

    /// The photo's duplicates if it has any, otherwise its similar shots.
    public func group(forUUID uuid: String) -> GroupInfo? {
        (lookAlike(forUUID: uuid, kind: .duplicate) ?? lookAlike(forUUID: uuid, kind: .similar)).map {
            GroupInfo(kind: $0.kind, size: $0.members.count, isBest: $0.keeper == uuid)
        }
    }

    /// Duplicate and Similar shot, for each kind of group this photo isn't the one to keep in.
    func groupReasons(forUUID uuid: String) -> [Reason] {
        var out: [Reason] = []
        if let g = lookAlike(forUUID: uuid, kind: .duplicate), g.keeper != uuid { out.append(.duplicate) }
        if let g = lookAlike(forUUID: uuid, kind: .similar), g.keeper != uuid {
            out.append(.similar)
            if LookAlikes.blinks(in: g.members, faces: faces).contains(uuid) { out.append(.eyesClosed) }
        }
        return out
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
        let group = self.group(forUUID: uuid)
        let groupReasons = self.groupReasons(forUUID: uuid)
        guard hasScores, let s = scores[uuid], s.isAnalysed, let score = basis(s) else {
            let reasons = (isScreenshot ? [Reason.screenshot] : []) + groupReasons
            return reasons.isEmpty && group == nil ? nil
                : Suggestion(stars: 0, reasons: reasons, keep: 0, group: group)
        }
        let stars = 1 + cutoffs.filter { score >= $0 }.count

        var reasons: [Reason] = []
        if isScreenshot { reasons.append(.screenshot) }
        if let f = s.failure, f <= thresholds.failure { reasons.append(.failed) }
        // Blurriness measures the whole frame, so a portrait's soft background reads as blurry.
        // Only call it blurry when the subject isn't sharp and the blur doesn't look intentional.
        if let b = s.blurriness, b <= thresholds.blurriness,
           (s.sharpSubject ?? 0) < thresholds.sharpSubject,
           (s.tastefullyBlurred ?? 0) < thresholds.tastefulBlur {
            reasons.append(.blurry)
        }
        if let e = s.exposure, e <= thresholds.exposure { reasons.append(.exposure) }
        if let n = s.noise, n <= thresholds.noise { reasons.append(.noisy) }
        if let low = lowScoreCutoff, score < low { reasons.append(.lowScore) }
        reasons += groupReasons

        // Screenshots are never protected: they're rarely what anyone means by a keepsake.
        let protected = !isScreenshot && protectCutoff.map { (s.curation ?? -.infinity) >= $0 } == true
        return Suggestion(stars: stars, reasons: reasons, keep: score, protected: protected, group: group)
    }

    /// How many photos have a reject suggestion, and how many are suggested 5★.
    public func counts() -> (rejects: Int, best: Int) {
        var rejects = 0, best = 0
        for uuid in Set(scores.keys).union(screenshots).union(duplicateIndex.keys).union(similarIndex.keys) {
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
