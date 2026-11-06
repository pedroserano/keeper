// orientation-eval: how well each set of orientation cues does on real photos.
//
//   swift run -c release orientation-eval --model PATH/OrientationNet.mlmodelc --count 300 FOLDER
//
// Takes a random sample of the JPEG and HEIC photos under FOLDER, assumes each is upright (most
// photos are), and shows it to the cues turned all four ways. Every cue is run once per image; then
// each combination of cues is scored from that evidence, as Keeper would decide. Prints totals only:
// no file names or paths.

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
let modelPath = option("--model")
let count = Int(option("--count") ?? "") ?? 200
let seed = UInt64(option("--seed") ?? "") ?? 1
guard let folder = args.first else {
    print("usage: orientation-eval [--model OrientationNet.mlmodelc] [--count N] [--seed S] FOLDER")
    exit(2)
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
print("\(files.count) photos found; sampling \(min(count, files.count))")

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

var network: OrientationNetwork?
if let modelPath {
    do { network = try OrientationNetwork.load(from: URL(fileURLWithPath: modelPath)) } catch {
        print("couldn't load the network: \(error)")
    }
}
let analyzer = OrientationAnalyzer(network: network, cues: Set(Cue.allCases))

// For each image and each turn it was shown at: the correction it needs and every cue's evidence.
struct Sample { let needs: Rotation; let evidence: [DetectorEvidence] }
var samples: [Sample] = []
var done = 0
let started = Date()
for url in files.prefix(count) {
    guard let upright = load(url) else { continue }
    for shown in Rotation.allCases {
        // Shown turned by `shown`, it needs the inverse turn to be upright again.
        guard let image = turned(upright, shown), let evidence = try? analyzer.allEvidence(image) else { continue }
        samples.append(Sample(needs: shown.inverse, evidence: evidence))
    }
    done += 1
    if done % 25 == 0 {
        print("  \(done) photos, \(Int(Date().timeIntervalSince(started)))s", to: &standardError)
    }
}

var standardError = FileHandle.standardError
extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) { write(string.data(using: .utf8)!) }
}

func score(_ cues: Set<String>, label: String) {
    let decider = OrientationDecider(minimumStrength: 0.3, minimumConfidence: 0.2)
    print("\n\(label)")
    print("  min conf | upright flagged | sideways found | upside down found | wrong turn")
    for threshold in [0.3, 0.5, 0.6] {
        var upright = 0, flagged = 0, sideways = 0, foundSide = 0, upside = 0, foundUpside = 0, wrong = 0, turnedTotal = 0
        for s in samples {
            let d = decider.decide(s.evidence.filter { cues.contains($0.detector) })
            let proposes = d.status == .needsRotation && d.confidence >= threshold
            if s.needs == .none {
                upright += 1
                if proposes { flagged += 1 }
                continue
            }
            turnedTotal += 1
            if s.needs == .rotate180 { upside += 1 } else { sideways += 1 }
            guard proposes else { continue }
            if d.rotation == s.needs {
                if s.needs == .rotate180 { foundUpside += 1 } else { foundSide += 1 }
            } else {
                wrong += 1
            }
        }
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%5.1f%%", Double(a) / Double(b) * 100) }
        print("  \(String(format: "%7.0f%%", threshold * 100)) | \(pct(flagged, upright).padding(toLength: 15, withPad: " ", startingAt: 0)) | "
              + "\(pct(foundSide, sideways).padding(toLength: 14, withPad: " ", startingAt: 0)) | "
              + "\(pct(foundUpside, upside).padding(toLength: 17, withPad: " ", startingAt: 0)) | \(pct(wrong, turnedTotal))")
    }
}

print("\n\(done) photos, \(samples.count) turned images, in \(Int(Date().timeIntervalSince(started)))s")
let standard: Set<String> = ["faces", "body", "network", "text"]
score(standard, label: "Standard cues (faces, body, network, text)")
score(standard.union(["animals"]), label: "+ animals")
score(standard.union(["people"]), label: "+ people (upper body)")
score(standard.union(["horizon"]), label: "+ horizon")
score(standard.union(["animals", "people", "horizon"]), label: "+ all three")

// Which cues push upright photos into a proposal: for each flagged upright image at 50%, the cues
// that scored the proposed turn highest.
do {
    let decider = OrientationDecider(minimumStrength: 0.3, minimumConfidence: 0.2)
    var blame: [String: Int] = [:], turns: [Rotation: Int] = [:], flagged = 0
    for s in samples where s.needs == .none {
        let d = decider.decide(s.evidence.filter { standard.contains($0.detector) })
        guard d.status == .needsRotation, d.confidence >= 0.5 else { continue }
        flagged += 1
        turns[d.rotation, default: 0] += 1
        for e in s.evidence where standard.contains(e.detector) && e.weight * e.score(for: d.rotation) > 0.2 {
            blame[e.detector, default: 0] += 1
        }
    }
    print("\nUpright photos flagged at 50%: \(flagged); proposed turns \(turns.map { "\($0.key.shortLabel) \($0.value)" }.sorted())")
    print("cues backing those turns: \(blame.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" })")
}

// Fitting the combination: weights per cue and an extra lean towards "as it is", tried on one half
// of the photos and checked on the other, so the numbers aren't flattering themselves.
func rates(_ subset: ArraySlice<Sample>, weights: [String: Double], lean: Double, threshold: Double) -> (flag: Double, side: Double, upside: Double, wrong: Double) {
    let decider = OrientationDecider(minimumStrength: 0.3, minimumConfidence: 0.2)
    var up = 0, fl = 0, sd = 0, fs = 0, ud = 0, fu = 0, wr = 0, tt = 0
    for s in subset {
        var ev = s.evidence.compactMap { e -> DetectorEvidence? in
            guard let w = weights[e.detector], w > 0 else { return nil }
            return DetectorEvidence(detector: e.detector, weight: w, uprightScores: e.uprightScores)
        }
        if lean > 0 { ev.append(DetectorEvidence(detector: "lean", weight: lean, uprightScores: [.none: 1])) }
        let d = decider.decide(ev)
        let proposes = d.status == .needsRotation && d.confidence >= threshold
        if s.needs == .none { up += 1; if proposes { fl += 1 }; continue }
        tt += 1
        if s.needs == .rotate180 { ud += 1 } else { sd += 1 }
        guard proposes else { continue }
        if d.rotation == s.needs { if s.needs == .rotate180 { fu += 1 } else { fs += 1 } } else { wr += 1 }
    }
    func r(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
    return (r(fl, up), r(fs, sd), r(fu, ud), r(wr, tt))
}

let half = samples.count / 8 * 4 // whole photos (4 turns each) in each half
let fit = samples[..<half], check = samples[half...]
var best: (weights: [String: Double], lean: Double, found: Double)? = nil
let grid: [Double] = [0, 0.5, 1, 1.5]
for wf in [0.5, 1.0, 1.5] { for wb in grid { for wn in [0.5, 1.0, 1.5] { for wt in grid { for wa in [0, 0.5] { for wp in [0, 0.5] { for wh in [0, 0.5] { for lean in [0, 0.25, 0.5, 0.75] {
    let w = ["faces": wf, "body": wb, "network": wn, "text": wt, "animals": wa, "people": wp, "horizon": wh]
    let r = rates(fit, weights: w, lean: lean, threshold: 0.5)
    // The aim: no more than 1 in 100 upright photos flagged, as many sideways ones found as possible.
    guard r.flag <= 0.01 else { continue }
    let found = r.side * 2 + r.upside - r.wrong * 2
    if best == nil || found > best!.found { best = (w, lean, found) }
}}}}}}}}
if let best {
    print("\nBest fit on half the photos (≤1% upright flagged at 50%): weights \(best.weights.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }), lean \(best.lean)")
    for t in [0.3, 0.5, 0.6] {
        let a = rates(check, weights: best.weights, lean: best.lean, threshold: t)
        let b = rates(check, weights: ["faces": 1, "body": 0.8, "network": 1, "text": 0.9], lean: 0, threshold: t)
        func p(_ x: Double) -> String { String(format: "%5.1f%%", x * 100) }
        print("  held-out \(Int(t * 100))%: fitted flags \(p(a.flag)) finds \(p(a.side)) sideways \(p(a.upside)) upside down, wrong \(p(a.wrong))"
              + " | standard flags \(p(b.flag)) finds \(p(b.side)) / \(p(b.upside)), wrong \(p(b.wrong))")
    }
}
