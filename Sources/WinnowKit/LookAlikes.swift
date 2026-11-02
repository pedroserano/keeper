// Duplicates and similar shots, each kind in its own list, and which photo of each group to keep.
//
// The suggested keeper leans hard towards the bigger file, since it holds the most detail:
// - Duplicates look the same, so the largest copy is kept (most pixels, then biggest file);
//   how good it looks only breaks a tie.
// - Similar shots are ranked within their group by how good they look and by file size, and
//   size counts `sizeWeight` times as much. A smaller shot is only kept when it looks clearly
//   better and the bigger ones aren't much bigger.
// - Faces count too, for similar shots: the take where faces look best ranks up as much as the
//   best-looking one, and a take with someone's eyes closed is never suggested while another take
//   of the moment has them open.
// You can always pick a different photo to keep before merging.

import WinnowCore

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
    /// How much more file size counts than looks when suggesting which similar shot to keep.
    public static let sizeWeight = 2.0
    /// More than looks, faces and size together (at most 1 + 1 + sizeWeight) can make up for.
    public static let eyesClosedPenalty = 5.0

    public static func build(groups: [SimilarGroup], score: (String) -> Double,
                             files: [String: FileInfo], faces: [String: FaceInfo] = [:]) -> [LookAlikeGroup] {
        groups.compactMap { group in
            guard group.members.count > 1 else { return nil }
            let keeper = suggestedKeeper(group.members, kind: group.kind, score: score, files: files, faces: faces)
            let rest = group.members.filter { $0 != keeper }.sorted { score($0) > score($1) }
            return LookAlikeGroup(kind: group.kind, members: [keeper] + rest, keeper: keeper)
        }
    }

    public static func suggestedKeeper(_ members: [String], kind: SimilarGroup.Kind, score: (String) -> Double,
                                       files: [String: FileInfo], faces: [String: FaceInfo] = [:]) -> String {
        func size(_ id: String) -> (Int, Int) { (files[id]?.pixels ?? 0, files[id]?.bytes ?? 0) }
        if kind == .duplicate {
            return members.max { (size($0).0, size($0).1, score($0)) < (size($1).0, size($1).1, score($1)) } ?? members[0]
        }
        // 0 for the worst in the group, 1 for the best; ties share a rank.
        let n = Double(max(members.count - 1, 1))
        func sizeRank(_ id: String) -> Double { Double(members.filter { size($0) < size(id) }.count) / n }
        func lookRank(_ id: String) -> Double { Double(members.filter { score($0) < score(id) }.count) / n }
        func faceQuality(_ id: String) -> Double { faces[id]?.quality ?? -1 }
        func faceRank(_ id: String) -> Double { Double(members.filter { faceQuality($0) < faceQuality(id) }.count) / n }
        let blinked = Set(blinks(in: members, faces: faces))
        func value(_ id: String) -> Double {
            lookRank(id) + faceRank(id) + sizeWeight * sizeRank(id) - (blinked.contains(id) ? eyesClosedPenalty : 0)
        }
        return members.max { (value($0), score($0)) < (value($1), score($1)) } ?? members[0]
    }

    /// Members with someone's eyes closed, when another member of the group has them open.
    public static func blinks(in members: [String], faces: [String: FaceInfo]) -> [String] {
        guard members.contains(where: { faces[$0]?.eyesClosed == false }) else { return [] }
        return members.filter { faces[$0]?.eyesClosed == true }
    }
}
