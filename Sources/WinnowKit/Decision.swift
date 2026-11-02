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
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case assetID, cloudID, rating, flag, hidden, seenAt, updatedAt
        case favorite = "originalFavorite" // column named in v1, when picks existed
    }

    public init(assetID: String, cloudID: String? = nil, rating: Int = 0, flag: Flag = .none,
                hidden: Bool = false, favorite: Bool? = nil, seenAt: Date? = nil,
                updatedAt: Date = Date()) {
        self.assetID = assetID
        self.cloudID = cloudID
        self.rating = rating
        self.flag = flag
        self.hidden = hidden
        self.favorite = favorite
        self.seenAt = seenAt
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

    public var isEmpty: Bool { favorite == nil && hidden == nil && inRejectAlbum == nil && rating == nil }

    public init(favorite: Bool? = nil, hidden: Bool? = nil, inRejectAlbum: Bool? = nil, rating: Int? = nil) {
        self.favorite = favorite
        self.hidden = hidden
        self.inRejectAlbum = inRejectAlbum
        self.rating = rating
    }

    public init(from before: Decision, to after: Decision) {
        favorite = before.favorite != after.favorite ? after.favorite : nil
        hidden = before.hidden != after.hidden ? after.hidden : nil
        inRejectAlbum = (before.flag == .reject) != (after.flag == .reject) ? after.flag == .reject : nil
        rating = before.rating != after.rating ? after.rating : nil
    }
}
