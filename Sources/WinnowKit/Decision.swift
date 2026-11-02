// What the user decided about one photo, and how that maps onto Apple Photos.

import Foundation
import GRDB

public enum Flag: String, Codable, Sendable, DatabaseValueConvertible {
    case none, pick, reject
}

/// A key press that changes a decision.
public enum Action: Equatable, Sendable {
    case rate(Int) // 0 clears, 1–5 stars
    case pick
    case reject
    case clearFlag
    case toggleHidden
}

public struct Decision: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "decision"

    /// PHAsset.localIdentifier. Stable on this Mac for this library.
    public var assetID: String
    /// PHCloudIdentifier string, so decisions can be re-matched after a library migration.
    public var cloudID: String?
    public var rating: Int
    public var flag: Flag
    /// True when Winnow hid the photo in Photos.
    public var hidden: Bool
    /// Photos' Favorite state before Winnow first changed it, so clearing a pick puts it back.
    public var originalFavorite: Bool?
    /// When the user first looked at this photo in single or compare view.
    public var seenAt: Date?
    public var updatedAt: Date

    public init(assetID: String, cloudID: String? = nil, rating: Int = 0, flag: Flag = .none,
                hidden: Bool = false, originalFavorite: Bool? = nil, seenAt: Date? = nil,
                updatedAt: Date = Date()) {
        self.assetID = assetID
        self.cloudID = cloudID
        self.rating = rating
        self.flag = flag
        self.hidden = hidden
        self.originalFavorite = originalFavorite
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
        case .pick:
            d.originalFavorite = d.originalFavorite ?? currentFavorite
            d.flag = .pick
        case .reject:
            d.originalFavorite = d.originalFavorite ?? currentFavorite
            d.flag = .reject
        case .clearFlag:
            d.flag = .none
        case .toggleHidden:
            d.hidden.toggle()
        }
        d.updatedAt = date
        return d
    }

    /// The Favorite state Photos should show for this decision.
    public func favorite(currentFavorite: Bool) -> Bool {
        flag == .pick ? true : (originalFavorite ?? currentFavorite)
    }
}

/// What has to change in Photos to go from one decision to another.
public struct PhotosChange: Equatable, Sendable {
    public var favorite: Bool?        // nil = leave alone
    public var hidden: Bool?
    public var inRejectAlbum: Bool?

    public var isEmpty: Bool { favorite == nil && hidden == nil && inRejectAlbum == nil }

    public init(from before: Decision, to after: Decision, currentFavorite: Bool) {
        let target = after.favorite(currentFavorite: currentFavorite)
        favorite = target != currentFavorite ? target : nil
        hidden = before.hidden != after.hidden ? after.hidden : nil
        inRejectAlbum = (before.flag == .reject) != (after.flag == .reject) ? after.flag == .reject : nil
    }
}
