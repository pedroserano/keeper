// Neighbouring shots agree: a photo taken seconds after an upright photo of the same scene should
// look like it. If it only looks like it once turned, that turn is the evidence. Built on Vision
// feature prints, compared by cosine distance like Duplicates and Similar Shots.

import Foundation

public enum NeighbourCue {
    public static let detector = "neighbours"
    /// How far apart in time two photos can be and still count as neighbours.
    public static let window: TimeInterval = 60

    /// Tuning, measured with orientation-eval's `--neighbours` run.
    public struct Parameters: Sendable, Equatable {
        /// The best turn must be at least this close to a neighbour: the same scene, not just similar light.
        public var limit: Float
        /// The best turn's lead over the runner-up that earns a full vote.
        public var fullMargin: Float
        public var weight: Double

        public init(limit: Float, fullMargin: Float, weight: Double) {
            self.limit = limit
            self.fullMargin = fullMargin
            self.weight = weight
        }

        public static let standard = Parameters(limit: 0.25, fullMargin: 0.15, weight: 1.0)
    }

    /// Evidence for each correction, from the photo's feature prints taken after each candidate turn
    /// (`prints[r]` = the photo turned by r) and the prints of neighbours known to be upright. Nil when
    /// there's no neighbour close enough to say anything.
    public static func evidence(prints: [Rotation: [Float]], neighbours: [[Float]],
                                parameters: Parameters = .standard) -> DetectorEvidence? {
        guard !neighbours.isEmpty, Rotation.allCases.allSatisfy({ prints[$0] != nil }) else { return nil }
        let others = neighbours.map(FeatureVector.init)
        var distance: [Rotation: Float] = [:]
        for r in Rotation.allCases {
            let v = FeatureVector(prints[r]!)
            distance[r] = others.map { v.distance(to: $0) }.min()!
        }
        let ranked = Rotation.allCases.sorted { distance[$0]! < distance[$1]! }
        let best = distance[ranked[0]]!, second = distance[ranked[1]]!
        guard best <= parameters.limit else { return nil }
        let score = Double(min(max((second - best) / parameters.fullMargin, 0), 1))
        guard score > 0 else { return nil }
        return DetectorEvidence(detector: detector, weight: parameters.weight, uprightScores: [ranked[0]: score])
    }
}
