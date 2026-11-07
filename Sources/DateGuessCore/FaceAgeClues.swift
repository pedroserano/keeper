import Foundation

/// "Peter looks about 4 here (born 1984) → about 1988": a face-age model's reading of each named
/// person, turned into years with their birth year and combined across everyone in the photo.
///
/// Follows "Photo Dating by Facial Age Aggregation" (Paplhám & Franc, 2025): each recognized face
/// gives a spread of likely years (birth year + apparent age), and the faces in one photo are
/// combined so people who agree reinforce each other. The model's age readings are corrected with
/// faces whose age is known from dated photos in this library (e.g. it reads teenagers ~5 years old).
public enum FaceAgeClues {
    /// One named person's face in a photo, as the model read it.
    public struct Reading: Codable, Hashable, Sendable {
        public var personID: UUID
        public var age: Double

        public init(personID: UUID, age: Double) {
            self.personID = personID
            self.age = age
        }
    }

    /// How far off the model tends to be, by the age it reads.
    public struct Correction: Codable, Hashable, Sendable {
        public struct Bracket: Codable, Hashable, Sendable {
            public var below: Double
            /// Subtracted from the reading.
            public var bias: Double
            /// About how many years off a corrected reading still is.
            public var spread: Double
            /// Known-age faces it was learned from (0: the defaults).
            public var checked: Int
        }

        public var brackets: [Bracket]

        /// Before any faces of known age are checked: the model's published accuracy, tighter for
        /// young children (on this library: babies within ~1 year, preschoolers within ~2).
        public static let standard = Correction(brackets: [
            .init(below: 3, bias: 0, spread: 1, checked: 0),
            .init(below: 8, bias: 0, spread: 1.6, checked: 0),
            .init(below: 13, bias: 0, spread: 3.5, checked: 0),
            .init(below: 20, bias: 0, spread: 4.5, checked: 0),
            .init(below: 30, bias: 0, spread: 5, checked: 0),
            .init(below: 45, bias: 0, spread: 6, checked: 0),
            .init(below: .infinity, bias: 0, spread: 8, checked: 0),
        ])

        public init(brackets: [Bracket]) { self.brackets = brackets }

        public func bracket(_ age: Double) -> Bracket { brackets.first { age < $0.below } ?? brackets[brackets.count - 1] }

        public static let minimumToLearn = 20
        /// Readings further than this from the bracket's typical error are left out of learning.
        public static let outlierYears = 8.0

        /// Learns each bracket's bias and spread from faces whose real age is known. A bracket keeps
        /// the defaults until it has enough faces; spreads never get tighter than the defaults' half.
        public static func learn(_ pairs: [(read: Double, real: Double)]) -> Correction {
            var out = standard
            for i in out.brackets.indices {
                let low = i == 0 ? -Double.infinity : out.brackets[i - 1].below
                let all = pairs.filter { $0.read >= low && $0.read < out.brackets[i].below }.map { $0.read - $0.real }.sorted()
                guard all.count >= minimumToLearn else { continue }
                // A "dated" photo can be a phone picture of an old print, dated the day it was
                // photographed: the child in it then seems decades older than they look. Errors that
                // big aren't the model's, so they're left out.
                let middle = all[all.count / 2]
                let errors = all.filter { abs($0 - middle) <= outlierYears }
                guard errors.count >= minimumToLearn else { continue }
                let bias = errors[errors.count / 2]
                let left = errors.map { abs($0 - bias) }.sorted()
                // ~68% of corrected readings fall within this.
                let spread = left[Int(Double(left.count - 1) * 0.68)]
                out.brackets[i].bias = bias
                out.brackets[i].spread = max(standard.brackets[i].spread / 2, spread)
                out.brackets[i].checked = errors.count
            }
            return out
        }
    }

    /// Where a person's birth falls in the year (mid-year when only the year is known).
    static func birth(_ person: PersonInfo) -> Double? {
        guard let year = person.birthYear else { return nil }
        return Double(year) + (Double(person.birthMonth ?? 7) - 0.5) / 12
    }

    /// One clue from all the named people's faces in a photo, or nil without any with a birth year.
    public static func evidence(_ readings: [Reading], people: [PersonInfo], correction: Correction = .standard) -> DateEvidence? {
        let byID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var faces: [(name: String, read: Double, mean: Double, spread: Double)] = []
        for r in readings {
            guard let person = byID[r.personID], let born = birth(person) else { continue }
            let b = correction.bracket(r.age)
            let age = max(0, r.age - b.bias)
            faces.append((person.name, age, born + age, b.spread))
        }
        guard !faces.isEmpty else { return nil }
        func combine(_ f: [(name: String, read: Double, mean: Double, spread: Double)]) -> (mean: Double, spread: Double) {
            let w = f.map { 1 / ($0.spread * $0.spread) }
            let total = w.reduce(0, +)
            return (zip(f, w).reduce(0) { $0 + $1.0.mean * $1.1 } / total, (1 / total).squareRoot())
        }
        var kept = faces
        // A face far from everyone else is probably someone else (or a misread): leave it out.
        if kept.count > 1 {
            let all = combine(kept)
            let agreeing = kept.filter { abs($0.mean - all.mean) <= 2.5 * ($0.spread * $0.spread + all.spread * all.spread).squareRoot() }
            if !agreeing.isEmpty { kept = agreeing }
        }
        let (mean, spread) = combine(kept)
        // A floor for the model's own mistakes that don't shrink with more faces (lighting, a scan).
        let width = max(0.8, spread) * 1.5
        let low = Int((mean - width).rounded(.down)), high = Int((mean + width).rounded(.down))
        let peak = Int(mean.rounded(.down))
        let weight: Double = spread <= 1 ? 0.85 : spread <= 2 ? 0.7 : spread <= 4 ? 0.5 : spread <= 6 ? 0.3 : 0.15
        let who = kept.map { "\($0.name) looks about \(Int($0.read.rounded()))" }.joined(separator: ", ")
        let years = low == high ? "\(low)" : "\(low)–\(high)"
        var e = DateEvidence(source: .person, summary: "Faces: \(who) → \(years)",
                             yearLow: low, yearHigh: high, peakYear: peak, weight: weight)
        e.calibrationKey = "person:faceModel"
        return e
    }
}
