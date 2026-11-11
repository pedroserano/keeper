import AppKit
import SwiftUI
import KeeperUI
import DateGuessCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case toApply, review, keyPhotos, places, outings, placeHistory, history, events, people, cameras, albumSuggestions, albumAdditions, albumDuplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toApply: return "To Apply"
        case .review: return "Undated Photos"
        case .keyPhotos: return "Key Photos"
        case .places: return "Places"
        case .outings: return "Outings"
        case .placeHistory: return "History"
        case .history: return "History"
        case .events: return "Events"
        case .people: return "People"
        case .cameras: return "Cameras"
        case .albumSuggestions: return "Suggested Albums"
        case .albumAdditions: return "Missing from Albums"
        case .albumDuplicates: return "Album Duplicates"
        }
    }

    var icon: String {
        switch self {
        case .toApply: return "tray.and.arrow.up"
        case .review: return "photo.on.rectangle"
        case .keyPhotos: return "key"
        case .places: return "mappin.and.ellipse"
        case .outings: return "figure.walk"
        case .placeHistory: return "clock.arrow.circlepath"
        case .history: return "clock.arrow.circlepath"
        case .events: return "square.stack"
        case .people: return "person.2"
        case .cameras: return "camera"
        case .albumSuggestions: return "rectangle.stack.badge.plus"
        case .albumAdditions: return "plus.rectangle.on.rectangle"
        case .albumDuplicates: return "square.on.square"
        }
    }

    static let library: [SidebarItem] = [.toApply, .history, .review, .keyPhotos, .places, .outings]
    static let clues: [SidebarItem] = [.events, .people, .cameras]
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    var _selection = State<SidebarItem?>(initialValue: .review)
    private var selection: SidebarItem? { get { _selection.wrappedValue } nonmutating set { _selection.wrappedValue = newValue } }
    var _columnVisibility = State<NavigationSplitViewVisibility>(initialValue: .all)
    private var columnVisibility: NavigationSplitViewVisibility { get { _columnVisibility.wrappedValue } nonmutating set { _columnVisibility.wrappedValue = newValue } }
    @State private var showShortcuts = false

    var body: some View {
        Group {
            if state.isAuthorized {
                NavigationSplitView(columnVisibility: _columnVisibility.projectedValue) {
                    sidebar
                } detail: {
                    detail
                        // A fixed minimum keeps any screen's content from forcing the sidebar
                        // to collapse (which left no way back to the other screens).
                        .frame(minWidth: Self.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                        .toolbar {
                            ToolbarItem(placement: .navigation) { ScanButton() }
                        }
                }
                .onChange(of: selection) { _, _ in columnVisibility = .all }
                .sheet(isPresented: Binding(
                    get: { state.needsLibrarySetup || state.needsContactsSetup },
                    set: { shown in
                        guard !shown else { return }
                        if state.needsLibrarySetup { state.settings.skippedLibrarySetup = true }
                        if state.needsContactsSetup { state.settings.skippedContactsSetup = true }
                    })) {
                    SetupView()
                }
            } else {
                WelcomeView()
            }
        }
        .overlay(alignment: .top) { BannerView() }
        .photoZoomHost()
        .sheet(isPresented: $showShortcuts) { ShortcutsView() }
        // / shows the shortcuts, unless another sheet or dialog is in front.
        .onHelpKey {
            guard NSApp.keyWindow?.sheetParent == nil, NSApp.keyWindow?.attachedSheet == nil else { return false }
            showShortcuts = true
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcuts)) { _ in
            if NSApp.keyWindow?.attachedSheet == nil { showShortcuts = true }
        }
    }

    private var sidebar: some View {
        List(selection: _selection.projectedValue) {
            Section("Library") {
                ForEach(SidebarItem.library) { row($0) }
            }
            Section("Clues") {
                ForEach(SidebarItem.clues) { row($0) }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        .safeAreaInset(edge: .bottom, spacing: 0) { ActivityFooter() }
    }

    private func row(_ item: SidebarItem) -> some View {
        NavigationLink(value: item) {
            Label(item.title, systemImage: item.icon)
                .badge(badge(for: item))
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .toApply: return state.waitingCount
        case .review: return state.undatedSorted.count
        case .keyPhotos: return state.keyPhotos.count
        case .places: return state.places.confidentCount
        case .events: return state.eventSuggestions.count
        case .people: return state.people.count
        case .albumSuggestions: return state.albumTools.shownSuggestions.count
        case .albumAdditions: return state.albumTools.additions.count
        case .albumDuplicates: return state.albumTools.duplicates.count
        case .outings: return state.places.outingsToPlaceCount
        case .history, .placeHistory, .cameras: return 0
        }
    }

    static let detailMinWidth: CGFloat = 640

    @ViewBuilder private var detail: some View {
        let item = selection ?? .review
        Group {
            switch item {
            case .toApply: ToApplyView()
            case .review: ReviewView(goToPeople: { selection = .people })
            case .keyPhotos: ReviewView(goToPeople: { selection = .people }, keyPhotos: true)
            case .places: PlacesView()
            case .outings: OutingsScreen()
            case .placeHistory, .history: HistoryView()
            case .events: EventsView()
            case .people: PeopleView()
            case .cameras: CamerasView()
            case .albumSuggestions: AlbumSuggestionsView()
            case .albumAdditions: AlbumAdditionsView()
            case .albumDuplicates: AlbumDuplicatesView()
            }
        }
        .navigationTitle(item.title)
        .photoInfoSheet(state)
    }
}

/// The bottom of the sidebar: what the app is doing right now, like the activity line in Photos or Mail.
struct ActivityFooter: View {
    @Environment(AppState.self) private var state
    var _showSummary = State<Bool>(initialValue: false)
    private var showSummary: Bool { get { _showSummary.wrappedValue } nonmutating set { _showSummary.wrappedValue = newValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if let p = state.scanProgress {
            progress(p.phase, p.fraction, p.total > 0 ? "\(p.done.formatted()) of \(p.total.formatted()) · \(p.found.formatted()) undated" : nil) {
                state.cancelScan()
            }
        } else if let p = state.applyProgress {
            progress("Updating dates…", Double(p.done) / Double(max(1, p.total)), "\(p.done.formatted()) of \(p.total.formatted())", stop: nil)
        } else if state.isEstimating, let p = state.estimationProgress {
            progress(p.phase, p.fraction, "\(p.done.formatted()) of \(p.total.formatted())") {
                state.cancelEstimation()
            }
        } else if state.settings.backgroundPaused == true {
            HStack {
                Text("Analysis stopped · \(state.backgroundWorkLeft.formatted()) left")
                Spacer(minLength: 4)
                Button("Resume") { state.resumeBackgroundWork() }
                    .controlSize(.small)
            }
        } else if let last = state.scan.lastScan {
            HStack(spacing: 4) {
                Text("Scanned \(last.formatted(.dateTime.month(.abbreviated).day())) · \(state.undatedSorted.count.formatted()) undated")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    showSummary = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("What the last scan found")
                .popover(isPresented: _showSummary.projectedValue, arrowEdge: .trailing) {
                    ScanSummary().padding(16).frame(width: 380)
                }
            }
        } else {
            Text("Not scanned yet")
        }
    }

    private func progress(_ phase: String, _ fraction: Double, _ detail: String?, stop: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(phase).lineLimit(2)
            HStack(spacing: 6) {
                ProgressView(value: fraction)
                    .controlSize(.small)
                if let stop {
                    Button(action: stop) {
                        Image(systemName: "stop.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop")
                }
            }
            if let detail { Text(detail).monospacedDigit() }
        }
    }
}

struct WelcomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text("Find the dates of your old photos")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Keeper finds photos without a real date, like scanned prints, and guesses when each was taken. You review every guess before anything changes.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            if state.authorization == .denied || state.authorization == .restricted {
                VStack(spacing: 8) {
                    Text("Photos access is turned off for this app.")
                        .font(.headline)
                    Text("Open System Settings ▸ Privacy & Security ▸ Photos and turn on Keeper, then reopen the app.")
                        .foregroundStyle(.secondary)
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } else {
                Button {
                    Task { await state.requestAccess() }
                } label: {
                    Text("Allow Access to Photos")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Text("Your photos stay in your library. Dates are changed only when you click Apply, and every change can be undone.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

/// The message bubble (Keeper's, shared by every screen): it closes itself after 10 seconds.
struct BannerView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        KeeperToast(message: $state.banner)
    }
}

/// First-run steps after Photos access: point the app at the library file once (for the names
/// you've tagged in Photos), then allow Contacts (for birthdays). Each step can be skipped.
struct SetupView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.needsLibrarySetup {
                libraryStep
            } else {
                contactsStep
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func header(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }

    private var libraryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("person.crop.rectangle.stack", "Choose your Photos library",
                   "So the app can use the people you’ve named in Photos.")
            Text("Photos access lets the app see your pictures and dates, but not the names of the people in them. Those live in your library file, and macOS asks you to point to it once. It’s usually in your Pictures folder, or on the drive where you keep your library. It’s only read, never changed.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not Now") { state.settings.skippedLibrarySetup = true }
                Spacer()
                Button {
                    LibraryPicker.choose(state)
                } label: {
                    Text("Choose Library…").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Text("You can also do this later from People ▸ Update from Photos.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var contactsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("person.crop.circle.badge.clock", "Use birthdays from Contacts",
                   "So you don’t have to type everyone’s birth year.")
            Text("When Photos has linked someone to a contact card, the app reads the birthday from it and works out how old they are in each photo. Contacts are only changed if you turn that on in Settings.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not Now") { state.settings.skippedContactsSetup = true }
                Spacer()
                Button {
                    Task { await state.requestContactsAccess() }
                } label: {
                    Text("Allow Contacts…").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Text("You can also do this later from People ▸ Birthdays from Contacts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
