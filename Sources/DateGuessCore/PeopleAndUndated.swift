import Foundation

// MARK: - People

/// Turns "this person appears, looking about N years old" into a year range using their birth date.
public enum PeopleClues {
    /// The person exists in the photo, so it can't predate their birth. Nil without a birth year.
    public static func presence(of person: PersonInfo, via: String = "") -> DateEvidence? {
        guard let born = person.birthYear else { return nil }
        return DateEvidence(source: .person, summary: "\(person.name) (born \(born)) is in this photo\(via)",
                            yearLow: born, yearHigh: nil, weight: 1, isHardConstraint: true)
    }

    /// Photos' rough age group for a face (`ZAGETYPE`). Worked out from ~87,000 faces on photos with
    /// trustworthy dates, following children from infancy: 1 is a baby (first year or so), 2 a young
    /// child (about 1–5), 3 older children through adults, 5 older adults (rare before 30, the
    /// majority later). 4 is almost never used. 3 and 5 overlap a lot, so they're weak clues.
    /// Apple doesn't document these. The one public mapping (mac4n6.com, 2020: 1–2 "Baby / Toddler",
    /// 3 "Child / Young Adult", 4 "Young Adult / Adult", 5 "Adult") has the same order.
    public static func faceAgeGroup(of person: PersonInfo, type: Int) -> DateEvidence? {
        guard let born = person.birthYear else { return nil }
        let (lo, hi, weight, label): (Int, Int?, Double, String)
        switch type {
        case 1: (lo, hi, weight, label) = (0, 1, 0.75, "looks like a baby")
        case 2: (lo, hi, weight, label) = (1, 6, 0.6, "looks like a young child")
        // 3 (older child or adult) and 5 (adult) only say "after some year". As a weighted clue that
        // pulled guesses toward that year: on this library "Peter looks older than a young child →
        // 1988 or later" moved 2019 photos to 2002. The birth year already sets the limit, so they're
        // left out.
        default: return nil
        }
        let range = hi.map { "\(born + lo)–\(born + $0)" } ?? "\(born + lo) or later"
        var e = DateEvidence(source: .person,
                             summary: "Photos thinks \(person.name) \(label) here (born \(born)) → \(range)",
                             yearLow: born + lo, yearHigh: hi.map { born + $0 }, weight: weight)
        // Checked against the user's dated photos per age group, pooled across people.
        e.calibrationKey = "person:faceAge:\(type)"
        return e
    }

    /// Apparent age → year range. `matchConfidence` is how sure we are it's really them.
    public static func age(of person: PersonInfo, ageLow: Int, ageHigh: Int, matchConfidence: Double,
                           userProvided: Bool = false) -> DateEvidence? {
        guard let birthYear = person.birthYear else { return nil }
        let lo = max(0, min(ageLow, ageHigh)), hi = max(ageLow, ageHigh)
        let slack = userProvided ? 1 : 1 + (hi >= 30 ? 2 : 0)
        let yearLo = birthYear + lo - slack
        let yearHi = birthYear + hi + slack
        let ageText = lo == hi ? "about \(lo)" : "\(lo)–\(hi)"
        let weight = userProvided ? 0.85 : 0.35 + 0.45 * max(0, min(1, matchConfidence))
        let who = userProvided ? "You said \(person.name) is" : "\(person.name) looks"
        return DateEvidence(source: .person,
                            summary: "\(who) \(ageText) years old here (born \(birthYear)) → \(yearLo)–\(yearHi)",
                            yearLow: max(birthYear, yearLo), yearHigh: yearHi,
                            peakYear: birthYear + (lo + hi) / 2, weight: weight)
    }
}

// MARK: - Undated detection

/// Capture-date related metadata read from the original file.
public struct EmbeddedDateInfo: Codable, Hashable, Sendable {
    public var dateTimeOriginal: String?
    public var dateTimeDigitized: String?
    public var tiffDateTime: String?
    public var make: String?
    public var model: String?
    public var software: String?
    public var hasGPS: Bool

    public init(dateTimeOriginal: String? = nil, dateTimeDigitized: String? = nil, tiffDateTime: String? = nil,
                make: String? = nil, model: String? = nil, software: String? = nil, hasGPS: Bool = false) {
        self.dateTimeOriginal = dateTimeOriginal
        self.dateTimeDigitized = dateTimeDigitized
        self.tiffDateTime = tiffDateTime
        self.make = make
        self.model = model
        self.software = software
        self.hasGPS = hasGPS
    }
}

public enum UndatedReason: String, Codable, CaseIterable, Sendable {
    case missingDate
    case implausibleDate
    case noCaptureDateInFile
    case scannerDate
    case albumRule
    case dateRangeRule

    public var explanation: String {
        switch self {
        case .missingDate: return "No date at all"
        case .implausibleDate: return "Impossible or camera-default date"
        case .noCaptureDateInFile: return "File has no capture date (date shown is import/scan time)"
        case .scannerDate: return "Date comes from a scanner, not the original photo"
        case .albumRule: return "In an album you marked as undated"
        case .dateRangeRule: return "Dated within a scanning session you marked"
        }
    }
}

/// A span of library dates the user knows are wrong (e.g. the week they scanned a shoebox of prints).
public struct DateRangeRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var start: Date
    public var end: Date

    public init(id: UUID = UUID(), label: String, start: Date, end: Date) {
        self.id = id
        self.label = label
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool { date >= start && date <= end }
}

public enum UndatedDetector {
    /// Checks needing only the library date (fast enough for 250k+ photos).
    public static func fastCheck(creationDate: Date?, now: Date = Date(), rules: [DateRangeRule] = []) -> UndatedReason? {
        guard let date = creationDate else { return .missingDate }
        if isImplausible(date, now: now) { return .implausibleDate }
        if rules.contains(where: { $0.contains(date) }) { return .dateRangeRule }
        return nil
    }

    static func isImplausible(_ date: Date, now: Date) -> Bool {
        if date > now.addingTimeInterval(2 * 86_400) { return true }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        if cal.component(.year, from: date) < YearBounds.earliestPhotoYear { return true }
        // Common "clock was never set" defaults: midnight Jan 1 of 1970/1980/2000/2001 in some time zone.
        for year in [1970, 1980, 2000, 2001] {
            guard let midnight = cal.date(from: DateComponents(year: year, month: 1, day: 1)) else { continue }
            let diff = date.timeIntervalSince(midnight)
            if abs(diff) <= 14 * 3600 && diff.truncatingRemainder(dividingBy: 1800) == 0 { return true }
        }
        return false
    }

    /// Checks needing the file's own metadata.
    public static func embeddedCheck(_ info: EmbeddedDateInfo) -> UndatedReason? {
        let original = info.dateTimeOriginal?.trimmingCharacters(in: .whitespaces) ?? ""
        let hasOriginal = !original.isEmpty && !original.hasPrefix("0000")
        if looksLikeScanner(make: info.make, model: info.model, software: info.software) {
            // Scanners stamp the scan time. Trust DateTimeOriginal only if someone set it to something else.
            if !hasOriginal || original == (info.dateTimeDigitized ?? "") || original == (info.tiffDateTime ?? "") {
                return .scannerDate
            }
            return nil
        }
        return hasOriginal ? nil : .noCaptureDateInFile
    }

    static let scannerKeywords = [
        "scan", "fastfoto", "perfection", "ff-6", "ff-680", "canoscan", "plustek", "opticfilm", "vuescan",
        "silverfast", "photomyne", "photoscan", "scanza", "wolverine", "magnasonic", "digitnow", "kodak slide n scan",
        "imagescan", "epson scan", "hp scanjet", "scansnap", "flatbed", "coolscan", "reflecta", "pacific image",
    ]

    public static func looksLikeScanner(make: String?, model: String?, software: String?) -> Bool {
        let text = [make, model, software].compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !text.isEmpty else { return false }
        return scannerKeywords.contains { text.contains($0) }
    }
}

// MARK: - Group suggestions

public struct GroupCandidate: Sendable {
    public var assetID: String
    public var filename: String?
    public var libraryDate: Date?
    public var albums: [String]

    public init(assetID: String, filename: String?, libraryDate: Date?, albums: [String]) {
        self.assetID = assetID
        self.filename = filename
        self.libraryDate = libraryDate
        self.albums = albums
    }
}

public struct GroupSuggestion: Identifiable, Hashable, Sendable {
    public var id: String { title + "\(assetIDs.count)" + (assetIDs.first ?? "") }
    public var title: String
    public var reason: String
    public var assetIDs: [String]
    public var kind: GroupKind

    public init(title: String, reason: String, assetIDs: [String], kind: GroupKind) {
        self.title = title
        self.reason = reason
        self.assetIDs = assetIDs
        self.kind = kind
    }
}

/// Suggests groups the user can accept: albums, and runs of sequentially-numbered scans
/// imported together (a roll of film or an album page scanned in one sitting).
public enum GroupSuggester {
    public static func suggest(_ candidates: [GroupCandidate], minRunLength: Int = 4) -> [GroupSuggestion] {
        var out: [GroupSuggestion] = []

        // Albums
        var byAlbum: [String: [String]] = [:]
        for c in candidates {
            for a in c.albums { byAlbum[a, default: []].append(c.assetID) }
        }
        for (album, ids) in byAlbum where ids.count >= 2 {
            out.append(GroupSuggestion(title: album, reason: "\(ids.count) undated photos in the album “\(album)”",
                                       assetIDs: ids, kind: .sameEra))
        }

        // Sequential filename runs
        struct Parsed { let id: String; let prefix: String; let number: Int; let date: Date?; let name: String }
        var parsed: [Parsed] = []
        for c in candidates {
            guard let name = c.filename, let (prefix, number) = splitCounter(name) else { continue }
            parsed.append(Parsed(id: c.assetID, prefix: prefix, number: number, date: c.libraryDate, name: name))
        }
        parsed.sort { ($0.prefix, $0.number) < ($1.prefix, $1.number) }
        var run: [Parsed] = []
        func flush() {
            if run.count >= minRunLength, let first = run.first, let last = run.last {
                out.append(GroupSuggestion(title: "\(first.name) … \(last.name)",
                                           reason: "\(run.count) sequentially numbered files imported together (likely one roll, album or scanning session)",
                                           assetIDs: run.map(\.id), kind: .sameEra))
            }
            run.removeAll()
        }
        for p in parsed {
            if let prev = run.last {
                let sequential = p.prefix == prev.prefix && p.number - prev.number <= 2
                var closeInTime = true
                if let a = p.date, let b = prev.date { closeInTime = abs(a.timeIntervalSince(b)) <= 30 * 60 }
                if !(sequential && closeInTime) { flush() }
            }
            run.append(p)
        }
        flush()
        return out.sorted { $0.assetIDs.count > $1.assetIDs.count }
    }

    /// "Scan_0042.jpg" → ("scan_", 42)
    static func splitCounter(_ filename: String) -> (String, Int)? {
        var base = filename
        if let dot = base.lastIndex(of: ".") { base = String(base[..<dot]) }
        let chars = Array(base)
        var end = chars.count
        while end > 0, !chars[end - 1].isNumber { end -= 1 }
        var start = end
        while start > 0, chars[start - 1].isNumber { start -= 1 }
        guard start < end, end - start <= 6, let n = Int(String(chars[start..<end])) else { return nil }
        let prefix = String(chars[0..<start]).lowercased()
        return (prefix, n)
    }
}

// MARK: - Matching names

public enum PersonMatcher {
    /// Finds the person a free-text name refers to ("dad (john)", "John Smith", "Grandma Rose").
    /// Exact matches win, then a full name contained in the text, then a unique first-name match.
    public static func match(_ text: String, in people: [PersonInfo]) -> PersonInfo? {
        let needle = normalize(text)
        guard !needle.isEmpty else { return nil }
        let named = people.filter { !normalize($0.name).isEmpty }
        if let exact = named.first(where: { normalize($0.name) == needle }) { return exact }
        let words = Set(needle.split(separator: " ").map(String.init))
        let contained = named.filter { p in
            let nameWords = normalize(p.name).split(separator: " ").map(String.init)
            return !nameWords.isEmpty && nameWords.allSatisfy(words.contains)
        }
        if contained.count == 1 { return contained[0] }
        let byFirst = named.filter { p in
            guard let first = normalize(p.name).split(separator: " ").first else { return false }
            return words.contains(String(first))
        }
        return byFirst.count == 1 ? byFirst[0] : nil
    }

    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let cleaned = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Clues from where the photo came from

public enum ProvenanceClues {
    /// The user knows their library has no photos older than this year.
    public static func earliestYear(_ year: Int) -> DateEvidence {
        DateEvidence(source: .prior, summary: "You said there are no photos from before \(year)",
                     yearLow: year, yearHigh: nil, weight: 1, isHardConstraint: true)
    }

    /// For scans and imports the library date is when the file was made, so the photo can't be newer.
    public static func libraryDateLimit(reason: UndatedReason, libraryDate: Date?,
                                        calendar: Calendar = .current) -> DateEvidence? {
        guard let libraryDate else { return nil }
        switch reason {
        case .noCaptureDateInFile, .scannerDate, .dateRangeRule: break
        case .missingDate, .implausibleDate, .albumRule: return nil
        }
        let year = calendar.component(.year, from: libraryDate)
        guard YearBounds.isPlausible(year) else { return nil }
        return DateEvidence(source: .libraryDate,
                            summary: "Scanned or imported in \(year), so it was taken in \(year) or earlier",
                            yearLow: nil, yearHigh: year, weight: 1, isHardConstraint: true)
    }
}
