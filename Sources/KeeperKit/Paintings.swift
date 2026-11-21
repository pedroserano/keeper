// Paintings: photos of paintings, like the ones on a museum wall, in two lists.
//
// - Paintings: the likely ones, to add to the Paintings album.
// - Maybe Paintings: everything borderline, most likely first, so you can say yes or no to each
//   and be sure none were missed.
// Photos in the Paintings album and ones you've said aren't paintings are in neither.
//
// From Photos' own "painting" scene label, measured on one library against an album of museum
// paintings and a random sample of 3,816 other photos:
// - Photos 70% sure or more: 40% of the album, and every such photo outside it was a painting
//   or a museum or palace interior.
// - Adding photos Photos is at least 30% sure of that look like one of those (a fingerprint
//   within 0.2) caught paintings shot at an angle or in a wider view: 53% of the album, with 4 of
//   the 3,816 others.
// - Photos where a face fills much of the frame were mostly people in a room with a picture on
//   the wall, so they're only ever a maybe.
// Paintings you confirm (the album) teach it: their look-alikes join the likely list, and photos
// Photos didn't label that look very like them become maybes.

import KeeperCore

public enum Paintings {
    /// Photos this sure are paintings on their own.
    public static let sure = 0.7
    /// Photos at least this sure are maybes, and likely when they look like a painting.
    public static let possible = 0.3
    /// How close a fingerprint must be to a known painting's to count as looking like it.
    public static let lookAlike: Float = 0.2
    /// Photos Photos didn't label are maybes when this close to a painting you confirmed.
    public static let unlabelledLookAlike: Float = 0.15
    /// A face at least this big (Photos' face size) makes it more likely a photo of someone.
    public static let face = 0.05

    public struct Lists: Sendable, Equatable {
        /// Each photo's place in its list, lowest first.
        public var likely: [String: Double] = [:]
        public var maybe: [String: Double] = [:]
        public init() {}
    }

    /// - scores: Photos' painting label, for photos it gave one.
    /// - prints: fingerprints of those photos and of `confirmed`.
    /// - confirmed: photos in the Paintings album. `rejected`: ones you said aren't paintings.
    /// - unlabelledNearConfirmed: photos without a label, by distance to the nearest confirmed one.
    public static func lists(scores: [String: PaintingScore], prints: [String: FeatureVector],
                             confirmed: Set<String>, rejected: Set<String>,
                             unlabelledNearConfirmed: [String: Float] = [:]) -> Lists {
        var out = Lists()
        let open = scores.filter { !confirmed.contains($0.key) && !rejected.contains($0.key) && $0.value.painting >= possible }
        let isFace = { (s: PaintingScore) in s.largestFace >= face }
        var seeds = confirmed.compactMap { prints[$0] }
        for (uuid, s) in open where s.painting >= sure && !isFace(s) {
            out.likely[uuid] = -s.painting
            if let p = prints[uuid] { seeds.append(p) }
        }
        for (uuid, s) in open where out.likely[uuid] == nil {
            let nearest = prints[uuid].flatMap { p in seeds.lazy.map { p.distance(to: $0) }.min() } ?? 2
            if !isFace(s), s.painting < sure, nearest <= lookAlike {
                out.likely[uuid] = Double(nearest)
            } else {
                // Most likely first: Photos' confidence, raised by looking like a painting, lowered by a face.
                let likeness = nearest <= lookAlike ? 0.2 : 0
                out.maybe[uuid] = -(s.painting + likeness - (isFace(s) ? 0.5 : 0))
            }
        }
        for (uuid, d) in unlabelledNearConfirmed where d <= unlabelledLookAlike
            && scores[uuid] == nil && !confirmed.contains(uuid) && !rejected.contains(uuid) {
            out.maybe[uuid] = -(0.3 - Double(d))
        }
        return out
    }
}
