import Foundation

/// How often each built-in clue was right on photos the user has already dated, used to count
/// unreliable clues less on the rest of their library.
///
/// Only the general-purpose clues are checked (color and tone, borders, print shape, scenes, file
/// size): they're tuned for a typical family archive and can be badly off for one library, like a
/// "faded 1970s print" look on digital photos from 2003. Clues that come from the user's own
/// library (albums, filenames, people, groups) aren't touched.
///
/// A clue is only ever counted *less*, never more. The user often accepts the app's own guess, so a
/// clue that drove that guess looks right whether it was or not; trusting such a clue more would feed on itself.
public struct ClueCalibration: Codable, Hashable, Sendable {
    public struct Stat: Codable, Hashable, Sendable {
        public var count = 0
        public var hits = 0

        public init(count: Int = 0, hits: Int = 0) {
            self.count = count
            self.hits = hits
        }

        /// 0…1: how much of the clue's weight to keep. Starts from "works as designed" and moves
        /// toward what this library shows as photos are dated.
        public var factor: Double {
            let observed = (Double(hits) + ClueCalibration.priorCount * ClueCalibration.expectedHitRate)
                / (Double(count) + ClueCalibration.priorCount)
            return min(1, observed / ClueCalibration.expectedHitRate)
        }

        /// Clearly wrong for this library: leave it out.
        public var isDropped: Bool { count >= ClueCalibration.minimumToDrop && factor < ClueCalibration.dropBelow }
    }

    /// A clue that works as designed lands in its range (or season) about this often.
    static let expectedHitRate = 0.7
    /// How many dated photos it takes before what they show outweighs the default.
    static let priorCount = 10.0
    static let minimumToDrop = 20
    static let dropBelow = 0.15

    public var year: [String: Stat] = [:]
    public var season: [String: Stat] = [:]

    public init(year: [String: Stat] = [:], season: [String: Stat] = [:]) {
        self.year = year
        self.season = season
    }

    /// One photo the user dated, with the clues the app had for it.
    public struct Confirmed: Sendable {
        public var evidence: [DateEvidence]
        public var year: Int
        public var month: Int

        public init(evidence: [DateEvidence], year: Int, month: Int) {
            self.evidence = evidence
            self.year = year
            self.month = month
        }
    }

    static let calibrated: Set<EvidenceSource> = [.colorTone, .borderPaper, .printFormat, .scene, .fileFormat]

    /// Which clue this is, the same for every photo it fires on. Nil for clues that aren't checked.
    public static func key(_ e: DateEvidence) -> String? {
        guard !e.isHardConstraint else { return nil }
        if let key = e.calibrationKey { return key }
        guard calibrated.contains(e.source) else { return nil }
        // The look-alike clue has its own check (how well its closest photos agree).
        guard !e.summary.hasPrefix("Looks most like") else { return nil }
        // Notes added by `adjusted` don't change which clue it is.
        let summary = e.summary.components(separatedBy: noteSeparator)[0]
        return "\(e.source.rawValue):\(summary)"
    }

    public static func build(_ photos: [Confirmed]) -> ClueCalibration {
        var out = ClueCalibration()
        for photo in photos {
            for e in photo.evidence {
                guard let key = key(e) else { continue }
                if e.weight > 0, e.yearLow != nil || e.yearHigh != nil {
                    let inside = (e.yearLow ?? .min) <= photo.year && photo.year <= (e.yearHigh ?? .max)
                    out.year[key, default: Stat()].count += 1
                    if inside { out.year[key, default: Stat()].hits += 1 }
                }
                if let s = e.season, e.seasonWeight > 0 {
                    out.season[key, default: Stat()].count += 1
                    if Season.from(month: photo.month) == s { out.season[key, default: Stat()].hits += 1 }
                }
            }
        }
        return out
    }

    public static let noteSeparator = " — "

    /// The clue with its weight scaled to how well it has done in this library, and a note saying so.
    public func adjusted(_ e: DateEvidence) -> DateEvidence {
        guard let key = Self.key(e) else { return e }
        var out = e
        var notes: [String] = []
        if let s = year[key], e.weight > 0, s.factor < 0.95 {
            out.weight = s.isDropped ? 0 : e.weight * s.factor
            notes.append(Self.note(s, what: "year"))
        }
        if let s = season[key], e.seasonWeight > 0, s.factor < 0.95 {
            out.seasonWeight = s.isDropped ? 0 : e.seasonWeight * s.factor
            if s.isDropped || out.seasonWeight < 0.5 { out.exactMonth = nil }
            notes.append(Self.note(s, what: "season"))
        }
        if !notes.isEmpty { out.summary = e.summary + Self.noteSeparator + notes.joined(separator: "; ") }
        return out
    }

    static func note(_ s: Stat, what: String) -> String {
        s.isDropped
            ? "\(what) usually wrong in your library (right \(s.hits) of \(s.count) times), so it’s left out"
            : "\(what) right \(s.hits) of \(s.count) times in your library, so it counts less"
    }
}
