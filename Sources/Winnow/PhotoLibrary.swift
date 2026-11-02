// Everything that talks to PhotoKit: what to cull, loading images, and writing decisions back.

import AppKit
import Photos
import WinnowKit

/// Where a cull session's photos come from.
enum Source: Hashable, Codable {
    case allPhotos
    case unreviewed
    case favorites
    case screenshots
    case bursts
    case suggestedRejects
    case bestShots
    case calibrate
    case album(id: String, title: String)

    var title: String {
        switch self {
        case .allPhotos: "All Photos"
        case .unreviewed: "Unreviewed"
        case .favorites: "Favorites"
        case .screenshots: "Screenshots"
        case .bursts: "Bursts"
        case .suggestedRejects: "Suggested Rejects"
        case .bestShots: "Best Shots"
        case .calibrate: "Rate to Calibrate"
        case .album(_, let title): title
        }
    }

    var systemImage: String {
        switch self {
        case .allPhotos: "photo.on.rectangle"
        case .unreviewed: "eye.slash"
        case .favorites: "heart"
        case .screenshots: "camera.viewfinder"
        case .bursts: "square.stack.3d.down.right"
        case .suggestedRejects: "wand.and.rays"
        case .bestShots: "star"
        case .calibrate: "slider.horizontal.3"
        case .album: "rectangle.stack"
        }
    }

    /// Sources built from Apple's scores, in their own order instead of by date.
    var isSuggestion: Bool { self == .suggestedRejects || self == .bestShots || self == .calibrate }

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
    static let rejectAlbumTitle = "Winnow – Rejected"

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
            self.reloadAlbums()
            self.onChange?(change)
        }
    }

    // MARK: Fetching

    /// Lazy: PhotoKit loads objects only as they're asked for, so this is fast at any library size.
    nonisolated func fetch(_ source: Source, newestFirst: Bool) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !newestFirst)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        func smartAlbum(_ subtype: PHAssetCollectionSubtype) -> PHFetchResult<PHAsset> {
            guard let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject
            else { return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }
            return PHAsset.fetchAssets(in: album, options: options)
        }

        switch source {
        case .allPhotos, .unreviewed, .suggestedRejects, .bestShots, .calibrate:
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
    func assets(withIDs ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        var out: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options).enumerateObjects { a, _, _ in out.append(a) }
        return out
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

    private func reloadAlbums() {
        var out: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { c, _, _ in
                if c.localizedTitle == Self.rejectAlbumTitle { self.rejectAlbum = c } else { out.append(c) }
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
    nonisolated func images(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFit,
                            highQualityOnly: Bool = false, allowNetwork: Bool = false) -> AsyncStream<LoadedImage> {
        AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = highQualityOnly ? .highQualityFormat : .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = allowNetwork
            let manager = imageManager
            let id = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode,
                                          options: options) { image, info in
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                let inCloud = info?[PHImageResultIsInCloudKey] as? Bool ?? false
                continuation.yield(LoadedImage(image: image, isDegraded: degraded, isInCloud: inCloud))
                if !degraded || image == nil { continuation.finish() }
            }
            continuation.onTermination = { _ in manager.cancelImageRequest(id) }
        }
    }

    func startCaching(_ assets: [PHAsset], targetSize: CGSize) {
        imageManager.startCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFit, options: nil)
    }

    func stopCaching(_ assets: [PHAsset], targetSize: CGSize) {
        imageManager.stopCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFit, options: nil)
    }

    // MARK: Writing

    /// Applies rating, favorite, hidden and reject-album changes in one Photos transaction.
    func apply(_ changes: [(asset: PHAsset, change: PhotosChange)]) async throws {
        let changes = changes.filter { !$0.change.isEmpty }
        guard !changes.isEmpty else { return }
        let album = changes.contains { $0.change.inRejectAlbum != nil } ? try await rejectAlbumCollection() : nil
        try await PHPhotoLibrary.shared().performChanges {
            for (asset, change) in changes {
                if change.favorite != nil || change.hidden != nil || change.rating != nil {
                    let request = PHAssetChangeRequest(for: asset)
                    if let favorite = change.favorite { request.isFavorite = favorite }
                    if let hidden = change.hidden { request.isHidden = hidden }
                    if let rating = change.rating { request.rating = PHAsset.Rating(rawValue: rating) ?? .unset }
                }
                if let inAlbum = change.inRejectAlbum, let album,
                   let request = PHAssetCollectionChangeRequest(for: album) {
                    if inAlbum { request.addAssets([asset] as NSArray) } else { request.removeAssets([asset] as NSArray) }
                }
            }
        }
    }

    /// One call, so macOS shows one confirmation for the whole batch.
    func delete(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
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
