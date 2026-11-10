import AppKit
import CoreLocation
import Photos
import ImageIO
import DateGuessCore
import KeeperCore

struct AlbumInfo: Identifiable, Hashable {
    var id: String
    var title: String
    var count: Int
}

/// Wraps a PHAsset so it can cross concurrency boundaries (PhotoKit objects are thread-safe to read).
struct AssetRef: @unchecked Sendable {
    let asset: PHAsset
}

/// All read access to the Photos library goes through here.
final class PhotoLibraryService: @unchecked Sendable {
    static let shared = PhotoLibraryService()

    let imageManager = PHCachingImageManager()
    private let assetCache = NSCache<NSString, PHAsset>()

    init() {
        assetCache.countLimit = 5000
        imageManager.allowsCachingHighQualityImages = false
    }

    // MARK: Authorization

    var authorizationStatus: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// What PhotoKit reports, saved when a scan comes back empty so access problems can be told apart.
    func accessDiagnostics() -> [String: String] {
        let status: String
        switch authorizationStatus {
        case .authorized: status = "authorized"
        case .limited: status = "limited"
        case .denied: status = "denied"
        case .restricted: status = "restricted"
        case .notDetermined: status = "notDetermined"
        @unknown default: status = "unknown"
        }
        let any = PHAsset.fetchAssets(with: nil).count
        let images = PHAsset.fetchAssets(with: .image, options: nil).count
        return ["status": status, "allAssets": String(any), "images": String(images),
                "userLibraryImages": String(fetchAllPhotos().count),
                "albums": String(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).count),
                "date": Date().formatted(), "bundle": Bundle.main.bundlePath]
    }

    // MARK: Fetching

    /// Every photo in the user's own library (not shared albums), oldest first.
    func fetchAllPhotos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    /// Drops a cached asset after it was edited here, so the next fetch sees the edit.
    func forget(_ id: String) { assetCache.removeObject(forKey: id as NSString) }

    func asset(for id: String) -> PHAsset? {
        if let cached = assetCache.object(forKey: id as NSString) { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        assetCache.setObject(asset, forKey: id as NSString)
        return asset
    }

    func assets(for ids: [String]) -> [String: PHAsset] {
        var out: [String: PHAsset] = [:]
        for chunk in ids.chunked(into: 500) {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
            result.enumerateObjects { asset, _, _ in out[asset.localIdentifier] = asset }
        }
        return out
    }

    private func userAlbumCollections() -> [PHAssetCollection] {
        var out: [PHAssetCollection] = []
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        result.enumerateObjects { collection, _, _ in
            // Shared iCloud albums can't be edited and aren't part of the user's library.
            if collection.assetCollectionSubtype != .albumCloudShared { out.append(collection) }
        }
        return out
    }

    func userAlbums() -> [AlbumInfo] {
        albumMembership().map { AlbumInfo(id: $0.id, title: $0.title, count: $0.ids.count) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Every album of your own and the photos in it, read once and kept for a minute: the
    /// album screens, the scan and the settings each asked PhotoKit for every album's photos.
    private let membershipLock = NSLock()
    private var membershipCache: (read: Date, albums: [(id: String, title: String, ids: Set<String>)])?

    func albumMembership() -> [(id: String, title: String, ids: Set<String>)] {
        membershipLock.lock()
        defer { membershipLock.unlock() }
        if let cache = membershipCache, Date().timeIntervalSince(cache.read) < 60 { return cache.albums }
        let albums = userAlbumCollections().map { c in
            var ids = Set<String>()
            PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
            return (id: c.localIdentifier, title: c.localizedTitle ?? "Untitled album", ids: ids)
        }
        membershipCache = (Date(), albums)
        return albums
    }

    /// Forgets the album membership read, after an album changes here.
    func forgetAlbums() {
        membershipLock.lock()
        membershipCache = nil
        membershipLock.unlock()
    }

    /// Every album of your own: its photos, and the ones with a date and a location.
    /// - Parameter all: every located photo (the Places scan). Reading `asset.location` here instead
    ///   made PhotoKit fetch each one on the main thread, which froze the app for a big library.
    func userAlbumDetails(located all: LocatedPhotos) -> [(id: String, title: String, ids: Set<String>, located: [AlbumSuggestions.Photo])] {
        var index: [String: Int] = [:]
        index.reserveCapacity(all.count)
        for (i, id) in all.ids.enumerated() { index[id] = i }
        return albumMembership().map { album in
            let located = album.ids.compactMap { id in index[id].map { AlbumSuggestions.Photo(id: id, time: all.times[$0], point: all.point($0)) } }
                .sorted { $0.time < $1.time }
            return (album.id, album.title, album.ids, located)
        }
    }

    /// Every album of your own with the photos in it.
    func userAlbumMembers() -> [(title: String, ids: Set<String>)] {
        albumMembership().map { ($0.title, $0.ids) }
    }

    /// Asset IDs in the given albums.
    func assetIDs(inAlbums albumIDs: [String]) -> Set<String> {
        guard !albumIDs.isEmpty else { return [] }
        let wanted = Set(albumIDs)
        var ids = Set<String>()
        for album in albumMembership() where wanted.contains(album.id) { ids.formUnion(album.ids) }
        return ids
    }

    /// Album titles for each of the given assets.
    func albumTitles(for ids: Set<String>) -> [String: [String]] {
        var out: [String: [String]] = [:]
        guard !ids.isEmpty else { return out }
        for album in albumMembership() {
            for id in album.ids where ids.contains(id) { out[id, default: []].append(album.title) }
        }
        return out
    }

    // MARK: File metadata

    func originalResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .photo }
            ?? resources.first { $0.type == .fullSizePhoto }
            ?? resources.first
    }

    func formatInfo(for asset: PHAsset, embedded: EmbeddedDateInfo?) -> FormatInfo {
        let resource = originalResource(for: asset)
        return FormatInfo(
            originalFilename: resource?.originalFilename,
            uniformTypeIdentifier: resource?.uniformTypeIdentifier,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isPanorama: asset.mediaSubtypes.contains(.photoPanorama),
            isDepthEffect: asset.mediaSubtypes.contains(.photoDepthEffect),
            cameraMake: embedded?.make,
            cameraModel: embedded?.model,
            software: embedded?.software,
            hasGPS: asset.location != nil || (embedded?.hasGPS ?? false))
    }

    enum EmbeddedResult {
        case info(EmbeddedDateInfo)
        /// The original isn't on this Mac (iCloud) and downloads aren't allowed, or it couldn't be read.
        case unavailable
    }

    /// Reads just enough of the original file to see its capture-date metadata, without
    /// loading or changing the photo.
    func readEmbeddedInfo(for asset: PHAsset, allowNetwork: Bool) async -> EmbeddedResult {
        guard let resource = originalResource(for: asset) else { return .unavailable }
        let uti = resource.uniformTypeIdentifier.lowercased()
        // JPEG/HEIC keep metadata near the start of the file; TIFF/RAW may keep it anywhere.
        let headerFormat = uti.contains("jpeg") || uti.contains("heic") || uti.contains("heif")
        let anywhereFormat = uti.contains("tiff") || uti.contains("raw") || uti.contains("dng")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork

        return await withCheckedContinuation { continuation in
            let reader = PartialMetadataReader(byteCap: anywhereFormat ? 64_000_000 : 8_000_000,
                                               conclusiveAfter: headerFormat ? 256 * 1024 : (anywhereFormat ? 64_000_000 : 1_000_000)) { result in
                continuation.resume(returning: result.map(EmbeddedResult.info) ?? .unavailable)
            }
            let requestID = PHAssetResourceManager.default().requestData(
                for: resource, options: options,
                dataReceivedHandler: { chunk in reader.append(chunk) },
                completionHandler: { error in reader.finish(error: error) })
            reader.setRequestID(requestID)
        }
    }

    // MARK: Images

    /// A thumbnail for grids. Calls back possibly twice (fast degraded image, then sharp).
    @discardableResult
    func requestThumbnail(for asset: PHAsset, side: CGFloat, handler: @escaping (NSImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: side * scale, height: side * scale)
        // On screen: background analysis waits until it's loaded (ScreenImages).
        ScreenImages.shared.begin()
        let pending = PendingThumbnail()
        let id = imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
            handler(image)
            if (info?[PHImageResultIsDegradedKey] as? Bool) != true { pending.finish() }
        }
        pending.id = id
        pendingThumbnails.add(pending)
        return id
    }

    func cancel(_ id: PHImageRequestID) {
        imageManager.cancelImageRequest(id)
        pendingThumbnails.finish(id)
    }

    /// A good-quality rendering for analysis (current edited version, oriented correctly).
    /// - Parameter allowNetwork: false uses only what's on this Mac (nil if the photo is only in iCloud).
    func analysisImage(for asset: PHAsset, maxEdge: Int, allowNetwork: Bool = true) async -> CGImage? {
        // Background work: let the photos on screen load first, or they stay blurry behind it.
        await ScreenImages.shared.waitUntilQuiet()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = allowNetwork
        options.isSynchronous = false
        let size = CGSize(width: maxEdge, height: maxEdge)
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard once.claim() else { return }
                var rect = CGRect(origin: .zero, size: image?.size ?? .zero)
                continuation.resume(returning: image?.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            }
        }
    }
}

/// An on-screen thumbnail still loading: ends its ScreenImages count once, when the sharp image
/// arrives or it's cancelled.
final class PendingThumbnail: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var id: PHImageRequestID = PHInvalidImageRequestID

    func finish() {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { ScreenImages.shared.end(); pendingThumbnails.remove(self) }
    }
}

/// Thumbnails still loading, by request, so cancelling one ends its count.
final class PendingThumbnails: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [PHImageRequestID: PendingThumbnail] = [:]

    func add(_ p: PendingThumbnail) { lock.lock(); byID[p.id] = p; lock.unlock() }
    func remove(_ p: PendingThumbnail) { lock.lock(); if byID[p.id] === p { byID[p.id] = nil }; lock.unlock() }
    func finish(_ id: PHImageRequestID) {
        lock.lock(); let p = byID[id]; lock.unlock()
        p?.finish()
    }
}

let pendingThumbnails = PendingThumbnails()

/// Thread-safe "only once" guard for continuations.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Accumulates file bytes until the image header's metadata can be parsed, then stops the download.
final class PartialMetadataReader: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelWhenIDKnown = false
    private var nextParseAt = 64 * 1024
    private let byteCap: Int
    /// After this many bytes, a readable header without EXIF/TIFF means the file has none.
    private let conclusiveAfter: Int
    private let completion: (EmbeddedDateInfo?) -> Void

    init(byteCap: Int, conclusiveAfter: Int, completion: @escaping (EmbeddedDateInfo?) -> Void) {
        self.byteCap = byteCap
        self.conclusiveAfter = conclusiveAfter
        self.completion = completion
    }

    func setRequestID(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        requestID = id
        let cancelNow = cancelWhenIDKnown
        lock.unlock()
        if cancelNow { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func append(_ chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        data.append(chunk)
        let size = data.count
        guard size >= nextParseAt || size >= byteCap else { lock.unlock(); return }
        nextParseAt = size * 2
        let snapshot = data
        lock.unlock()

        if let info = Self.parse(snapshot, final: false, requireDates: size < conclusiveAfter && size < byteCap) {
            deliver(info, cancel: true)
        } else if size >= byteCap {
            // Read plenty and still no capture-date metadata: treat as having none.
            deliver(Self.parse(snapshot, final: false, requireDates: false) ?? EmbeddedDateInfo(), cancel: true)
        }
    }

    func finish(error: Error?) {
        lock.lock()
        let alreadyDone = finished
        let snapshot = data
        lock.unlock()
        guard !alreadyDone else { return }
        if error != nil && snapshot.isEmpty {
            deliver(nil, cancel: false)
            return
        }
        deliver(Self.parse(snapshot, final: error == nil, requireDates: false) ?? (error == nil ? EmbeddedDateInfo() : nil), cancel: false)
    }

    private func deliver(_ info: EmbeddedDateInfo?, cancel: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let id = requestID
        if cancel && id == nil { cancelWhenIDKnown = true }
        lock.unlock()
        if cancel, let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        completion(info)
    }

    /// Parses image properties from (possibly partial) file data.
    /// With `requireDates`, returns nil unless EXIF/TIFF metadata has been seen (so we keep reading).
    static func parse(_ data: Data, final: Bool, requireDates: Bool) -> EmbeddedDateInfo? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, final)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        if requireDates && exif == nil && tiff == nil { return nil }
        return EmbeddedDateInfo(
            dateTimeOriginal: exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            dateTimeDigitized: exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiffDateTime: tiff?[kCGImagePropertyTIFFDateTime] as? String,
            make: tiff?[kCGImagePropertyTIFFMake] as? String,
            model: tiff?[kCGImagePropertyTIFFModel] as? String,
            software: tiff?[kCGImagePropertyTIFFSoftware] as? String,
            hasGPS: !(gps?.isEmpty ?? true))
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
