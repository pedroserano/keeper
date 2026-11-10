// Choosing and opening a library. PhotoKit can only work with the System Photo Library,
// so after you choose one, Keeper checks that it is the system one before opening it.

import AppKit
import Photos
import SwiftUI
import KeeperCore
import KeeperKit

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
    /// The System Photo Library, once the chooser has found it; the Open panel starts in its folder.
    @Published var systemLibrary: URL?
    private var library: PhotoLibrary?

    var session: CullingSession? {
        if case .ready(let s) = state { s } else { nil }
    }

    var lastLibraryPath: String? {
        get { UserDefaults.standard.string(forKey: "lastLibraryPath") }
        set { UserDefaults.standard.set(newValue, forKey: "lastLibraryPath") }
    }

    /// The chooser only comes up the first time, or when the last library is gone (its drive isn't
    /// connected, say); otherwise Keeper reopens the last library. File › Choose Library switches.
    init() {
        if let path = lastLibraryPath, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            state = .opening(url)
            Task { await open(url) }
        }
    }

    func chooseLibrary() {
        state = .choosing
    }

    /// The session, unless a Dates screen is showing.
    var cullingSession: CullingSession? {
        guard let session, session.dates == nil else { return nil }
        return session
    }

    /// ⌘Z and ⇧⌘Z: the culling list's own history, or the Dates screen's.
    /// On a Dates screen ⌘Z takes back whichever came last: a selection or Don't Show Again there,
    /// or a rating, Favorite or rotation (Keeper's own changes, made there too).
    func undo() {
        guard let s = cullingSession else { return }
        if let item = s.dates, let dates = s.datesModel {
            if let mine = s.history.undoTime, mine > (dates.undoTime(on: item) ?? .distantPast) {
                s.undo()
                dates.say("Undid \(s.lastUndoLabel ?? "it"). ⇧⌘Z redoes it.")
            } else {
                dates.undo(on: item)
            }
        } else {
            s.undo()
        }
    }

    func redo() {
        guard let s = cullingSession else { return }
        if let item = s.dates, let dates = s.datesModel {
            if let mine = s.history.redoTime, mine > (dates.redoTime(on: item) ?? .distantPast) {
                s.redo()
                dates.say("Redone.")
            } else {
                dates.redo(on: item)
            }
        } else {
            s.redo()
        }
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
            log.notice("open: system-library check took \(started.duration(to: .now), privacy: .public)")
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
            state = .problem(url, .other("Couldn't open Keeper's database: \(error.localizedDescription)"))
        }
    }

    /// Which of these libraries is the System Photo Library, trying the last one used first. Only
    /// when Keeper already has Photos access, so the chooser never asks for it.
    func findSystemLibrary(among urls: [URL]) async {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        let ordered = urls.sorted { a, _ in a.path == lastLibraryPath }
        for url in ordered where (try? await isSystemLibrary(url).get()) == true {
            systemLibrary = url
            return
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

    // MARK: Starting over (Settings › Reset)

    /// Checks every photo again for look-alikes and orientation; your decisions stay.
    func rescan() async {
        guard let session, case .ready = state else { return }
        let url = session.libraryURL
        try? session.store.clearScans()
        await reopen(url)
    }

    /// Forgets everything Keeper stored for the open library: rejects, what you've seen, picks,
    /// ticks and scans. Photos itself is left alone.
    func resetLibrary() async {
        guard let session else { return }
        let url = session.libraryURL
        state = .opening(url)
        DecisionStore.deleteFiles(at: DecisionStore.url(forLibrary: url))
        await open(url, skipSystemCheck: true)
    }

    /// Keeper as just installed: every library's data, its settings and caches, then the chooser.
    func resetEverything() {
        state = .choosing
        let fm = FileManager.default
        try? fm.removeItem(at: DecisionStore.directory)
        try? fm.removeItem(at: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DecisionStore.folderName))
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        KeeperSettings.shared.rules = .standard
        systemLibrary = nil
    }

    private func reopen(_ url: URL) async {
        state = .opening(url)
        await open(url, skipSystemCheck: true)
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func openPhotosPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
    }
}
