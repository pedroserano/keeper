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
                if let location = asset.location, CLLocationCoordinate2DIsValid(location.coordinate),
                   location.coordinate.latitude != 0 || location.coordinate.longitude != 0 {
                    if let date = asset.creationDate {
                        scan.located.append(asset.localIdentifier, date,
                                            GeoPoint(lat: location.coordinate.latitude, lon: location.coordinate.longitude))
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
                let current = asset.location.map { GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
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
