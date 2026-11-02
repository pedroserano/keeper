// Choosing and opening a library. PhotoKit can only work with the System Photo Library,
// so after you choose one, Winnow checks that it is the system one before opening it.

import AppKit
import Photos
import SwiftUI
import WinnowCore
import WinnowKit

@MainActor
final class AppModel: ObservableObject {
    enum State {
        case choosing
        case opening(URL)
        case problem(URL, Problem)
        case ready(CullingSession)
    }

    enum Problem {
        case photosAccess
        case fullDiskAccess(String)
        case notSystemLibrary
        case other(String)
    }

    @Published var state: State = .choosing
    private var library: PhotoLibrary?

    var session: CullingSession? {
        if case .ready(let s) = state { s } else { nil }
    }

    var lastLibraryPath: String? {
        get { UserDefaults.standard.string(forKey: "lastLibraryPath") }
        set { UserDefaults.standard.set(newValue, forKey: "lastLibraryPath") }
    }

    func chooseLibrary() {
        state = .choosing
    }

    func open(_ url: URL, skipSystemCheck: Bool = false) async {
        state = .opening(url)

        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized || access == .limited else {
            state = .problem(url, .photosAccess)
            return
        }

        if !skipSystemCheck {
            let started = ContinuousClock.now
            let isSystem = await isSystemLibrary(url)
            log.notice("open: system-library check took \(started.duration(to: .now))")
            switch isSystem {
            case .success(true): break
            case .success(false):
                state = .problem(url, .notSystemLibrary)
                return
            case .failure(let error):
                if error.kind == .noAccess {
                    state = .problem(url, .fullDiskAccess(error.message))
                } else {
                    state = .problem(url, .other(error.message))
                }
                return
            }
        }

        do {
            let store = try DecisionStore(path: DecisionStore.url(forLibrary: url).path)
            let library = self.library ?? PhotoLibrary()
            self.library = library
            lastLibraryPath = url.path
            state = .ready(CullingSession(library: library, store: store, libraryURL: url))
        } catch {
            state = .problem(url, .other("Couldn't open Winnow's database: \(error.localizedDescription)"))
        }
    }

    /// There's no public API that names the System Photo Library, so look up the 100 newest photos
    /// PhotoKit returns in the chosen library's own database: one read-only query, no copying.
    private func isSystemLibrary(_ url: URL) async -> Result<Bool, PhotosDatabaseError> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 100
        var uuids: [String] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { a, _, _ in
            uuids.append(String(a.localIdentifier.split(separator: "/").first ?? ""))
        }
        // An empty System Photo Library has nothing to cull, so there's nothing to get wrong.
        guard !uuids.isEmpty else { return .success(true) }
        do {
            let found = try await Task.detached { try PhotosDatabase.countPhotos(withUUIDs: uuids, inLibrary: url) }.value
            return .success(Double(found) / Double(uuids.count) >= 0.9)
        } catch let error as PhotosDatabaseError {
            return .failure(error)
        } catch {
            return .failure(PhotosDatabaseError(kind: .sql, message: error.localizedDescription))
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func openPhotosPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
    }
}
