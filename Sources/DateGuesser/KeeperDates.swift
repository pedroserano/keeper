// What Keeper sees of the dates screens (from Photo Date Guesser): the sidebar rows, the screen
// for each row, the sidebar footer, and the one-time copy of the date app's saved data.

import AppKit
import SwiftUI
import KeeperUI

/// A row of Keeper's Dates section.
public enum DatesItem: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case review, events, people, cameras, places, history, albumSuggestions, albumAdditions, albumDuplicates

    public var id: String { rawValue }
    var item: SidebarItem { SidebarItem(rawValue: rawValue)! }
    public var title: String { item.title }
    /// The rows of the Albums section; the rest are Places and the Dates section.
    public static let albumItems: [DatesItem] = [.albumSuggestions, .albumAdditions, .albumDuplicates]
    public var isAlbumItem: Bool { Self.albumItems.contains(self) }
    public var systemImage: String { item.icon }
}

/// The dates state for one library. Made the first time a Dates row is opened, because it loads
/// everything the date screens know and starts estimating in the background.
@MainActor
public final class DatesModel {
    let state: AppState
    /// Whether a photo's original is a RAW file (Keeper knows from the library's own records).
    public static var isRaw: (String) -> Bool = { _ in false }
    private var observers: [NSObjectProtocol] = []

    /// Copies and decodes the saved data in the background, then makes the state on the main thread.
    public static func load(libraryURL: URL, dataDirectory: URL) async -> DatesModel {
        let store = await Task.detached(priority: .userInitiated) { () -> JSONStore in
            try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            copyFromDateApp(into: dataDirectory)
            let store = JSONStore(directory: dataDirectory)
            AppState.preload(into: store)
            return store
        }.value
        return DatesModel(libraryURL: libraryURL, store: store)
    }

    private init(libraryURL: URL, store: JSONStore) {
        JSONStore.shared = store
        AppState.keeperLibrary = libraryURL
        state = AppState()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                            queue: .main) { [state] _ in
            MainActor.assumeIsolated { state.saveEverything() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [state] _ in
            MainActor.assumeIsolated { state.appBecameActive() }
        })
    }

    /// Saves now, for example before switching to another library.
    public func save() { state.saveEverything() }

    /// ⌘Z on a Dates screen: takes back the last selection, hide or changed guess there (applied
    /// dates and places are undone from History).
    public func undo(on item: DatesItem) {
        let done = item == .places ? state.places.decisionHistory.undo(&state.places.decisions)
                                   : state.decisionHistory.undo(&state.decisions)
        state.banner = done ? "Undone. ⇧⌘Z redoes it." : "Nothing to undo here. Applied changes are undone from History."
    }

    public func redo(on item: DatesItem) {
        let done = item == .places ? state.places.decisionHistory.redo(&state.places.decisions)
                                   : state.decisionHistory.redo(&state.decisions)
        if done { state.banner = "Redone." }
    }

    /// The sidebar count for a row (read inside a view body, so the row updates as it changes).
    public func badge(for item: DatesItem) -> Int {
        switch item.item {
        case .review: state.undatedSorted.count
        case .places: state.places.confidentCount
        case .events: state.eventSuggestions.count
        case .people: state.people.count
        case .albumSuggestions: state.albumTools.shownSuggestions.count
        case .albumAdditions: state.albumTools.additions.count
        case .albumDuplicates: state.albumTools.duplicates.count
        case .history, .cameras: 0
        }
    }

    // MARK: Data from Photo Date Guesser

    /// Where Photo Date Guesser (a sandboxed app) keeps its data: its container is named after its
    /// bundle id, which ends in the app's name.
    nonisolated static var dateAppData: URL? {
        let containers = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: containers.path)) ?? []
        return names.first { $0.hasSuffix(".PhotoMetadataGuesser") }.map {
            containers.appendingPathComponent("\($0)/Data/Library/Application Support/PhotoMetadataGuesser",
                                              isDirectory: true)
        }
    }

    /// Copies the date app's scan, people, groups, events, decisions and undo history into a new
    /// dates folder, once. The date app's own files are left as they are. Its library bookmark
    /// and compiled face model aren't copied: Keeper uses its own library and model.
    nonisolated static func copyFromDateApp(into directory: URL) {
        let fm = FileManager.default
        let marker = directory.appendingPathComponent(".checked-date-app")
        guard !fm.fileExists(atPath: marker.path) else { return }
        defer { fm.createFile(atPath: marker.path, contents: Data()) }
        // Only into a folder with nothing of its own yet.
        let existing = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        guard !existing.contains(where: { $0.hasSuffix(".json") || $0.hasSuffix(".plist") }),
              let source = dateAppData,
              let files = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        let skipped: Set<String> = ["photosLibrary.json", "scan-diagnostics.json"]
        var copied = 0
        for file in files where ["json", "plist"].contains(file.pathExtension) && !skipped.contains(file.lastPathComponent) {
            if (try? fm.copyItem(at: file, to: directory.appendingPathComponent(file.lastPathComponent))) != nil {
                copied += 1
            }
        }
        NSLog("Dates: copied %d files from Photo Date Guesser", copied)
    }
}

/// The screen for a Dates row, filling Keeper's main area.
public struct DatesScreen: View {
    let model: DatesModel
    let item: DatesItem
    let select: (DatesItem) -> Void
    @State private var showShortcuts = false

    public init(model: DatesModel, item: DatesItem, select: @escaping (DatesItem) -> Void) {
        self.model = model
        self.item = item
        self.select = select
    }

    public var body: some View {
        let state = model.state
        Group {
            if state.isAuthorized {
                screen
                    .frame(minWidth: ContentView.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .sheet(isPresented: Binding(
                        get: { state.needsContactsSetup },
                        set: { if !$0, state.needsContactsSetup { state.settings.skippedContactsSetup = true } })) {
                        SetupView().environment(state)
                    }
            } else {
                WelcomeView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { ScanButton() }
            // Each screen adds the keyboard button last in its own toolbar, so it's the farthest right.
            if !state.isAuthorized {
                ToolbarItem(placement: .primaryAction) {
                    ShortcutsToolbarButton { showShortcuts = true }
                }
            }
        }
        .environment(\.showShortcuts, { showShortcuts = true })
        .navigationTitle(item.title)
        .overlay(alignment: .top) { BannerView() }
        .photoZoomHost()
        .sheet(isPresented: $showShortcuts) { ShortcutsView(screen: item.title).environment(state) }
        .onHelpKey {
            guard NSApp.keyWindow?.sheetParent == nil, NSApp.keyWindow?.attachedSheet == nil else { return false }
            showShortcuts = true
            return true
        }
        .environment(state)
    }

    @ViewBuilder private var screen: some View {
        switch item.item {
        case .review: ReviewView(goToPeople: { select(.people) })
        case .places: PlacesView()
        case .history: HistoryView()
        case .events: EventsView()
        case .people: PeopleView()
        case .cameras: CamerasView()
        case .albumSuggestions: AlbumSuggestionsView()
        case .albumAdditions: AlbumAdditionsView()
        case .albumDuplicates: AlbumDuplicatesView()
        }
    }
}

/// The Dates tab of Keeper's Settings window.
public struct DatesSettings: View {
    let model: DatesModel
    let scanning: Bool
    public init(model: DatesModel, scanning: Bool = false) {
        self.model = model
        self.scanning = scanning
    }

    public var body: some View {
        Group {
            if scanning { ScanSettingsView() } else { GeneralSettingsView() }
        }
        .frame(height: 560)
        .environment(model.state)
    }
}

/// What the dates work is doing right now, for the Dates section's footer.
public struct DatesActivity: View {
    let model: DatesModel

    public init(model: DatesModel) { self.model = model }

    public var body: some View {
        ActivityFooter().environment(model.state).padding(.horizontal, -14)
    }
}
