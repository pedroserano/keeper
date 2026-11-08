import Foundation
import DateGuessCore

/// What the place scan found: photos with no location, and the ones with a location to learn from.
struct PlacesScan: Codable {
    var lastScan: Date?
    /// Photos with no location, and the date Photos has for each.
    var missing: [String: Date?] = [:]
    /// Photos with a location, stored as parallel columns to keep the file small.
    var located = LocatedPhotos()
}

struct LocatedPhotos: Codable {
    var ids: [String] = []
    var times: [Date] = []
    var lats: [Double] = []
    var lons: [Double] = []

    var count: Int { ids.count }

    mutating func append(_ id: String, _ time: Date, _ point: GeoPoint) {
        ids.append(id)
        times.append(time)
        lats.append(point.lat)
        lons.append(point.lon)
    }

    func point(_ i: Int) -> GeoPoint { GeoPoint(lat: lats[i], lon: lons[i]) }

    /// Drops these photos (their location was taken back).
    mutating func remove(_ drop: Set<String>) {
        guard ids.contains(where: drop.contains) else { return }
        var kept = LocatedPhotos()
        for i in ids.indices where !drop.contains(ids[i]) { kept.append(ids[i], times[i], point(i)) }
        self = kept
    }
}

/// A named place: one the user picked from Apple Maps, or a dropped pin.
struct PlaceChoice: Codable, Hashable {
    var name: String
    var point: GeoPoint
}

struct PlaceDecision: Codable, Hashable {
    var selected = false
    var override: PlaceChoice?
    var ignored = false
}

struct PlaceJournalEntry: Codable, Hashable {
    var assetID: String
    var previous: GeoPoint?
    var new: GeoPoint
    var name: String?
    /// When the photo was taken, so its outing can still be shown once it has a location.
    var taken: Date?
}

/// One "Apply" of places, kept so it can be undone.
struct PlaceBatch: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var entries: [PlaceJournalEntry]
    var failures: [String: String] = [:]
    var undone = false
}

/// A guess ready for review.
struct PlaceGuessResult: Hashable {
    var estimate: PlaceEstimate
    var evidence: [PlaceEvidence]

    enum Level { case low, medium, high }

    var level: Level {
        estimate.confidence >= 0.75 ? .high : estimate.confidence >= 0.45 ? .medium : .low
    }
}
