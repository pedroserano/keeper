import AppKit
import Photos
import SwiftUI
import Vision
import WinnowCore

struct ScoredPhoto: Identifiable {
    let id: String // PHAsset.localIdentifier
    let thumbnail: NSImage?
    let vision: Float?
    let isUtility: Bool?
    let photosScore: Double? // Apple Photos' own overall aesthetic score, from Photos.sqlite
    let loadMs: Double
    let scoreMs: Double
    var rejected = false

    var uuid: String { uuidPart(of: id) }
}

/// The part of a PhotoKit local identifier that matches ZASSET.ZUUID in Photos.sqlite.
func uuidPart(of localIdentifier: String) -> String {
    String(localIdentifier.split(separator: "/").first ?? "")
}

/// Everything read from a library's database, loaded off the main thread.
struct LoadedLibrary: Sendable {
    let database: PhotosDatabase
    let photoCount: Int
    let columns: [ColumnStats]
    let uuids: Set<String>
    let photosScores: [String: Double]
}

@MainActor
final class SpikeModel: ObservableObject {
    enum State {
        case choosing
        case opening(URL)
        case failed(URL, message: String, needsFullDiskAccess: Bool)
        case ready
    }

    @Published var state: State = .choosing
    @Published private(set) var library: LoadedLibrary?
    /// nil = not checked yet, or Photos access was refused.
    @Published private(set) var isSystemLibrary: Bool?
    @Published private(set) var photosAccessDenied = false

    @Published var status = "Press Run to score your most recent photos."
    @Published var comparison: String?
    @Published var photos: [ScoredPhoto] = []
    @Published var running = false
    @Published var sampleSize = 200
    /// Off every launch. Only offered when the chosen library is the System Photo Library.
    @Published var deleteEnabled = false

    var rejectedCount: Int { photos.filter(\.rejected).count }

    var lastLibraryPath: String? {
        get { UserDefaults.standard.string(forKey: "lastLibraryPath") }
        set { UserDefaults.standard.set(newValue, forKey: "lastLibraryPath") }
    }

    // MARK: Library

    func chooseAnotherLibrary() {
        guard !running else { return }
        library = nil
        isSystemLibrary = nil
        photos = []
        comparison = nil
        deleteEnabled = false
        state = .choosing
    }

    func open(_ url: URL) async {
        state = .opening(url)
        do {
            let loaded = try await Task.detached {
                let db = try PhotosDatabase(library: url)
                return LoadedLibrary(database: db,
                                     photoCount: try db.photoCount(),
                                     columns: try db.columnStats(),
                                     uuids: try db.photoUUIDs(),
                                     photosScores: try db.scores())
            }.value
            lastLibraryPath = url.path
            library = loaded
            photos = []
            comparison = nil
            status = "Press Run to score your most recent photos."
            state = .ready
            await checkSystemLibrary()
        } catch let error as PhotosDatabaseError {
            state = .failed(url, message: error.message, needsFullDiskAccess: error.kind == .noAccess)
        } catch {
            state = .failed(url, message: error.localizedDescription, needsFullDiskAccess: false)
        }
    }

    /// PhotoKit only sees the System Photo Library, and there's no public API that says which
    /// library that is. So compare the photos PhotoKit returns with the ones in the chosen database.
    func checkSystemLibrary() async {
        guard let library else { return }
        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized || access == .limited else {
            photosAccessDenied = true
            isSystemLibrary = nil
            return
        }
        photosAccessDenied = false

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 100
        var ids: [String] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        if ids.isEmpty {
            isSystemLibrary = library.uuids.isEmpty
        } else {
            let matches = ids.filter { library.uuids.contains(uuidPart(of: $0)) }.count
            isSystemLibrary = Double(matches) / Double(ids.count) >= 0.9
        }
        if isSystemLibrary != true { deleteEnabled = false }
    }

    func openInPhotos() {
        guard let url = library?.database.libraryURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func openPhotosPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
    }

    // MARK: Scoring

    func run() async {
        guard let library, isSystemLibrary == true else { return }
        running = true
        defer { running = false }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = sampleSize
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in assets.append(asset) }

        photos = []
        comparison = nil
        let request = CalculateImageAestheticsScoresRequest()
        let started = CFAbsoluteTimeGetCurrent()

        for (index, asset) in assets.enumerated() {
            status = "Scoring \(index + 1) of \(assets.count)…"
            let t0 = CFAbsoluteTimeGetCurrent()
            let image = await Self.image(for: asset, side: 1024)
            let t1 = CFAbsoluteTimeGetCurrent()

            var vision: Float?
            var isUtility: Bool?
            if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let observation = try? await request.perform(on: cgImage) {
                vision = observation.overallScore
                isUtility = observation.isUtility
            }
            let t2 = CFAbsoluteTimeGetCurrent()

            // Keep only a small thumbnail in memory; the 1024 px image is released here.
            let thumbnail = await Self.image(for: asset, side: 256)
            photos.append(ScoredPhoto(id: asset.localIdentifier, thumbnail: thumbnail,
                                      vision: vision, isUtility: isUtility,
                                      photosScore: library.photosScores[uuidPart(of: asset.localIdentifier)],
                                      loadMs: (t1 - t0) * 1000, scoreMs: (t2 - t1) * 1000))
        }

        // Lowest Vision score first: the likely rejects.
        photos.sort { ($0.vision ?? .infinity) < ($1.vision ?? .infinity) }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let scored = photos.filter { $0.vision != nil }.count
        status = String(format: "%d scored in %.1f s (%.1f per second) · median load %.0f ms · median score %.0f ms",
                        scored, elapsed, Double(photos.count) / max(elapsed, 0.001),
                        Self.median(photos.map(\.loadMs)), Self.median(photos.map(\.scoreMs)))
        if photos.count > scored { status += " · \(photos.count - scored) not on this Mac (iCloud only), skipped" }

        let pairs: [(Double, Double)] = photos.compactMap { p in
            guard let a = p.photosScore, let b = p.vision else { return nil }
            return (a, Double(b))
        }
        if pairs.count >= 10 {
            let overlap = bottomFifthOverlap(pairs)
            comparison = String(format: "Vision vs Photos' own score, %d photos: rank correlation %.2f · ", pairs.count, spearman(pairs))
                + "of Photos' bottom 20%, Vision also puts \(overlap.hits) of \(overlap.of) in its bottom 20%"
        } else {
            comparison = "Not enough photos with both scores to compare (\(pairs.count)). Photos may not have analysed this library yet."
        }

        saveResults()
    }

    func deleteRejected() async {
        let ids = photos.filter(\.rejected).map(\.id)
        guard deleteEnabled, isSystemLibrary == true, !ids.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        do {
            // One change block = one macOS confirmation for the whole batch.
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            photos.removeAll(where: \.rejected)
            status = "Deleted \(ids.count) photos. They're in Recently Deleted for 30 days."
        } catch {
            status = "Delete cancelled or failed: \(error.localizedDescription)"
        }
    }

    /// Keeps a record of each run in ~/Documents/Winnow/out for the Phase 0 gate review.
    private func saveResults() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Winnow/out")
        var csv = "uuid,vision,isUtility,photosOverall,loadMs,scoreMs\n"
        for p in photos {
            csv += [p.uuid,
                    p.vision.map { String($0) } ?? "",
                    p.isUtility.map { String($0) } ?? "",
                    p.photosScore.map { String($0) } ?? "",
                    String(format: "%.1f", p.loadMs),
                    String(format: "%.1f", p.scoreMs)].joined(separator: ",") + "\n"
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try csv.write(to: dir.appendingPathComponent("spike-run.csv"), atomically: true, encoding: .utf8)
            status += " · saved to Documents/Winnow/out/spike-run.csv"
        } catch {
            status += " · couldn't save results: \(error.localizedDescription)"
        }
    }

    private static func image(for asset: PHAsset, side: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat // one callback, never a degraded first pass
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false    // Phase 0 measures photos stored on this Mac
            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit,
                                                  options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
