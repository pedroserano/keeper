import CoreLocation
import DateGuessCore
import Foundation
import Photos

/// Finds which photos have a location: one quick pass over the library.
enum LocationScanner {
    @concurrent
    static func run(progress: @escaping @Sendable (Int, Int) async -> Void) async -> PlacesScan {
        var scan = PlacesScan(lastScan: Date())
        let all = PhotoLibraryService.shared.fetchAllPhotos()
        let total = all.count
        var index = 0
        while index < total {
            if Task.isCancelled { break }
            let end = min(index + 2000, total)
            for asset in all.objects(at: IndexSet(integersIn: index..<end)) {
                if asset.mediaSubtypes.contains(.photoScreenshot) { continue }
                if let point = realPoint(asset.location) {
                    if let date = asset.creationDate {
                        scan.located.append(asset.localIdentifier, date, point)
                    }
                } else {
                    scan.missing[asset.localIdentifier] = .some(asset.creationDate)
                }
            }
            index = end
            await progress(index, total)
        }
        return scan
    }

    /// A photo's location, or nil when it has none. Photos can store an empty or invalid one
    /// (0,0 or out of range), which counts as no location both here and when setting one.
    static func realPoint(_ location: CLLocation?) -> GeoPoint? {
        guard let c = location?.coordinate, CLLocationCoordinate2DIsValid(c), c.latitude != 0 || c.longitude != 0 else { return nil }
        return GeoPoint(lat: c.latitude, lon: c.longitude)
    }
}

/// Sets photo locations using PhotoKit's official API, the same as Image ▸ Location in Photos.
/// Only the location changes; the file isn't rewritten and everything else stays as it was.
enum PlaceWriter {
    struct Change: Sendable {
        var assetID: String
        var point: GeoPoint?
        var name: String?
        /// Only write if the photo still has no location (someone may have set one in Photos since).
        var requireNoLocation = true
    }

    static let changedElsewhere = "It got a location in Photos after the last scan, so it was left alone."

    static func apply(_ changes: [Change], progress: @escaping @Sendable (Int, Int) async -> Void) async -> PlaceBatch {
        var batch = PlaceBatch(date: Date(), entries: [])
        let library = PhotoLibraryService.shared
        var done = 0
        for chunk in changes.chunked(into: DateWriter.chunkSize) {
            if Task.isCancelled { break }
            let assets = library.assets(for: chunk.map(\.assetID))
            var pending: [(AssetRef, Change, GeoPoint?)] = []
            for change in chunk {
                guard let asset = assets[change.assetID] else {
                    batch.failures[change.assetID] = "Photo no longer in the library"
                    continue
                }
                let current = LocationScanner.realPoint(asset.location)
                if change.requireNoLocation, current != nil {
                    batch.failures[change.assetID] = changedElsewhere
                    continue
                }
                guard asset.canPerform(.properties) else {
                    batch.failures[change.assetID] = "Photos doesn’t allow changing this item’s location (e.g. shared album)"
                    continue
                }
                pending.append((AssetRef(asset: asset), change, current))
            }
            if !pending.isEmpty {
                let requests = pending.map { ($0.0, $0.1.point) }
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        for (ref, point) in requests {
                            let request = PHAssetChangeRequest(for: ref.asset)
                            request.location = point.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
                        }
                    }
                    for (_, change, previous) in pending {
                        if let new = change.point {
                            batch.entries.append(PlaceJournalEntry(assetID: change.assetID, previous: previous, new: new, name: change.name))
                        }
                    }
                } catch {
                    for (_, change, _) in pending { batch.failures[change.assetID] = error.localizedDescription }
                }
            }
            for (_, change, _) in pending { library.forget(change.assetID) }
            done += chunk.count
            await progress(done, changes.count)
        }
        return batch
    }

    /// Puts the previous locations back (no location, for photos placed here).
    static func undo(_ batch: PlaceBatch, progress: @escaping @Sendable (Int, Int) async -> Void) async -> PlaceBatch {
        let changes = batch.entries.map { Change(assetID: $0.assetID, point: $0.previous, requireNoLocation: false) }
        return await apply(changes, progress: progress)
    }
}
