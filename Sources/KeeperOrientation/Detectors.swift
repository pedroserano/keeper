// The cues that say which way up a photo is: faces, people (body pose), text and the orientation
// network. Adapted from ApplePhotosRotator (Detection/Detectors.swift), without its fallback scene
// model and optional user model.

import AppKit
import CoreML
import Foundation
import KeeperKit
import Vision

/// A Vision-based signal for which correction makes a photo upright.
///
/// Scores are in `0...1` per candidate correction: 0 means "no upright content found after this correction",
/// 1 means "certainly upright".
protocol OrientationDetector: Sendable {
    var name: String { get }
    var weight: Double { get }
    /// `true` for detectors that find their subject at any angle and report that angle (faces). They run once, on
    /// the photo as displayed, and score every correction from that single result. Other detectors are shown the
    /// photo once per candidate correction.
    var runsOnce: Bool { get }
    func makeRequests() -> [VNRequest]
    /// Scores keyed by correction. `pass` is the correction Vision applied before analysing, `image` is the photo
    /// as displayed (before that correction), and `frameSize` is the pixel size of the frame Vision analysed.
    func uprightScores(of requests: [VNRequest], image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double]
    /// Adjusts the scores summed over all passes before they are combined with other detectors.
    func finalScores(_ scores: [Rotation: Double]) -> [Rotation: Double]
}

extension OrientationDetector {
    func finalScores(_ scores: [Rotation: Double]) -> [Rotation: Double] { scores }
}

/// Most detectors need a single Vision request per pass.
protocol SingleRequestDetector: OrientationDetector {
    func makeRequest() -> VNRequest
    func uprightScores(of request: VNRequest, image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double]
}

extension SingleRequestDetector {
    func makeRequests() -> [VNRequest] { [makeRequest()] }

    func uprightScores(of requests: [VNRequest], image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double] {
        requests.first.map { uprightScores(of: $0, image: image, frameSize: frameSize, pass: pass) } ?? [:]
    }
}

/// A detector that only recognises upright content. It is run on all four orientations, and the orientation in
/// which it finds upright content gets the credit. Because every score is about the frame Vision analysed, the
/// detector never needs to know which way a rotation's sign runs.
protocol PerPassDetector: SingleRequestDetector {
    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double
}

extension PerPassDetector {
    var runsOnce: Bool { false }

    func uprightScores(of request: VNRequest, image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double] {
        [pass: uprightScore(of: request, frameSize: frameSize)]
    }
}

/// Faces are the strongest cue. Vision's face detector finds faces at any in-plane angle and reports their roll,
/// so one pass is enough: a face rolled by about +90° means the photo needs 90° clockwise, and so on.
struct FaceDetector: SingleRequestDetector {
    let name = "faces"
    let weight = 1.0
    let runsOnce = true

    func makeRequest() -> VNRequest {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }

    func uprightScores(of request: VNRequest, image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double] {
        guard let faces = request.results as? [VNFaceObservation] else { return [:] }
        var votes: [Rotation: [Double]] = [:]
        for face in faces {
            // Ignore specks: tiny "faces" in a thumbnail are mostly false positives.
            guard face.boundingBox.width * face.boundingBox.height >= 0.0025,
                  let roll = face.roll?.doubleValue
            else { continue }
            // Roll is relative to the analysed frame, so add the correction already applied for this pass.
            let degrees = roll * 180 / .pi + Double(pass.degrees)
            let correction = Rotation(degrees: Int(degrees.rounded()))
            // Faces tilted 30–45° from any quarter turn are ambiguous; they don't vote.
            let tilt = (degrees - Double(correction.degrees)) * .pi / 180
            let certainty = Double(face.confidence) * uprightFactor(angleFromVertical: tilt, toleranceDegrees: 30)
            if certainty > 0 { votes[correction, default: []].append(certainty) }
        }
        return votes.mapValues { noisyOr($0) }
    }
}

/// People: credit the orientation in which the body points up — neck above hips, or for head-and-shoulders shots,
/// nose above neck.
struct BodyPoseDetector: PerPassDetector {
    let name = "body"
    let weight = 0.8

    func makeRequest() -> VNRequest { VNDetectHumanBodyPoseRequest() }

    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double {
        guard let bodies = request.results as? [VNHumanBodyPoseObservation] else { return 0 }
        return noisyOr(bodies.compactMap { body -> Double? in
            guard let (top, bottom) = axis(of: body) else { return nil }
            // Vision's normalised coordinates have their origin at the bottom left, y pointing up.
            let dx = Double(top.location.x - bottom.location.x) * frameSize.width
            let dy = Double(top.location.y - bottom.location.y) * frameSize.height
            guard hypot(dx, dy) > 0.03 * max(frameSize.width, frameSize.height) else { return nil }
            let angleFromUp = atan2(dx, dy)
            return min(top.confidence, bottom.confidence) * uprightFactor(angleFromVertical: angleFromUp, toleranceDegrees: 35)
        })
    }

    private struct Joint {
        var location: CGPoint
        var confidence: Double
    }

    /// The longest reliable head-to-toe direction available.
    private func axis(of body: VNHumanBodyPoseObservation) -> (top: Joint, bottom: Joint)? {
        if let top = joint(body, .neck) ?? joint(body, .nose),
           let bottom = joint(body, .root) ?? center(joint(body, .leftHip), joint(body, .rightHip)) {
            return (top, bottom)
        }
        if let top = joint(body, .nose) ?? center(joint(body, .leftEye), joint(body, .rightEye)),
           let bottom = joint(body, .neck) ?? center(joint(body, .leftShoulder), joint(body, .rightShoulder)) {
            return (top, bottom)
        }
        return nil
    }

    private func joint(_ body: VNHumanBodyPoseObservation, _ name: VNHumanBodyPoseObservation.JointName) -> Joint? {
        guard let p = try? body.recognizedPoint(name), p.confidence > 0.3 else { return nil }
        return Joint(location: p.location, confidence: Double(p.confidence))
    }

    private func center(_ a: Joint?, _ b: Joint?) -> Joint? {
        guard let a, let b else { return nil }
        return Joint(
            location: CGPoint(x: (a.location.x + b.location.x) / 2, y: (a.location.y + b.location.y) / 2),
            confidence: min(a.confidence, b.confidence)
        )
    }
}

/// Signs, logos, documents, screens. Two signals per pass:
/// - *Which way up*: Vision reads upside-down text as gibberish with the *same* confidence as real text, so this
///   counts recognised dictionary words, not Vision's confidence.
/// - *Which axis*: Vision can't read sideways text at all, so any text it reads in a pass — brand names, numbers,
///   gibberish — means the photo is either that way up or upside down, never sideways. This works for logos and
///   screens whose words aren't in the dictionary.
struct TextDetector: SingleRequestDetector {
    let name = "text"
    let weight = 0.9
    let runsOnce = false

    func makeRequest() -> VNRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        // Correction would "fix" upside-down gibberish into words, hiding exactly the signal we need.
        request.usesLanguageCorrection = false
        return request
    }

    func uprightScores(of request: VNRequest, image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double] {
        guard let lines = request.results as? [VNRecognizedTextObservation], !lines.isEmpty else { return [:] }
        let strings = lines.compactMap { $0.topCandidates(1).first?.string }
        let text = strings.joined(separator: " ")
        let (words, real) = Lexicon.count(in: text)
        // Mostly real words, and enough of them: ~3 real words is strong evidence for this exact way up.
        let direction = words > 0 ? (Double(real) / Double(words)) * (1 - exp(-Double(real) / 2)) : 0
        // Any readable characters that aren't clearly words: evidence for this way up or upside down, split evenly.
        // (Where real words already say which way up, this would only blur that answer.)
        let characters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        let axis = 0.25 * (1 - exp(-Double(characters) / 12)) * (1 - direction)
        return [pass: direction + axis, pass.followed(by: .rotate180): axis]
    }
}

/// Dictionary lookups via the system spell checker, in the user's languages.
enum Lexicon {
    private static let lock = NSLock()

    /// Words of 3+ characters, and how many of them are spelled correctly. Tokens mixing letters and digits
    /// ("IS31", "OIOHd" style misreads) count as words but never as real ones.
    static func count(in text: String) -> (words: Int, real: Int) {
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) }
        guard !tokens.isEmpty else { return (0, 0) }
        // NSSpellChecker is not thread-safe; the text stage is rare enough that serialising it costs little.
        lock.lock()
        defer { lock.unlock() }
        let checker = NSSpellChecker.shared
        let real = tokens.filter { token in
            guard token.allSatisfy(\.isLetter) else { return false }
            // Lower-cased so all-caps gibberish isn't waved through as an acronym.
            let word = token.lowercased()
            return checker.checkSpelling(of: word, startingAt: 0).location == NSNotFound
        }.count
        return (tokens.count, real)
    }
}

/// The fine-tuned orientation network: an image-recognition network trained specifically to tell which way a photo
/// is turned. It covers every kind of photo — landscapes, buildings, objects, people — and is the main cue for photos
/// without faces. It runs on all four orientations and averages the four estimates.
public struct OrientationNetDetector: SingleRequestDetector {
    let name = "network"
    let weight = 1.0
    let runsOnce = false
    let network: OrientationNetwork

    /// The network was trained with all four turns equally likely; real libraries are mostly upright and rarely
    /// upside down. Measured on held-out photos (Models/OrientationNet-report-coreml.txt), these odds cut wrongly
    /// flagged upright photos from 3% to under 0.1% at 50% confidence, while still finding about half of sideways
    /// photos. In exchange the network alone almost never proposes upside-down turns; faces, people and text
    /// still do.
    static let prior = OrientationPrior(upright: 0.90, sideways: 0.045, upsideDown: 0.01)

    func finalScores(_ scores: [Rotation: Double]) -> [Rotation: Double] { Self.prior.apply(to: scores) }

    /// The network bundled with the app (compiled at build time, or compiled once on first use and
    /// cached), or `nil` if this build doesn't include one.
    public static let builtIn: OrientationNetwork? = {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DecisionStore.folderName, isDirectory: true)
        let candidates = [
            Bundle.main.url(forResource: "OrientationNet", withExtension: "mlmodelc"),
            Bundle.main.url(forResource: "OrientationNet", withExtension: "mlpackage"),
        ]
        for case let url? in candidates {
            if let network = try? OrientationNetwork.load(from: url, cacheDirectory: cache) { return network }
        }
        return nil
    }()

    func makeRequest() -> VNRequest { network.makeRequest() }

    func uprightScores(of request: VNRequest, image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double] {
        guard let p = OrientationNetwork.probabilities(from: request) else { return [:] }
        return passScores(p, pass: pass)
    }
}

// MARK: - Extra cues (Keeper)

/// Pets and other animals: Vision's animal recogniser finds them mostly when they're the right way
/// up, so it's shown all four ways and the way it's surest of gets the credit.
struct AnimalDetector: PerPassDetector {
    let name = "animals"
    let weight = 0.6

    func makeRequest() -> VNRequest { VNRecognizeAnimalsRequest() }

    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double {
        guard let animals = request.results as? [VNRecognizedObjectObservation] else { return 0 }
        return noisyOr(animals.filter { $0.boundingBox.width * $0.boundingBox.height >= 0.01 }
            .map { Double($0.labels.first?.confidence ?? $0.confidence) })
    }
}

/// People seen from the waist up, all four ways: the human detector finds upright people far more
/// readily than sideways ones. Catches crowds and backs of heads that faces and body pose miss.
struct UpperBodyDetector: PerPassDetector {
    let name = "people"
    let weight = 0.5

    func makeRequest() -> VNRequest {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = true
        return request
    }

    func uprightScore(of request: VNRequest, frameSize: CGSize) -> Double {
        guard let people = request.results as? [VNHumanObservation] else { return 0 }
        return noisyOr(people.filter { $0.boundingBox.width * $0.boundingBox.height >= 0.01 }
            .map { Double($0.confidence) * 0.8 })
    }
}

/// Horizons: Vision only finds a horizon that's roughly level, so finding one in a pass means the
/// photo is that way up or upside down, never sideways. An axis cue, like readable text.
struct HorizonDetector: SingleRequestDetector {
    let name = "horizon"
    let weight = 0.5
    let runsOnce = false

    func makeRequest() -> VNRequest { VNDetectHorizonRequest() }

    func uprightScores(of request: VNRequest, image: CGImage, frameSize: CGSize, pass: Rotation) -> [Rotation: Double] {
        guard let horizon = (request.results as? [VNHorizonObservation])?.first,
              abs(horizon.angle) < 0.35 else { return [:] }
        let score = 0.5 * Double(horizon.confidence)
        return [pass: score, pass.followed(by: .rotate180): score]
    }
}
