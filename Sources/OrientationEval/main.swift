// orientation-eval: how well each set of orientation cues does on real photos.
//
//   swift run -c release orientation-eval --model PATH/OrientationNet.mlmodelc [--model2 PATH/Other.mlmodelc]
//       [--neighbours] --count 300 FOLDER
//
// Takes a random sample of the JPEG and HEIC photos under FOLDER, assumes each is upright (most
// photos are), and shows it to the cues turned all four ways. Every cue is run once per image; then
// each combination of cues is scored from that evidence, as Keeper would decide.
//
// --model2     a second network, scored on its own and in place of the first ("v2").
// --neighbours samples photos taken within a minute of another photo instead, turns only the
//              sampled one, and scores the neighbouring-shot cue with the other kept upright.
//
// Prints totals only: no file names or paths.

import CoreGraphics
import Foundation
import ImageIO
import KeeperKit
import KeeperOrientation

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
let modelPath = option("--model")
let model2Path = option("--model2")
let count = Int(option("--count") ?? "") ?? 200
let seed = UInt64(option("--seed") ?? "") ?? 1
let neighboursMode = flag("--neighbours")
guard let folder = args.first else {
    print("usage: orientation-eval [--model M.mlmodelc] [--model2 M2.mlmodelc] [--neighbours] [--count N] [--seed S] FOLDER")
    exit(2)
}

var standardError = FileHandle.standardError
extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) { write(string.data(using: .utf8)!) }
}

// A seeded shuffle, so runs can be compared.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

var files: [URL] = []
if let e = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil) {
    for case let url as URL in e where ["jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()) {
        files.append(url)
    }
}
var rng = SplitMix(state: seed)
files.shuffle(using: &rng)
print("\(files.count) photos found")

/// The photo as it's shown (EXIF orientation applied), long edge 768, like Keeper's previews.
func load(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: 768]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// `image` turned by `rotation` clockwise.
func turned(_ image: CGImage, _ rotation: Rotation) -> CGImage? {
    guard rotation != .none else { return image }
    let w = rotation.swapsDimensions ? image.height : image.width
    let h = rotation.swapsDimensions ? image.width : image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
    ctx.rotate(by: -CGFloat(rotation.degrees) * .pi / 180) // CG's y points up: negative is clockwise
    ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                               width: CGFloat(image.width), height: CGFloat(image.height)))
    return ctx.makeImage()
}

func loadNetwork(_ path: String?) -> OrientationNetwork? {
    guard let path else { return nil }
    do { return try OrientationNetwork.load(from: URL(fileURLWithPath: path)) } catch {
        print("couldn't load a network: \(error)")
        return nil
    }
}
let network = loadNetwork(modelPath), network2 = loadNetwork(model2Path)

/// Runs `body` over `items` eight at a time, keeping results in order.
func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], label: String, _ body: @Sendable @escaping (T) -> R?) -> [R?] {
    let lock = NSLock()
    nonisolated(unsafe) var results = [R?](repeating: nil, count: items.count)
    nonisolated(unsafe) var done = 0
    let started = Date()
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        let r = autoreleasepool { body(items[i]) }
        lock.lock()
        results[i] = r
        done += 1
        if done % 250 == 0 { print("  \(label): \(done) of \(items.count), \(Int(Date().timeIntervalSince(started)))s", to: &standardError) }
        lock.unlock()
    }
    return results
}

// MARK: Sample

// Neighbour mode: photos taken within a minute of another one (by EXIF capture time).
struct Pair: Sendable { let target: URL; let neighbour: URL }
var targets: [URL] = []
var pairs: [Pair] = []
if neighboursMode {
    func captureDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: text)
    }
    let pool = Array(files.prefix(60_000))
    let dates = concurrentMap(pool, label: "reading capture times") { captureDate($0) }
    var dated = zip(pool, dates).compactMap { u, d in d.map { (u, $0) } }
    dated.sort { $0.1 < $1.1 }
    var candidates: [Pair] = []
    for i in dated.indices.dropLast() where dated[i + 1].1.timeIntervalSince(dated[i].1) <= NeighbourCue.window {
        candidates.append(Pair(target: dated[i + 1].0, neighbour: dated[i].0))
    }
    candidates.shuffle(using: &rng)
    pairs = Array(candidates.prefix(count))
    targets = pairs.map(\.target)
    print("\(dated.count) dated photos read, \(candidates.count) with a neighbour within \(Int(NeighbourCue.window))s; sampling \(pairs.count)")
} else {
    targets = Array(files.prefix(count))
    print("sampling \(targets.count)")
}

// MARK: Evidence

var nets: [String: (OrientationNetwork, OrientationPrior)] = [:]
if let network { nets["network"] = (network, .equal) }   // raw: odds are applied when scoring
if let network2 { nets["v2"] = (network2, .equal) }
let analyzer = OrientationAnalyzer(networks: nets, cues: Set(Cue.allCases), collectsPrints: true)

struct Sample { var needs: Rotation; let shown: Rotation; let photo: Int; let evidence: [DetectorEvidence] }
struct Job: Sendable { let target: URL; let neighbour: URL? }
let jobs = neighboursMode ? pairs.map { Job(target: $0.target, neighbour: $0.neighbour) } : targets.map { Job(target: $0, neighbour: nil) }
nonisolated(unsafe) let sharedAnalyzer = analyzer
let started = Date()
let perPhoto = concurrentMap(Array(jobs.enumerated()).map { ($0.offset, $0.element) }, label: "checking") { (index, job) -> [Sample]? in
    guard let upright = load(job.target) else { return nil }
    var neighbourPrint: [Float]?
    if let n = job.neighbour {
        guard let image = load(n), let p = try? OrientationAnalyzer.turnedPrints(of: image, turns: [.none])[.none] else { return nil }
        neighbourPrint = p
    }
    var out: [Sample] = []
    for shown in Rotation.allCases {
        // Shown turned by `shown`, it needs the inverse turn to be upright again.
        guard let image = turned(upright, shown), let (evidence, prints) = try? sharedAnalyzer.allEvidence(image) else { continue }
        var e = evidence
        if let neighbourPrint {
            // Several tunings side by side, named neighbours/<limit>/<margin>.
            for limit: Float in [0.15, 0.25, 0.35] {
                for margin: Float in [0.04, 0.08, 0.15] {
                    if var n = NeighbourCue.evidence(prints: prints, neighbours: [neighbourPrint],
                                                     parameters: .init(limit: limit, fullMargin: margin, weight: 1)) {
                        n.detector = "neighbours/\(limit)/\(margin)"
                        e.append(n)
                    }
                }
            }
            // How close each turn came, for tuning.
            var d = DetectorEvidence(detector: "distance", weight: 0, uprightScores: [:])
            for r in Rotation.allCases {
                d.uprightScores[r] = Double(FeatureVector(prints[r]!).distance(to: FeatureVector(neighbourPrint)))
            }
            e.append(d)
        }
        out.append(Sample(needs: shown.inverse, shown: shown, photo: index, evidence: e))
    }
    return out
}
var samples = perPhoto.compactMap { $0 }.flatMap { $0 }
let done = perPhoto.compactMap { $0 }.count
print("\n\(done) photos, \(samples.count) turned images, in \(Int(Date().timeIntervalSince(started)))s")

// Photos that were never upright: where both networks, with no lean towards upright, agree at all
// four turns that the photo itself needs the same turn c, it's taken to really need c, and every
// turned copy's answer moves with it. Scored separately below, so the rates aren't blamed for
// finding photos that really are sideways.
var relabelled = 0
if network != nil, network2 != nil {
    func argmax(_ e: DetectorEvidence?) -> Rotation? {
        guard let e, !e.uprightScores.isEmpty else { return nil }
        return Rotation.allCases.max { e.score(for: $0) < e.score(for: $1) }
    }
    let byPhoto = Dictionary(grouping: samples.indices, by: { samples[$0].photo })
    for (_, indices) in byPhoto where indices.count == 4 {
        var truths: Set<Rotation> = []
        for i in indices {
            let s = samples[i]
            for name in ["network", "v2"] {
                // What this answer says the photo itself needs: the answer, before the turn it was shown at.
                guard let a = argmax(s.evidence.first { $0.detector == name }) else { truths.insert(.none); continue }
                truths.insert(a.followed(by: s.shown))
            }
        }
        guard truths.count == 1, let c = truths.first, c != .none else { continue }
        relabelled += 1
        for i in indices { samples[i].needs = c.followed(by: samples[i].shown.inverse) }
    }
    print("Photos both networks agree were never upright (re-labelled with that turn): \(relabelled) of \(done)")
}

// MARK: Scoring

let defaultPriors: [String: OrientationPrior] = [
    "network": OrientationPrior(upright: 0.90, sideways: 0.045, upsideDown: 0.01),
    "v2": OrientationPrior(upright: 0.75, sideways: 0.1125, upsideDown: 0.025),
]

struct Rates { var flag = 0.0, side = 0.0, upside = 0.0, wrong = 0.0 }

func rates(_ cues: Set<String>, priors: [String: OrientationPrior] = defaultPriors, threshold: Double) -> Rates {
    let decider = OrientationDecider(minimumStrength: 0.3, minimumConfidence: 0.2)
    var up = 0, fl = 0, sd = 0, fs = 0, ud = 0, fu = 0, wr = 0, tt = 0
    for s in samples {
        let evidence = s.evidence.filter { cues.contains($0.detector) }.map { e -> DetectorEvidence in
            guard let prior = priors[e.detector] else { return e }
            var e = e
            e.uprightScores = prior.apply(to: e.uprightScores)
            return e
        }
        let d = decider.decide(evidence)
        let proposes = d.status == .needsRotation && d.confidence >= threshold
        if s.needs == .none { up += 1; if proposes { fl += 1 }; continue }
        tt += 1
        if s.needs == .rotate180 { ud += 1 } else { sd += 1 }
        guard proposes else { continue }
        if d.rotation == s.needs { if s.needs == .rotate180 { fu += 1 } else { fs += 1 } } else { wr += 1 }
    }
    func r(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
    return Rates(flag: r(fl, up), side: r(fs, sd), upside: r(fu, ud), wrong: r(wr, tt))
}

func p(_ x: Double) -> String { String(format: "%5.1f%%", x * 100) }

func table(_ label: String, _ cues: Set<String>, priors: [String: OrientationPrior] = defaultPriors) {
    print("\n\(label)")
    print("  min conf | upright flagged | sideways found | upside down found | wrong turn")
    for t in [0.3, 0.5, 0.6] {
        let r = rates(cues, priors: priors, threshold: t)
        print("  \(String(format: "%7.0f%%", t * 100)) | \(p(r.flag).padding(toLength: 15, withPad: " ", startingAt: 0)) | "
              + "\(p(r.side).padding(toLength: 14, withPad: " ", startingAt: 0)) | "
              + "\(p(r.upside).padding(toLength: 17, withPad: " ", startingAt: 0)) | \(p(r.wrong))")
    }
}

let vision: Set<String> = ["faces", "body", "text"]
let standard = vision.union(["network"])
if network != nil { table("Standard cues (faces, body, network, text)", standard) }
if network2 != nil {
    table("v2 network alone", ["v2"])
    if network != nil { table("current network alone", ["network"]) }
    table("faces, body, v2, text", vision.union(["v2"]))
    if network != nil { table("faces, body, both networks, text", standard.union(["v2"])) }
}
// Odds for each network-like cue: a stronger lean towards upright flags fewer upright photos but finds fewer.
if network != nil && network2 != nil {
    for u in [0.75, 0.8, 0.85, 0.88] {
        var priors = defaultPriors
        priors["v2"] = OrientationPrior(upright: u, sideways: (1 - u) * 0.45, upsideDown: (1 - u) * 0.1)
        table("faces, body, v2 (upright \(u)), text", vision.union(["v2"]), priors: priors)
    }
}
print("\nOdds (upright share; the rest split 9:9:2 sideways/sideways/upside down), at 50%:")
for cue in ["network", "v2"] where samples.contains(where: { s in s.evidence.contains { $0.detector == cue } }) {
    for base in [standard.subtracting(["network"]), Set<String>()] {
        for u in [0.5, 0.75, 0.8, 0.85, 0.88, 0.9, 0.95] {
            var priors = defaultPriors
            priors[cue] = OrientationPrior(upright: u, sideways: (1 - u) * 0.45, upsideDown: (1 - u) * 0.1)
            let r = rates(base.union([cue]), priors: priors, threshold: 0.5)
            print("  \(cue)\(base.isEmpty ? " alone" : " + faces/body/text") upright \(u): flags \(p(r.flag)) finds \(p(r.side)) sideways \(p(r.upside)) upside down, wrong \(p(r.wrong))")
        }
    }
}

if neighboursMode {
    // How close the right turn comes to the neighbour, against the closest wrong turn.
    var right: [Double] = [], wrongTurn: [Double] = []
    for s in samples {
        guard let d = s.evidence.first(where: { $0.detector == "distance" }) else { continue }
        right.append(d.uprightScores[s.needs] ?? 0)
        wrongTurn.append(Rotation.allCases.filter { $0 != s.needs }.map { d.uprightScores[$0] ?? 2 }.min()!)
    }
    func q(_ xs: [Double], _ f: Double) -> String { xs.isEmpty ? "-" : String(format: "%.3f", xs.sorted()[Int(Double(xs.count - 1) * f)]) }
    print("\nDistance to the neighbour, right turn: median \(q(right, 0.5)), 90th pct \(q(right, 0.9)); closest wrong turn: 10th pct \(q(wrongTurn, 0.1)), median \(q(wrongTurn, 0.5))")
    print("Right turn closer than every wrong one: \(p(Double(zip(right, wrongTurn).filter { $0 < $1 }.count) / Double(max(right.count, 1))))")
    let base = network2 != nil ? vision.union(["v2"]) : standard
    let baseLabel = network2 != nil ? "faces, body, v2, text" : "standard"
    table("\(baseLabel) (neighbour sample)", base)
    for limit: Float in [0.15, 0.25, 0.35] {
        for margin: Float in [0.04, 0.08, 0.15] {
            let name = "neighbours/\(limit)/\(margin)"
            let r = rates(base.union([name]), threshold: 0.5)
            let alone = rates([name], threshold: 0.5)
            print("  + neighbours limit \(limit) margin \(margin) at 50%: flags \(p(r.flag)) finds \(p(r.side)) / \(p(r.upside)), wrong \(p(r.wrong))"
                  + " | alone: flags \(p(alone.flag)) finds \(p(alone.side)) / \(p(alone.upside))")
        }
    }
}

// Time per photo for each network, on a few photos.
do {
    let few = targets.prefix(12).compactMap(load)
    func time(_ label: String, _ a: OrientationAnalyzer) {
        let t = Date()
        for image in few { _ = try? a.allEvidence(image) }
        print("  \(label): \(String(format: "%.0f", Date().timeIntervalSince(t) / Double(max(few.count, 1)) * 1000)) ms per photo")
    }
    print("\nTime (one photo at a time, all four passes):")
    if let network { time("current network", OrientationAnalyzer(networks: ["network": (network, .equal)], cues: [.network], collectsPrints: false)) }
    if let network2 { time("v2 network", OrientationAnalyzer(networks: ["v2": (network2, .equal)], cues: [.network], collectsPrints: false)) }
    time("feature prints", OrientationAnalyzer(networks: [:], cues: [], collectsPrints: true))
    time("faces, body, text", OrientationAnalyzer(networks: [:], cues: [.faces, .body, .text], collectsPrints: false))
}
