// Finding duplicates and similar shots.
//
// Duplicates and near-identical takes are almost always captured within seconds of each other,
// so photos are first chained into time clusters (each within `clusterGap` of the previous one).
// Only photos in a cluster of two or more are compared, using Vision's image feature print:
// 768 numbers per photo, normalised, where the cosine distance between two photos is about
// 0.002 for a resized copy, 0.01 for a slightly rotated one, 0.05 for a cropped one, 0.15 for two
// different scenes in a similar style, and 0.65 for unrelated images.
// Prints come from small previews, so even exact copies are up to about 0.02 apart, as close as
// two frames of a burst. What sets copies apart is time: a copy keeps the original's capture time,
// so duplicates must also share a capture moment (`sameMoment`); bursts are similar shots.

import Accelerate
import Foundation

/// A feature print, stored compactly: one Float32 scale followed by one Int8 per element
/// (about 0.8 KB per photo instead of 3 KB).
public struct FeatureVector: Sendable, Equatable {
    public let values: [Float]
    /// Length of `values`, worked out once: grouping compares each print with many others.
    private let norm: Float

    public init(_ values: [Float]) {
        self.values = values
        norm = Self.dot(values, values, count: values.count).squareRoot()
    }

    public init?(quantized data: Data) {
        guard data.count > 4 else { return nil }
        let scale = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        self.init(data.dropFirst(4).map { Float(Int8(bitPattern: $0)) * scale })
    }

    public static func == (a: FeatureVector, b: FeatureVector) -> Bool { a.values == b.values }

    private static func dot(_ a: [Float], _ b: [Float], count: Int) -> Float {
        var result: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                vDSP_dotpr(pa.baseAddress!, 1, pb.baseAddress!, 1, &result, vDSP_Length(count))
            }
        }
        return result
    }

    public var quantized: Data {
        let maxAbs = values.map(abs).max() ?? 0
        let scale = maxAbs > 0 ? maxAbs / 127 : 1
        var data = withUnsafeBytes(of: scale) { Data($0) }
        data.append(contentsOf: values.map { UInt8(bitPattern: Int8(clamping: Int(($0 / scale).rounded()))) })
        return data
    }

    /// 0 = same direction, 1 = unrelated, 2 = opposite.
    public func distance(to other: FeatureVector) -> Float {
        let n = min(values.count, other.values.count)
        guard n > 0 else { return 1 }
        let d = Self.dot(values, other.values, count: n)
        // Different lengths never happen with one Vision revision; compare the shared part then.
        let a = n == values.count ? norm : Self.dot(values, values, count: n).squareRoot()
        let b = n == other.values.count ? other.norm : Self.dot(other.values, other.values, count: n).squareRoot()
        guard a > 0, b > 0 else { return 1 }
        return 1 - d / (a * b)
    }
}

/// Photos that look alike: every member is within the kind's distance of every other member,
/// and all were taken within `Similarity.groupSpan` of each other.
public struct SimilarGroup: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Near-identical copies with the same capture time: re-imports, edits, the same frame saved twice.
        case duplicate
        /// Takes of the same moment that look alike.
        case similar

        public var distance: Float {
            self == .duplicate ? Similarity.duplicateDistance : Similarity.similarDistance
        }
    }

    public let members: [String]
    public let kind: Kind

    public init(members: [String], kind: Kind) {
        self.members = members
        self.kind = kind
    }
}

public enum Similarity {
    /// Photos more than this far apart in time are never compared.
    public static let clusterGap: TimeInterval = 30
    /// Members of one group are never more than this far apart in time.
    public static let groupSpan: TimeInterval = 60
    /// From test images and the first scan of a 150,000-photo library (out/similarity-report.csv).
    /// 0.12 grouped photos that looked nothing alike, so similar is now 0.10.
    public static let duplicateDistance: Float = 0.02
    public static let similarDistance: Float = 0.10

    /// Taken at the same moment, as a copy and its original are: the same time to the hundredth of
    /// a second, or the same second when one of them has no fraction (a copy that lost it on import).
    public static func sameMoment(_ a: Date, _ b: Date) -> Bool {
        let x = a.timeIntervalSinceReferenceDate, y = b.timeIntervalSinceReferenceDate
        if abs(x - y) <= 0.01 { return true }
        let wholeX = x == x.rounded(.down), wholeY = y == y.rounded(.down)
        return (wholeX || wholeY) && x.rounded(.down) == y.rounded(.down)
    }

    /// Chains photos (sorted by date) into runs where each is within `clusterGap` of the one before.
    /// Returns only runs of two or more.
    public static func timeClusters(_ photos: [(uuid: String, date: Date)]) -> [[String]] {
        let sorted = photos.sorted { $0.date < $1.date }
        var clusters: [[String]] = []
        var run: [String] = []
        var last: Date?
        for p in sorted {
            if let last, p.date.timeIntervalSince(last) > clusterGap {
                if run.count > 1 { clusters.append(run) }
                run = []
            }
            run.append(p.uuid)
            last = p.date
        }
        if run.count > 1 { clusters.append(run) }
        return clusters
    }

    /// Groups of photos that all look alike (complete linkage: each new member must be within the
    /// kind's distance of every member already there, not just one of them, so groups can't chain
    /// across a run of gradually changing shots) and were all taken within `groupSpan` of each other.
    /// Duplicates must also all share a capture moment (`sameMomentDuplicates: false` is the old
    /// rule, kept to carry saved ticks over). Clusters must be in date order, as `timeClusters` returns them.
    public static func groups(clusters: [[String]], vectors: [String: FeatureVector], dates: [String: Date],
                              kind: SimilarGroup.Kind, sameMomentDuplicates: Bool = true) -> [SimilarGroup] {
        let limit = kind.distance
        var out: [SimilarGroup] = []
        for cluster in clusters {
            let ids = cluster.filter { vectors[$0] != nil && dates[$0] != nil }
            var open: [[String]] = []
            func close(before date: Date) {
                open.removeAll { group in
                    guard date.timeIntervalSince(dates[group[0]]!) > groupSpan else { return false }
                    if group.count > 1 { out.append(SimilarGroup(members: group, kind: kind)) }
                    return true
                }
            }
            for id in ids {
                let date = dates[id]!, v = vectors[id]!
                close(before: date)
                // Join the open group this photo is closest to, if it's close to all of its members.
                var best: (index: Int, distance: Float)?
                for (i, group) in open.enumerated() {
                    if kind == .duplicate, sameMomentDuplicates, !group.allSatisfy({ sameMoment(dates[$0]!, date) }) { continue }
                    let farthest = group.map { v.distance(to: vectors[$0]!) }.max() ?? .infinity
                    if farthest <= limit, farthest < (best?.distance ?? .infinity) { best = (i, farthest) }
                }
                if let best { open[best.index].append(id) } else { open.append([id]) }
            }
            close(before: .distantFuture)
        }
        return out
    }

    /// Group sizes, for the report: how many groups have 2, 3, … members, plus the largest.
    public static func sizeCounts(_ groups: [SimilarGroup]) -> (counts: [Int: Int], largest: Int) {
        var counts: [Int: Int] = [:]
        for g in groups { counts[g.members.count, default: 0] += 1 }
        return (counts, groups.map(\.members.count).max() ?? 0)
    }

    /// How many photos either side, in date order, the report compares each photo with. Long runs
    /// (a day of bursts can chain thousands of photos) made comparing every pair take many seconds.
    public static let histogramWindow = 32

    /// Each compared photo's distance to its closest neighbour among the photos taken just before
    /// and after it, for tuning the thresholds: a histogram in steps of 0.02 up to 0.3, plus everything above.
    public static func nearestNeighbourHistogram(clusters: [[String]], vectors: [String: FeatureVector]) -> [(upTo: Float, count: Int)] {
        let edges: [Float] = stride(from: 0.02, through: 0.3001, by: 0.02).map { Float($0) } + [.infinity]
        var counts = [Int](repeating: 0, count: edges.count)
        for cluster in clusters {
            let ids = cluster.filter { vectors[$0] != nil }
            for i in ids.indices {
                var nearest = Float.infinity
                let v = vectors[ids[i]]!
                let window = max(ids.startIndex, i - histogramWindow)..<min(ids.endIndex, i + histogramWindow + 1)
                for j in window where j != i { nearest = min(nearest, v.distance(to: vectors[ids[j]]!)) }
                if let bin = edges.firstIndex(where: { nearest <= $0 }), nearest.isFinite { counts[bin] += 1 }
            }
        }
        return zip(edges, counts).map { ($0, $1) }
    }
}
