// What the user decided about one photo, and how that maps onto Apple Photos.

import Foundation
import GRDB

public enum Flag: String, Codable, Sendable, DatabaseValueConvertible {
    case none, reject
}

/// A key press that changes a decision.
public enum Action: Equatable, Sendable {
    case rate(Int) // 0 clears, 1–5 stars
    case reject
    case clearFlag
    case toggleHidden
    case toggleFavorite
}

public struct Decision: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "decision"

    /// PHAsset.localIdentifier. Stable on this Mac for this library.
    public var assetID: String
    /// PHCloudIdentifier string, so decisions can be re-matched after a library migration.
    public var cloudID: String?
    /// 0–5. Photos' own rating (macOS 27). Photos is the source of truth: the session fills this
    /// in from Photos, and a change here is written there.
    public var rating: Int
    public var flag: Flag
    /// True when Winnow hid the photo in Photos.
    public var hidden: Bool
    /// Favorite in Photos. Like `rating`, the session fills it in from Photos; a change is written there.
    public var favorite: Bool?
    /// When the user first looked at this photo in single or compare view.
    public var seenAt: Date?
    /// Albums Winnow added this photo to when merging look-alikes into it (album local
    /// identifiers), so undo removes exactly those and no others.
    public var addedAlbums: Set<String>?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case assetID, cloudID, rating, flag, hidden, seenAt, addedAlbums, updatedAt
        case favorite = "originalFavorite" // column named in v1, when picks existed
    }

    public init(assetID: String, cloudID: String? = nil, rating: Int = 0, flag: Flag = .none,
                hidden: Bool = false, favorite: Bool? = nil, seenAt: Date? = nil,
                addedAlbums: Set<String>? = nil, updatedAt: Date = Date()) {
        self.assetID = assetID
        self.cloudID = cloudID
        self.rating = rating
        self.flag = flag
        self.hidden = hidden
        self.favorite = favorite
        self.seenAt = seenAt
        self.addedAlbums = addedAlbums
        self.updatedAt = updatedAt
    }

    /// The decision an asset has before Winnow has touched it.
    public static func untouched(_ assetID: String) -> Decision {
        Decision(assetID: assetID, updatedAt: .distantPast)
    }

    /// Applies a key press. `currentFavorite` is the asset's Favorite state in Photos right now.
    public func applying(_ action: Action, currentFavorite: Bool, at date: Date = Date()) -> Decision {
        var d = self
        switch action {
        case .rate(let stars):
            d.rating = min(max(stars, 0), 5)
        case .reject:
            d.flag = .reject
        case .clearFlag:
            d.flag = .none
        case .toggleHidden:
            d.hidden.toggle()
        case .toggleFavorite:
            d.favorite = !(d.favorite ?? currentFavorite)
        }
        d.updatedAt = date
        return d
    }
}

/// What has to change in Photos to go from one decision to another.
public struct PhotosChange: Equatable, Sendable {
    public var favorite: Bool?        // nil = leave alone
    public var hidden: Bool?
    public var inRejectAlbum: Bool?
    public var rating: Int?           // 0 = unset, 1–5
    /// Album local identifiers to add the photo to, or take it out of.
    public var addAlbums: [String] = []
    public var removeAlbums: [String] = []

    public var isEmpty: Bool {
        favorite == nil && hidden == nil && inRejectAlbum == nil && rating == nil && addAlbums.isEmpty && removeAlbums.isEmpty
    }

    public init(favorite: Bool? = nil, hidden: Bool? = nil, inRejectAlbum: Bool? = nil, rating: Int? = nil,
                addAlbums: [String] = [], removeAlbums: [String] = []) {
        self.favorite = favorite
        self.hidden = hidden
        self.inRejectAlbum = inRejectAlbum
        self.rating = rating
        self.addAlbums = addAlbums
        self.removeAlbums = removeAlbums
    }

    public init(from before: Decision, to after: Decision) {
        favorite = before.favorite != after.favorite ? after.favorite : nil
        hidden = before.hidden != after.hidden ? after.hidden : nil
        inRejectAlbum = (before.flag == .reject) != (after.flag == .reject) ? after.flag == .reject : nil
        rating = before.rating != after.rating ? after.rating : nil
        let was = before.addedAlbums ?? [], now = after.addedAlbums ?? []
        addAlbums = now.subtracting(was).sorted()
        removeAlbums = was.subtracting(now).sorted()
    }
}

/// Merging a look-alike group into the photo to keep, the way Photos merges duplicates: the kept
/// photo gets the group's highest rating, Favorite if any of them was one, and every album the
/// others are in; the others are rejected (deleted only from Delete Rejected, after confirmation).
public enum Merge {
    /// `albumsToAdd`: albums the others are in that the kept photo isn't.
    public static func merged(keeper: Decision, others: [Decision], albumsToAdd: Set<String>,
                              at date: Date = Date()) -> [Decision] {
        var k = keeper
        k.rating = max(k.rating, others.map(\.rating).max() ?? 0)
        k.favorite = (k.favorite ?? false) || others.contains { $0.favorite == true }
        k.addedAlbums = (k.addedAlbums ?? []).union(albumsToAdd)
        k.flag = .none
        k.updatedAt = date
        return [k] + others.map { d in
            var d = d
            d.flag = .reject
            d.updatedAt = date
            return d
        }
    }
}
