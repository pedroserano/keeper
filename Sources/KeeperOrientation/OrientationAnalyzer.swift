// Runs the detectors over one photo and decides whether it needs turning. Adapted from
// ApplePhotosRotator (Detection/OrientationAnalyzer.swift and Library/PhotoLibrary.swift).

import CoreGraphics
import ImageIO
import Foundation
import Vision
import KeeperKit

/// Detectors run in stages, cheapest first. A photo that is confidently upright stops early, which
/// matters when the same work is repeated for every photo in a library. A proposed turn never stops
/// early: every cue gets a say, so a person lying down in an upright photo, or a sign the network
/// misreads, can outvote it.
/// Which cues to use; Keeper uses `standard`, the evaluation tool tries others.
public enum Cue: String, CaseIterable, Sendable {
    case faces, body, network, animals, people, horizon, text

    public static let standard: Set<Cue> = [.faces, .body, .network, .text]
}

public struct OrientationAnalyzer: Sendable {
    var stages: [[any OrientationDetector]]
    public var decider = OrientationDecider(minimumStrength: 0.3, minimumConfidence: 0.2)
    /// Stop after a stage once the photo is judged upright with at least this confidence.
    var earlyExitConfidence = 0.8

    public struct Result: Sendable {
        public var decision: OrientationDecision
        public var evidence: [DetectorEvidence]

        /// A compact summary such as `faces 90°:0.97 · text 90°:0.40`.
        public var summary: String {
            evidence.compactMap { e -> String? in
                guard let best = Rotation.allCases.max(by: { e.score(for: $0) < e.score(for: $1) }),
                      e.score(for: best) > 0.05 else { return nil }
                return "\(e.detector) \(best.degrees)°:\(String(format: "%.2f", e.score(for: best)))"
            }.joined(separator: " · ")
        }
    }

    /// Faces first (one Vision request, usually decisive), then body pose and the network together
    /// (both look at all four orientations, so they share the passes), then text.
    public init(network: OrientationNetwork?, cues: Set<Cue> = Cue.standard) {
        var stages: [[any OrientationDetector]] = []
        if cues.contains(.faces) { stages.append([FaceDetector()]) }
        // These look at all four orientations, so they share one set of passes.
        var fourPass: [any OrientationDetector] = []
        if cues.contains(.body) { fourPass.append(BodyPoseDetector()) }
        if cues.contains(.network), let network { fourPass.append(OrientationNetDetector(network: network)) }
        if cues.contains(.animals) { fourPass.append(AnimalDetector()) }
        if cues.contains(.people) { fourPass.append(UpperBodyDetector()) }
        if cues.contains(.horizon) { fourPass.append(HorizonDetector()) }
        if !fourPass.isEmpty { stages.append(fourPass) }
        if cues.contains(.text) { stages.append([TextDetector()]) }
        self.stages = stages
    }

    /// Every cue's evidence with no early stop, for the evaluation tool.
    public func allEvidence(_ image: CGImage) throws -> [DetectorEvidence] {
        try stages.flatMap { try run($0, on: image) }
    }

    public func analyze(_ image: CGImage) throws -> Result {
        var evidence: [DetectorEvidence] = []
        var decision = decider.decide([])
        for stage in stages {
            evidence += try run(stage, on: image)
            decision = decider.decide(evidence)
            if decision.status == .upright && decision.confidence >= earlyExitConfidence { break }
        }
        return Result(decision: decision, evidence: evidence)
    }

    /// One `VNImageRequestHandler` per candidate orientation, with all of a stage's requests performed
    /// together so Vision prepares each oriented image only once. Detectors that run once only take
    /// part in the first pass.
    private func run(_ detectors: [any OrientationDetector], on image: CGImage) throws -> [DetectorEvidence] {
        var scores = Array(repeating: [Rotation: Double](), count: detectors.count)
        let passes: [Rotation] = detectors.allSatisfy(\.runsOnce) ? [.none] : Rotation.allCases
        for pass in passes {
            let active = detectors.indices.filter { pass == .none || !detectors[$0].runsOnce }
            let size = pass.swapsDimensions
                ? CGSize(width: image.height, height: image.width)
                : CGSize(width: image.width, height: image.height)
            let requests = active.map { detectors[$0].makeRequests() }
            let handler = VNImageRequestHandler(cgImage: image, orientation: pass.cgOrientation, options: [:])
            try handler.perform(requests.flatMap { $0 })
            for (detectorRequests, i) in zip(requests, active) {
                scores[i].merge(detectors[i].uprightScores(of: detectorRequests, image: image, frameSize: size,
                                                           pass: pass)) { $0 + $1 }
            }
        }
        return detectors.enumerated().map { i, d in
            DetectorEvidence(detector: d.name, weight: d.weight, uprightScores: d.finalScores(scores[i]))
        }
    }
}

extension Rotation {
    /// The EXIF orientation whose display transform is this clockwise rotation (as Vision and
    /// CIImage.oriented use it), so what was analysed is exactly what gets applied.
    public var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .none: .up
        case .clockwise90: .right
        case .rotate180: .down
        case .clockwise270: .left
        }
    }
}
