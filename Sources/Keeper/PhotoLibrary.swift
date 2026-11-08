// Everything that talks to PhotoKit: what to cull, loading images, and writing decisions back.

import AppKit
import Photos
import KeeperCore
import KeeperKit

/// Where a cull session's photos come from.
enum Source: Hashable, Codable {
    case allPhotos
    case unreviewed
    case rejected
    case favorites
    case dateRange
    case screenshots
    case bursts
    case suggestedRejects
    case bestShots
    case calibrate
    case duplicates
    case similarShots
    case sideways
    case album(id: String, title: String)

    var title: String {
        switch self {
        case .allPhotos: "All Photos"
        case .unreviewed: "Unreviewed"
        case .rejected: "Rejected"
        case .favorites: "Favorites"
        case .dateRange: "Date Range"
        case .screenshots: "Screenshots"
        case .bursts: "Bursts"
        case .suggestedRejects: "Suggested Rejects"
        case .bestShots: "Best Shots"
        case .calibrate: "Rate to Calibrate"
        case .duplicates: "Duplicates"
        case .similarShots: "Similar Shots"
        case .sideways: "Sideways Photos"
        case .album(_, let title): title
        }
    }

    var systemImage: String {
        switch self {
        case .allPhotos: "photo.on.rectangle"
        case .unreviewed: "eye.slash"
        case .rejected: "xmark.bin"
        case .favorites: "heart"
        case .dateRange: "calendar"
        case .screenshots: "camera.viewfinder"
        case .bursts: "square.stack.3d.down.right"
        case .suggestedRejects: "wand.and.rays"
        case .bestShots: "star"
        case .calibrate: "slider.horizontal.3"
        case .duplicates: "plus.square.on.square"
        case .similarShots: "square.on.square"
        case .sideways: "rotate.right"
        case .album: "rectangle.stack"
        }
    }

    /// Sources built from Apple's scores, in their own order instead of by date.
    var isSuggestion: Bool {
        [.suggestedRejects, .bestShots, .calibrate, .duplicates, .similarShots].contains(self)
    }

    /// Lists in date order, which Sort can change (suggestions and Sideways Photos have their own order).
    var sorts: Bool { !isSuggestion && self != .sideways }

    /// Duplicates and similar shots, shown group by group.
    var isGroups: Bool { groupKind != nil }

    var groupKind: SimilarGroup.Kind? {
        switch self {
        case .duplicates: .duplicate
        case .similarShots: .similar
        default: nil
        }
    }

    /// Stable key for remembering a position per source.
    var key: String {
        switch self {
        case .album(let id, _): "album:\(id)"
        default: title
        }
    }
}

struct LoadedImage {
    let image: NSImage?
    let isDegraded: Bool
    let isInCloud: Bool
}

@MainActor
final class PhotoLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    nonisolated static let rejectAlbumTitle = PhotosDatabase.rejectAlbumTitle

    nonisolated let imageManager = PHCachingImageManager()
    @Published private(set) var albums: [PHAssetCollection] = []
    /// Called on the main actor for every library change.
    var onChange: ((PHChange) -> Void)?
    private var rejectAlbum: PHAssetCollection?

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
        reloadAlbums()
    }

    nonisolated func photoLibraryDidChange(_ change: PHChange) {
        Task { @MainActor in
            self.scheduleAlbumReload()
            self.onChange?(change)
        }
    }

    // MARK: Fetching

    /// Lazy: PhotoKit loads objects only as they're asked for, so this is fast at any library size.
    /// `range` is for Date Range: whole days, first to last inclusive.
    nonisolated func fetch(_ source: Source, newestFirst: Bool, range: ClosedRange<Date>? = nil) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !newestFirst)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        if source == .dateRange, let range {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: range.lowerBound)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: range.upperBound))!
            options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate < %@",
                                            PHAssetMediaType.image.rawValue, start as NSDate, end as NSDate)
        }

        func smartAlbum(_ subtype: PHAssetCollectionSubtype) -> PHFetchResult<PHAsset> {
            guard let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject
            else { return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }
            return PHAsset.fetchAssets(in: album, options: options)
        }

        switch source {
        case .allPhotos, .unreviewed, .rejected, .dateRange, .suggestedRejects, .bestShots, .calibrate, .duplicates, .similarShots, .sideways:
            return PHAsset.fetchAssets(with: options)
        case .favorites:
            return smartAlbum(.smartAlbumFavorites)
        case .screenshots:
            return smartAlbum(.smartAlbumScreenshots)
        case .bursts:
            return smartAlbum(.smartAlbumBursts)
        case .album(let id, _):
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
            else { return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }
            return PHAsset.fetchAssets(in: album, options: options)
        }
    }

    /// Assets by ID, including hidden ones and every frame of a burst.
    nonisolated func assets(withIDs ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        var out: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options).enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    /// These photos as a fetch result (for a list), newest first.
    nonisolated func assets(fetching ids: [String]) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
    }

    /// Every frame of a burst, oldest first.
    func burstFrames(_ burstID: String) -> [PHAsset] {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var out: [PHAsset] = []
        PHAsset.fetchAssets(withBurstIdentifier: burstID, options: options).enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    private var albumReload: Task<Void, Never>?

    /// Albums are re-read once changes settle, not after each of a bulk write's many reports.
    private func scheduleAlbumReload() {
        albumReload?.cancel()
        albumReload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { self?.reloadAlbums() }
        }
    }

    private func reloadAlbums() {
        var out: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { c, _, _ in
                if c.localizedTitle == Self.rejectAlbumTitle { self.rejectAlbum = c }
                else if c.localizedTitle == PhotosDatabase.legacyRejectAlbumTitle { self.renameLegacyRejectAlbum(c) }
                else { out.append(c) }
            }
        albums = out.sorted { ($0.localizedTitle ?? "").localizedStandardCompare($1.localizedTitle ?? "") == .orderedAscending }
    }

    /// UUIDs (the part of a local identifier that matches Photos.sqlite) of every photo in a source.
    nonisolated func uuids(in source: Source) -> Set<String> {
        var out = Set<String>()
        fetch(source, newestFirst: false).enumerateObjects { a, _, _ in
            out.insert(String(a.localIdentifier.split(separator: "/").first ?? ""))
        }
        return out
    }

    /// Every star rating you've given in Photos (macOS 27), by UUID. Reads each photo once,
    /// so it runs in the background.
    nonisolated func photoRatings() -> [String: Int] {
        var out: [String: Int] = [:]
        fetch(.allPhotos, newestFirst: false).enumerateObjects { a, _, _ in
            let r = a.rating.rawValue
            if r > 0 { out[String(a.localIdentifier.split(separator: "/").first ?? "")] = r }
        }
        return out
    }

    func cloudIDs(for ids: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for (id, result) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: ids) {
            if case .success(let cloud) = result { out[id] = cloud.archivalStringValue }
        }
        return out
    }

    // MARK: Images

    /// Delivers a fast low-quality image first (unless `highQualityOnly`), then the final one.
    /// `background`: for a scan, which waits while photos on screen are loading (ScreenImages).
    nonisolated func images(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFit,
                            highQualityOnly: Bool = false, allowNetwork: Bool = false,
                            background: Bool = false) -> AsyncStream<LoadedImage> {
        AsyncStream { continuation in
            if !background { ScreenImages.shared.begin() }
            var ended = background
            let end = { if !ended { ended = true; ScreenImages.shared.end() } }
            let options = PHImageRequestOptions()
            options.deliveryMode = highQualityOnly ? .highQualityFormat : .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = allowNetwork
            let manager = imageManager
            let id = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode,
                                          options: options) { image, info in
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                let inCloud = info?[PHImageResultIsInCloudKey] as? Bool ?? false
                if !degraded, image == nil, let error = info?[PHImageErrorKey] as? Error {
                    log.notice("images: full-size image failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.yield(LoadedImage(image: image, isDegraded: degraded, isInCloud: inCloud))
                if !degraded || image == nil { continuation.finish() }
            }
            continuation.onTermination = { _ in
                manager.cancelImageRequest(id)
                end()
            }
        }
    }

    private var cached: (assets: [PHAsset], size: CGSize) = ([], .zero)

    /// Keeps just these photos rendered ahead at this size, and stops the ones you've moved past.
    /// Left running, every step would queue more full-size renders (slow for RAW files) ahead of
    /// the photo on screen, which then stayed on its blurry preview.
    func cacheWindow(_ assets: [PHAsset], targetSize: CGSize) {
        let ids = Set(assets.map(\.localIdentifier))
        let stale = cached.size == targetSize ? cached.assets.filter { !ids.contains($0.localIdentifier) } : cached.assets
        if !stale.isEmpty {
            imageManager.stopCachingImages(for: stale, targetSize: cached.size, contentMode: .aspectFit, options: nil)
        }
        let had = cached.size == targetSize ? Set(cached.assets.map(\.localIdentifier)) : []
        let new = assets.filter { !had.contains($0.localIdentifier) }
        if !new.isEmpty {
            imageManager.startCachingImages(for: new, targetSize: targetSize, contentMode: .aspectFit, options: nil)
        }
        cached = (assets, targetSize)
    }

    func stopCachingAll() {
        imageManager.stopCachingImagesForAllAssets()
        cached = ([], .zero)
    }

    // MARK: Writing

    /// Applies rating, favorite, hidden and reject-album changes in one Photos transaction.
    /// Photos changes per transaction: a merge or a bulk rating of thousands is split up.
    nonisolated static let batchSize = 500

    func apply(_ changes: [(asset: PHAsset, change: PhotosChange)],
               progress: ((Int, Int) -> Void)? = nil) async throws {
        let changes = changes.filter { !$0.change.isEmpty }
        guard !changes.isEmpty else { return }
        let rejectAlbum = changes.contains { $0.change.inRejectAlbum != nil } ? try await rejectAlbumCollection() : nil
        let albumIDs = Set(changes.flatMap { $0.change.addAlbums + $0.change.removeAlbums })
        var albums: [String: PHAssetCollection] = [:]
        if !albumIDs.isEmpty {
            PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(albumIDs), options: nil)
                .enumerateObjects { c, _, _ in albums[c.localIdentifier] = c }
        }
        // A merge of thousands of groups is split up so no single Photos transaction gets huge.
        for start in stride(from: 0, to: changes.count, by: Self.batchSize) {
            let chunk = changes[start..<min(start + Self.batchSize, changes.count)]
            try await PHPhotoLibrary.shared().performChanges {
                for (asset, change) in chunk {
                    if change.favorite != nil || change.hidden != nil || change.rating != nil {
                        let request = PHAssetChangeRequest(for: asset)
                        if let favorite = change.favorite { request.isFavorite = favorite }
                        if let hidden = change.hidden { request.isHidden = hidden }
                        if let rating = change.rating { request.rating = PHAsset.Rating(rawValue: rating) ?? .unset }
                    }
                    if let inAlbum = change.inRejectAlbum, let rejectAlbum,
                       let request = PHAssetCollectionChangeRequest(for: rejectAlbum) {
                        if inAlbum { request.addAssets([asset] as NSArray) } else { request.removeAssets([asset] as NSArray) }
                    }
                    for id in change.addAlbums {
                        if let album = albums[id] { PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray) }
                    }
                    for id in change.removeAlbums {
                        if let album = albums[id] { PHAssetCollectionChangeRequest(for: album)?.removeAssets([asset] as NSArray) }
                    }
                }
            }
            progress?(min(start + Self.batchSize, changes.count), changes.count)
        }
    }

    /// Regular albums a photo is in that Keeper may add photos to (not Keeper's own reject
    /// album, not shared or smart albums).
    nonisolated func albumIDs(containing asset: PHAsset) -> Set<String> {
        var out = Set<String>()
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).enumerateObjects { c, _, _ in
            if c.assetCollectionSubtype == .albumRegular, c.localizedTitle != Self.rejectAlbumTitle,
               c.canPerform(.addContent) {
                out.insert(c.localIdentifier)
            }
        }
        return out
    }

    /// One call, so macOS shows one confirmation for the whole batch.
    func delete(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    /// The app used to be called Winnow: its "Winnow – Rejected" album becomes "Keeper – Rejected",
    /// keeping every photo in it.
    private func renameLegacyRejectAlbum(_ album: PHAssetCollection) {
        if rejectAlbum == nil { rejectAlbum = album }
        Task {
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: album)?.title = Self.rejectAlbumTitle
            }
        }
    }

    private func rejectAlbumCollection() async throws -> PHAssetCollection {
        if let rejectAlbum { return rejectAlbum }
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            placeholderID = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: Self.rejectAlbumTitle)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let placeholderID,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholderID], options: nil).firstObject
        else { throw CocoaError(.fileNoSuchFile) }
        rejectAlbum = album
        return album
    }
}
