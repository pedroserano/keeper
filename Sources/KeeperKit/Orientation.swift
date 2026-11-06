// Deciding which way up a photo is, from the cues the detectors find (faces, people, text, the
// orientation network). Adapted from ApplePhotosRotator's RotatorCore (OrientationDecision,
// OrientationPrior and OrientationClassifier.passScores).

import Foundation

/// Evidence from one detector (faces, body pose, text, …).
///
/// The analyzer shows the detector the photo four times, once per candidate correction, and records how
/// strongly the photo looks upright after that correction. A value is in `0...1`, where 0 means "no upright
/// content found" and 1 means "certainly upright".
public struct DetectorEvidence: Sendable, Equatable {
    public var detector: String
    public var weight: Double
    public var uprightScores: [Rotation: Double]

    public init(detector: String, weight: Double, uprightScores: [Rotation: Double]) {
        self.detector = detector
        self.weight = weight
        self.uprightScores = uprightScores
    }

    public func score(for rotation: Rotation) -> Double {
        min(max(uprightScores[rotation] ?? 0, 0), 1)
    }
}

/// What the scan concluded about one photo.
public enum ScanStatus: Int, Sendable, Codable, CaseIterable {
    /// The photo already looks upright.
    case upright = 0
    /// The photo looks like it needs the proposed rotation.
    case needsRotation = 1
    /// Not enough evidence either way (for example, a landscape with no people or text).
    case inconclusive = 2
    /// No local image data (for example, iCloud-only with downloads disabled).
    case unavailable = 3
    /// Analysis failed.
    case failed = 4
}

public struct OrientationDecision: Sendable, Equatable {
    public var status: ScanStatus
    /// The best-supported correction (may be `.none`).
    public var rotation: Rotation
    /// How much the best correction beats the runner-up, scaled by how strong the evidence is; `0...1`.
    public var confidence: Double
    /// The combined, weighted score of the best correction.
    public var strength: Double

    public init(status: ScanStatus, rotation: Rotation, confidence: Double, strength: Double) {
        self.status = status
        self.rotation = rotation
        self.confidence = confidence
        self.strength = strength
    }
}

/// Fuses detector evidence into a single decision.
public struct OrientationDecider: Sendable {
    /// Below this combined score for the best candidate, the photo is `inconclusive`.
    public var minimumStrength: Double
    /// Below this confidence, a non-zero proposal is treated as `inconclusive` instead of `needsRotation`.
    /// The proposal is still reported so it can be stored and surfaced with a lower review threshold.
    public var minimumConfidence: Double

    public init(minimumStrength: Double = 0.3, minimumConfidence: Double = 0.2) {
        self.minimumStrength = minimumStrength
        self.minimumConfidence = minimumConfidence
    }

    public func decide(_ evidence: [DetectorEvidence]) -> OrientationDecision {
        var combined: [Rotation: Double] = [:]
        for rotation in Rotation.allCases {
            combined[rotation] = evidence.reduce(0) { $0 + $1.weight * $1.score(for: rotation) }
        }
        // Ties resolve toward `.none` so we never propose a change without a clear winner.
        let ranked = Rotation.allCases.sorted {
            let a = combined[$0]!, b = combined[$1]!
            return a != b ? a > b : $0.rawValue < $1.rawValue
        }
        let best = ranked[0]
        let bestScore = combined[best]!
        let secondScore = combined[ranked[1]]!

        guard bestScore >= minimumStrength else {
            return OrientationDecision(status: .inconclusive, rotation: .none, confidence: 0, strength: bestScore)
        }
        // Margin over the runner-up, normalised by the larger of the best score and 1 so weak evidence
        // (one blurry face) can't produce a high confidence just because everything else scored zero.
        let confidence = min(max((bestScore - secondScore) / max(bestScore, 1), 0), 1)

        if best == Rotation.none {
            return OrientationDecision(status: .upright, rotation: .none, confidence: confidence, strength: bestScore)
        }
        let status: ScanStatus = confidence >= minimumConfidence ? .needsRotation : .inconclusive
        return OrientationDecision(status: status, rotation: best, confidence: confidence, strength: bestScore)
    }
}

/// Combines independent probabilities: the chance that at least one piece of evidence is right.
public func noisyOr<S: Sequence>(_ probabilities: S) -> Double where S.Element == Double {
    1 - probabilities.reduce(1.0) { $0 * (1 - min(max($1, 0), 1)) }
}

/// How upright a feature is, given its angle (radians) away from vertical in the analysed frame.
/// Returns `cos(angle)` within `tolerance`, otherwise 0.
public func uprightFactor(angleFromVertical angle: Double, toleranceDegrees tolerance: Double) -> Double {
    var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
    if a > .pi { a -= 2 * .pi }
    if a < -.pi { a += 2 * .pi }
    guard abs(a) <= tolerance * .pi / 180 else { return 0 }
    return cos(a)
}

/// How common each correction is in a real photo library, before looking at the photo.
///
/// The orientation network was trained with all four turns equally likely, so its probabilities assume a quarter of
/// all photos are upside down. In a real library almost every photo is upright, sideways photos are occasional and
/// upside-down ones rare. Re-weighting by these odds (Bayes' rule) stops the network from proposing a rare turn
/// unless it is very sure.
public struct OrientationPrior: Sendable, Equatable {
    public var upright: Double
    /// For each sideways direction (90° and 270° separately).
    public var sideways: Double
    public var upsideDown: Double

    public init(upright: Double, sideways: Double, upsideDown: Double) {
        self.upright = upright
        self.sideways = sideways
        self.upsideDown = upsideDown
    }

    /// The odds the network was trained with.
    public static let equal = OrientationPrior(upright: 0.25, sideways: 0.25, upsideDown: 0.25)

    public func probability(of rotation: Rotation) -> Double {
        switch rotation {
        case .none: return upright
        case .clockwise90, .clockwise270: return sideways
        case .rotate180: return upsideDown
        }
    }

    /// Re-weights scores from a model trained with equal odds, keeping their total.
    public func apply(to scores: [Rotation: Double]) -> [Rotation: Double] {
        let total = scores.values.reduce(0, +)
        var weighted: [Rotation: Double] = [:]
        for rotation in Rotation.allCases {
            weighted[rotation] = (scores[rotation] ?? 0) * probability(of: rotation) / 0.25
        }
        let weightedTotal = weighted.values.reduce(0, +)
        guard weightedTotal > 0 else { return scores }
        return weighted.mapValues { $0 * total / weightedTotal }
    }
}

/// Scores for each correction from one pass of a four-orientation classifier, for averaging over the
/// four passes. In the pass where Vision turned the photo by `pass`, output `c` means the photo needs
/// `pass + c` overall; averaging over all four cancels out the model's own direction biases.
public func passScores(_ probabilities: [Double], pass: Rotation, passCount: Int = 4) -> [Rotation: Double] {
    var scores: [Rotation: Double] = [:]
    for (c, p) in probabilities.enumerated() {
        scores[Rotation(degrees: pass.degrees + 90 * c), default: 0] += p / Double(passCount)
    }
    return scores
}
