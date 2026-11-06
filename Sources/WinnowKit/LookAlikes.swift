// Duplicates and similar shots, each kind in its own list, and which photo of each group to keep.
//
// The keeper is picked by KeeperRules (Winnow › Settings): an ordered list of rules, each checked
// or not, each saying which side to mark (not keep). Rules are tried in order; each one keeps only
// the photos that do best on it, and the first one where they differ decides. Sizes within
// `KeeperRules.sizeTie` of the best count as a tie, so the next rule gets a say. What's left at the
// end is decided by how good the photo looks. By default:
// - a rejected photo is never kept while another isn't, nor a take with someone's eyes closed
//   while another has them open;
// - the most pixels, then a RAW or HEIC original among photos about that big, then the biggest
//   file, which holds the most detail;
// - then how good it looks and how its faces look, then Favorite, rating and albums.
// You can always pick a different photo to keep before merging.

import WinnowCore

/// One thing a keeper rule looks at.
public enum KeeperRule: String, Codable, CaseIterable, Sendable {
    case rejected, eyes, fileType, dimensions, fileSize, quality, faceQuality, favorite, rating, album
    case missing, portrait, hdr, live, keywords, title, caption, location, metadata, referenced
    case fileName, captureDate, addedDate, modifiedDate

    public var title: String {
        switch self {
        case .rejected: "Rejected"
        case .eyes: "Eyes"
        case .fileType: "File Type"
        case .dimensions: "Dimensions"
        case .fileSize: "File Size"
        case .quality: "Quality Score"
        case .faceQuality: "Face Quality"
        case .favorite: "Favorite"
        case .rating: "Rating"
        case .album: "Album"
        case .missing: "Missing"
        case .portrait: "Portrait Photos"
        case .hdr: "HDR Photos"
        case .live: "Live Photos"
        case .keywords: "Keywords"
        case .title: "Title"
        case .caption: "Caption"
        case .location: "Geo Location"
        case .metadata: "Metadata"
        case .referenced: "Referenced"
        case .fileName: "File Name"
        case .captureDate: "Capture Date"
        case .addedDate: "Created Date"
        case .modifiedDate: "Modified Date"
        }
    }

    public var systemImage: String {
        switch self {
        case .rejected: "xmark.circle"
        case .eyes: "eye"
        case .fileType: "doc"
        case .dimensions: "arrow.up.left.and.arrow.down.right"
        case .fileSize: "internaldrive"
        case .quality: "sparkles"
        case .faceQuality: "face.smiling"
        case .favorite: "heart"
        case .rating: "star"
        case .album: "rectangle.stack"
        case .missing: "questionmark.circle"
        case .portrait: "cube"
        case .hdr: "camera.aperture"
        case .live: "livephoto"
        case .keywords: "tag"
        case .title: "textformat"
        case .caption: "text.bubble"
        case .location: "location"
        case .metadata: "info.circle"
        case .referenced: "link"
        case .fileName: "character.cursor.ibeam"
        case .captureDate: "camera"
        case .addedDate: "calendar.badge.plus"
        case .modifiedDate: "pencil"
        }
    }

    /// What's marked (not kept) for each direction: keeping the higher value, or the lower.
    public func markLabel(keepHigher: Bool) -> String {
        switch self {
        case .rejected: keepHigher ? "mark rejected" : "mark not rejected"
        case .eyes: keepHigher ? "mark eyes closed" : "mark eyes open"
        case .fileType: keepHigher ? "mark non RAW+HEIC" : "mark RAW+HEIC"
        case .dimensions, .fileSize: keepHigher ? "mark smaller" : "mark larger"
        case .quality, .faceQuality: keepHigher ? "mark worse" : "mark better"
        case .favorite: keepHigher ? "mark non-favorite" : "mark favorite"
        case .rating: keepHigher ? "mark lower rated" : "mark higher rated"
        case .album: keepHigher ? "mark not added to albums" : "mark added to albums"
        case .missing: keepHigher ? "mark missing" : "mark not missing"
        case .portrait: keepHigher ? "mark not portrait" : "mark portrait"
        case .hdr: keepHigher ? "mark not HDR" : "mark HDR"
        case .live: keepHigher ? "mark not live" : "mark live"
        case .keywords, .title, .caption, .location, .metadata: keepHigher ? "mark without" : "mark with"
        case .referenced: keepHigher ? "mark referenced" : "mark in library"
        case .fileName: keepHigher ? "mark shorter" : "mark longer"
        case .captureDate, .addedDate, .modifiedDate: keepHigher ? "mark earlier" : "mark later"
        }
    }

    /// Sizes count as a tie when close (`KeeperRules.sizeTie`).
    var hasTie: Bool { self == .dimensions || self == .fileSize }
}

/// A rule in the list: whether it's used and which way it goes.
public struct KeeperRuleSetting: Codable, Equatable, Sendable, Identifiable {
    public var rule: KeeperRule
    public var enabled: Bool
    /// Keep the photo with the higher value (more pixels, RAW, a Favorite, a later date…).
    public var keepHigher: Bool
    public var id: KeeperRule { rule }

    public init(_ rule: KeeperRule, _ enabled: Bool, keepHigher: Bool) {
        self.rule = rule
        self.enabled = enabled
        self.keepHigher = keepHigher
    }
}

/// How Winnow picks the photo to keep in each group of duplicates or similar shots.
public struct KeeperRules: Codable, Equatable, Sendable {
    public var rules: [KeeperRuleSetting]

    /// Sizes within 5% of the best count as the same, so the next rule decides.
    public static let sizeTie = 0.05

    public init(rules: [KeeperRuleSetting]) { self.rules = Self.complete(rules) }

    public static let standard = KeeperRules(rules: [
        .init(.rejected, true, keepHigher: true),
        .init(.eyes, true, keepHigher: true),
        // Dimensions before File Type: a RAW original wins when it's about as big (within sizeTie),
        // not when it's much smaller.
        .init(.dimensions, true, keepHigher: true),
        .init(.fileType, true, keepHigher: true),
        .init(.fileSize, true, keepHigher: true),
        .init(.quality, true, keepHigher: true),
        .init(.faceQuality, true, keepHigher: true),
        .init(.favorite, true, keepHigher: true),
        .init(.rating, true, keepHigher: true),
        .init(.album, true, keepHigher: true),
        .init(.missing, false, keepHigher: true),
        .init(.portrait, false, keepHigher: true),
        .init(.hdr, false, keepHigher: true),
        .init(.live, false, keepHigher: true),
        .init(.keywords, false, keepHigher: true),
        .init(.title, false, keepHigher: true),
        .init(.caption, false, keepHigher: true),
        .init(.location, false, keepHigher: true),
        .init(.metadata, false, keepHigher: true),
        .init(.referenced, false, keepHigher: true),
        .init(.fileName, false, keepHigher: false),
        .init(.captureDate, false, keepHigher: false),
        .init(.addedDate, false, keepHigher: false),
        .init(.modifiedDate, false, keepHigher: false),
    ])

    /// Every rule once, in the saved order; rules added in a later version go at the end, unchecked.
    static func complete(_ rules: [KeeperRuleSetting]) -> [KeeperRuleSetting] {
        var seen = Set<KeeperRule>()
        var out = rules.filter { seen.insert($0.rule).inserted }
        for rule in KeeperRule.allCases where !seen.contains(rule) {
            out.append(.init(rule, false, keepHigher: rule.defaultKeepsHigher))
        }
        return out
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Rules this version doesn't know (from a newer one) are skipped, not fatal.
        let raw = try container.decode([FailableRule].self, forKey: .rules)
        self.init(rules: raw.compactMap(\.value))
    }

    private struct FailableRule: Decodable {
        let value: KeeperRuleSetting?
        init(from decoder: Decoder) throws { value = try? KeeperRuleSetting(from: decoder) }
    }
}

extension KeeperRule {
    var defaultKeepsHigher: Bool {
        KeeperRules.standard.rules.first { $0.rule == self }?.keepHigher ?? true
    }
}

/// What the rules know about a photo, beyond its file details.
public struct KeeperFacts: Sendable {
    public var score: @Sendable (String) -> Double
    public var files: [String: FileInfo]
    public var faces: [String: FaceInfo]
    /// Photos you've rejected in Winnow.
    public var rejected: Set<String>

    public init(score: @escaping @Sendable (String) -> Double, files: [String: FileInfo],
                faces: [String: FaceInfo] = [:], rejected: Set<String> = []) {
        self.score = score
        self.files = files
        self.faces = faces
        self.rejected = rejected
    }

    /// The rule's value for a photo, higher meaning more of it; nil when unknown.
    func value(_ rule: KeeperRule, _ id: String) -> Double? {
        let f = files[id]
        func flag(_ b: Bool?) -> Double? { b.map { $0 ? 1 : 0 } }
        switch rule {
        case .rejected: return rejected.contains(id) ? 0 : 1
        case .eyes: return faces[id]?.eyesClosed == true ? 0 : 1
        case .fileType: return flag(f.map { $0.isRaw || $0.isHEIC })
        case .dimensions: return f?.pixels.map(Double.init)
        case .fileSize: return f?.bytes.map(Double.init)
        case .quality:
            let s = score(id)
            return s.isFinite ? s : nil
        case .faceQuality: return faces[id]?.quality
        case .favorite: return flag(f?.favorite)
        case .rating: return f.map { Double($0.rating) }
        case .album: return flag(f?.inAlbum)
        case .missing: return flag(f.map { !$0.missing })
        case .portrait: return flag(f?.portrait)
        case .hdr: return flag(f?.hdr)
        case .live: return flag(f?.live)
        case .keywords: return flag(f?.hasKeywords)
        case .title: return flag(f?.hasTitle)
        case .caption: return flag(f?.hasCaption)
        case .location: return flag(f?.hasLocation)
        case .metadata: return flag(f?.hasCameraMetadata)
        case .referenced: return flag(f.map { !$0.referenced })
        case .fileName: return f?.filename.map { Double($0.count) }
        case .captureDate: return f?.captureDate
        case .addedDate: return f?.addedDate
        case .modifiedDate: return f?.modifiedDate
        }
    }
}

public struct LookAlikeGroup: Sendable, Equatable, Identifiable {
    public let kind: SimilarGroup.Kind
    /// The one to keep first, then the rest, best-looking first.
    public let members: [String]
    public let keeper: String
    /// Stays the same whichever photo is kept.
    public let id: String

    public init(kind: SimilarGroup.Kind, members: [String], keeper: String) {
        self.kind = kind
        self.members = members
        self.keeper = keeper
        id = (kind == .duplicate ? "d:" : "s:") + (members.min() ?? "")
    }

    public var others: [String] { members.filter { $0 != keeper } }

    /// The same group, keeping another of its photos instead.
    public func keeping(_ uuid: String) -> LookAlikeGroup {
        guard members.contains(uuid) else { return self }
        return LookAlikeGroup(kind: kind, members: [uuid] + members.filter { $0 != uuid }, keeper: uuid)
    }
}

public enum LookAlikes {
    public static func build(groups: [SimilarGroup], score: @escaping @Sendable (String) -> Double,
                             files: [String: FileInfo], faces: [String: FaceInfo] = [:],
                             rules: KeeperRules = .standard) -> [LookAlikeGroup] {
        build(groups: groups, facts: KeeperFacts(score: score, files: files, faces: faces), rules: rules)
    }

    public static func build(groups: [SimilarGroup], facts: KeeperFacts, rules: KeeperRules = .standard) -> [LookAlikeGroup] {
        groups.compactMap { group in
            guard group.members.count > 1 else { return nil }
            let keeper = suggestedKeeper(group.members, facts: facts, rules: rules)
            let rest = group.members.filter { $0 != keeper }.sorted { facts.score($0) > facts.score($1) }
            return LookAlikeGroup(kind: group.kind, members: [keeper] + rest, keeper: keeper)
        }
    }

    /// Tries the checked rules in order, each keeping only the photos that do best on it, until one
    /// is left; then how good it looks decides.
    public static func suggestedKeeper(_ members: [String], facts: KeeperFacts, rules: KeeperRules = .standard) -> String {
        decidingRule(members, facts: facts, rules: rules).keeper
    }

    /// The keeper, and the rule that picked it (nil when it came down to how good it looks).
    public static func decidingRule(_ members: [String], facts: KeeperFacts,
                                    rules: KeeperRules = .standard) -> (keeper: String, rule: KeeperRule?) {
        var left = members
        for setting in rules.rules where setting.enabled && left.count > 1 {
            let values = left.map { facts.value(setting.rule, $0) }
            let known = values.compactMap { $0 }
            guard !known.isEmpty else { continue }
            let best = setting.keepHigher ? known.max()! : known.min()!
            func passes(_ v: Double?) -> Bool {
                guard let v else { return false }
                guard setting.rule.hasTie else { return v == best }
                let margin = abs(best) * KeeperRules.sizeTie
                return setting.keepHigher ? v >= best - margin : v <= best + margin
            }
            let kept = zip(left, values).filter { passes($0.1) }.map(\.0)
            guard kept.count < left.count else { continue }
            left = kept
            if left.count == 1 { return (left[0], setting.rule) }
        }
        let keeper = left.max { (facts.score($0), $1) < (facts.score($1), $0) } ?? members[0]
        return (keeper, nil)
    }

    /// Members with someone's eyes closed, when another member of the group has them open.
    public static func blinks(in members: [String], faces: [String: FaceInfo]) -> [String] {
        guard members.contains(where: { faces[$0]?.eyesClosed == false }) else { return [] }
        return members.filter { faces[$0]?.eyesClosed == true }
    }
}

/// Moves saved ticks and keeper picks onto the groups that now hold their photos, after the
/// grouping rules change. Group ids are the kind plus the smallest member, so a duplicate group
/// that lost members, or whose photos are now similar shots instead, has a new id.
/// Entries with no new home are left as they are: nothing is dropped.
public enum GroupCarryOver {
    public struct Result: Equatable, Sendable {
        public var selected: Set<String>
        public var choices: [String: String]
        public var moved: Int
        public var leftAlone: Int
    }

    /// Carries over entries for duplicate groups ("d:" ids) that no longer exist. `previous` are the
    /// duplicate groups under the old rule, so a tick reaches every group its photos are now in.
    public static func map(selected: Set<String>, choices: [String: String],
                           groups: [SimilarGroup], previous: [SimilarGroup]) -> Result {
        func id(_ g: SimilarGroup) -> String { (g.kind == .duplicate ? "d:" : "s:") + (g.members.min() ?? "") }
        var ids = Set<String>(), duplicateOf: [String: String] = [:], similarOf: [String: String] = [:]
        for g in groups where g.members.count > 1 {
            ids.insert(id(g))
            for m in g.members {
                if g.kind == .duplicate { duplicateOf[m] = id(g) } else { similarOf[m] = id(g) }
            }
        }
        var oldMembers: [String: [String]] = [:]
        for g in previous where g.kind == .duplicate { oldMembers[id(g)] = g.members }
        func home(_ uuid: String) -> String? { duplicateOf[uuid] ?? similarOf[uuid] }
        func isStale(_ id: String) -> Bool { id.hasPrefix("d:") && !ids.contains(id) }

        var out = Result(selected: selected, choices: choices, moved: 0, leftAlone: 0)
        for old in selected.sorted() where isStale(old) {
            let members = oldMembers[old] ?? [String(old.dropFirst(2))]
            let targets = Set(members.compactMap(home))
            if targets.isEmpty { out.leftAlone += 1; continue }
            out.selected.remove(old)
            out.selected.formUnion(targets)
            out.moved += 1
        }
        for (old, keeper) in choices.sorted(by: { $0.key < $1.key }) where isStale(old) {
            if let target = home(keeper), out.choices[target] == nil {
                out.choices[old] = nil
                out.choices[target] = keeper
                out.moved += 1
            } else { out.leftAlone += 1 }
        }
        return out
    }
}
