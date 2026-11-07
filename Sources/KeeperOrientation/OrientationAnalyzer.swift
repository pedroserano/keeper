// Runs the detectors over one photo and decides whether it needs turning. Adapted from
// ApplePhotosRotator (Detection/OrientationAnalyzer.swift and Library/PhotoLibrary.swift).

import CoreGraphics
import ImageIO
import Foundation
import Vision
import KeeperKit

/// Which cues to use; Keeper uses `standard`, the evaluation tool tries others.
public enum Cue: String, CaseIterable, Sendable {
    case faces, body, network, animals, people, horizon, text

    public static let standard: Set<Cue> = [.faces, .body, .network, .text]
}

/// Vision feature prints of a photo, keyed by the turn Vision applied before taking it. `.none` is
/// the photo as it's shown; with the others, they feed the neighbouring-shot cue.
public typealias TurnedPrints = [Rotation: [Float]]

/// Detectors run in stages, cheapest first. A photo that is confidently upright stops early, which
/// matters when the same work is repeated for every photo in a library. A proposed turn never stops
/// early: every cue gets a say, so a person lying down in an upright photo, or a sign the network
/// misreads, can outvote it.
public struct OrientationAnalyzer: Sendable {
    var stages: [[any OrientationDetector]]
    /// Take feature prints, for neighbouring shots.
    var collectsPrints: Bool
    public var decider = OrientationDecider(minimumStrength: 0.3, minimumConfidence: 0.2)
    /// Stop after a stage once the photo is judged upright with at least this confidence.
    var earlyExitConfidence = 0.8

    public struct Result: Sendable {
        public var decision: OrientationDecision
        public var evidence: [DetectorEvidence]
        public var prints: TurnedPrints

        /// A compact summary such as `faces 90°:0.97 · text 90°:0.40`.
        public var summary: String { OrientationAnalyzer.summary(of: evidence) }
    }

    public static func summary(of evidence: [DetectorEvidence]) -> String {
        evidence.compactMap { e -> String? in
            guard let best = Rotation.allCases.max(by: { e.score(for: $0) < e.score(for: $1) }),
                  e.score(for: best) > 0.05 else { return nil }
            return "\(e.detector) \(best.degrees)°:\(String(format: "%.2f", e.score(for: best)))"
        }.joined(separator: " · ")
    }

    /// Faces first (one Vision request, usually decisive), then body pose and the network together
    /// (both look at all four orientations, so they share the passes), then text.
    public init(network: OrientationNetwork?, cues: Set<Cue> = Cue.standard, collectsPrints: Bool = false) {
        self.init(networks: network.map { ["network": ($0, OrientationNetDetector.prior)] } ?? [:], cues: cues,
                  collectsPrints: collectsPrints)
    }

    /// Several networks side by side, each with its own name and odds (for the evaluation tool).
    public init(networks: [String: (OrientationNetwork, OrientationPrior)], cues: Set<Cue>, collectsPrints: Bool) {
        var stages: [[any OrientationDetector]] = []
        if cues.contains(.faces) { stages.append([FaceDetector()]) }
        // These look at all four orientations, so they share one set of passes.
        var fourPass: [any OrientationDetector] = []
        if cues.contains(.body) { fourPass.append(BodyPoseDetector()) }
        if cues.contains(.network) {
            for (name, entry) in networks.sorted(by: { $0.key < $1.key }) {
                fourPass.append(OrientationNetDetector(name: name, network: entry.0, prior: entry.1))
            }
        }
        if cues.contains(.animals) { fourPass.append(AnimalDetector()) }
        if cues.contains(.people) { fourPass.append(UpperBodyDetector()) }
        if cues.contains(.horizon) { fourPass.append(HorizonDetector()) }
        if !fourPass.isEmpty || collectsPrints { stages.append(fourPass) }
        if cues.contains(.text) { stages.append([TextDetector()]) }
        self.stages = stages
        self.collectsPrints = collectsPrints
    }

    /// Every cue's evidence with no early stop, and the photo's feature prints, for the evaluation tool.
    public func allEvidence(_ image: CGImage) throws -> (evidence: [DetectorEvidence], prints: TurnedPrints) {
        var prints: TurnedPrints = [:]
        var evidence: [DetectorEvidence] = []
        for i in stages.indices { evidence += try run(i, on: image, prints: &prints) }
        return (evidence, prints)
    }

    public func analyze(_ image: CGImage) throws -> Result {
        var evidence: [DetectorEvidence] = []
        var prints: TurnedPrints = [:]
        var decision = decider.decide([])
        for i in stages.indices {
            evidence += try run(i, on: image, prints: &prints)
            decision = decider.decide(evidence)
            if decision.status == .upright && decision.confidence >= earlyExitConfidence { break }
        }
        return Result(decision: decision, evidence: evidence, prints: prints)
    }

    /// One `VNImageRequestHandler` per candidate orientation, with all of a stage's requests performed
    /// together so Vision prepares each oriented image only once. Detectors that run once only take
    /// part in the first pass. Feature prints are taken in the first pass that runs at each turn.
    private func run(_ stage: Int, on image: CGImage, prints: inout TurnedPrints) throws -> [DetectorEvidence] {
        let detectors = stages[stage]
        var scores = Array(repeating: [Rotation: Double](), count: detectors.count)
        let fourWay = detectors.isEmpty || !detectors.allSatisfy(\.runsOnce)
        let passes: [Rotation] = fourWay ? Rotation.allCases : [.none]
        for pass in passes {
            let active = detectors.indices.filter { pass == .none || !detectors[$0].runsOnce }
            let size = pass.swapsDimensions
                ? CGSize(width: image.height, height: image.width)
                : CGSize(width: image.width, height: image.height)
            let requests = active.map { detectors[$0].makeRequests() }
            var printRequest: VNGenerateImageFeaturePrintRequest?
            if collectsPrints, prints[pass] == nil {
                let r = VNGenerateImageFeaturePrintRequest()
                r.revision = VNGenerateImageFeaturePrintRequestRevision2
                printRequest = r
            }
            let all = requests.flatMap { $0 } + (printRequest.map { [$0] } ?? [])
            guard !all.isEmpty else { continue }
            let handler = VNImageRequestHandler(cgImage: image, orientation: pass.cgOrientation, options: [:])
            try handler.perform(all)
            for (detectorRequests, i) in zip(requests, active) {
                scores[i].merge(detectors[i].uprightScores(of: detectorRequests, image: image, frameSize: size,
                                                           pass: pass)) { $0 + $1 }
            }
            if let observation = printRequest?.results?.first, observation.elementType == .float {
                prints[pass] = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
        return detectors.enumerated().map { i, d in
            DetectorEvidence(detector: d.name, weight: d.weight, uprightScores: d.finalScores(scores[i]))
        }
    }

    /// Feature prints of `image` at each of `turns`.
    public static func turnedPrints(of image: CGImage, turns: [Rotation] = Rotation.allCases) throws -> TurnedPrints {
        var prints: TurnedPrints = [:]
        for pass in turns {
            let r = VNGenerateImageFeaturePrintRequest()
            r.revision = VNGenerateImageFeaturePrintRequestRevision2
            try VNImageRequestHandler(cgImage: image, orientation: pass.cgOrientation, options: [:]).perform([r])
            if let o = r.results?.first, o.elementType == .float {
                prints[pass] = o.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
        return prints
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
