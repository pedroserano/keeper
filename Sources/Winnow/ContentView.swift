import Photos
import SwiftUI
import WinnowKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: CullingSession
    @State private var showingDelete = false
    @State private var showingShortcuts = false
    @FocusState private var keysFocused: Bool

    var body: some View {
        NavigationSplitView {
            Sidebar(session: session, library: session.library)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            detail
                .focusable()
                .focusEffectDisabled()
                .focused($keysFocused)
                .onKeyPress(phases: .down, action: handleKey)
                .simultaneousGesture(TapGesture().onEnded { keysFocused = true })
                .onAppear { keysFocused = true }
                .onChange(of: session.source) { keysFocused = true }
                .overlay(alignment: .top) { toast }
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(session: session) }
                .toolbar { toolbar }
                .navigationTitle(session.source.title)
                .navigationSubtitle(session.libraryName)
        }
        .environmentObject(session)
        .environmentObject(session.library)
        .sheet(isPresented: $showingDelete) { DeleteQueueSheet().environmentObject(session).environmentObject(session.library) }
        .sheet(isPresented: $showingShortcuts) { ShortcutsSheet() }
    }

    @ViewBuilder private var detail: some View {
        if session.loading {
            ProgressView("Filtering \(session.source.title)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.list.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "photo.on.rectangle",
                                   description: Text(emptyDetail))
        } else {
            switch session.mode {
            case .grid: GridView()
            case .single: SingleView()
            case .compare: CompareView()
            }
        }
    }

    private var emptyTitle: String {
        session.filter == .all ? "No photos in \(session.source.title)" : "No \(session.filter.rawValue.lowercased()) photos"
    }

    private var emptyDetail: String {
        session.source == .unreviewed && session.filter == .all
            ? "You've looked at every photo in this library."
            : "Choose another source or filter."
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $session.mode) {
                Label("Grid", systemImage: "square.grid.2x2").tag(CullingSession.Mode.grid)
                Label("Single", systemImage: "square").tag(CullingSession.Mode.single)
                Label("Compare", systemImage: "rectangle.split.2x1").tag(CullingSession.Mode.compare)
            }
            .pickerStyle(.segmented)
            .help("Grid, single photo or compare (⌘1, ⌘2, ⌘3)")
        }
        ToolbarItem {
            Picker("Show", selection: $session.filter) {
                ForEach(CullingSession.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Which photos to show")
        }
        ToolbarItem {
            Button { showingDelete = true } label: {
                Label("Delete Rejected (\(session.rejectCount))", systemImage: "trash")
            }
            .disabled(session.rejectCount == 0)
            .help("Review and delete the photos you rejected")
        }
        ToolbarItem {
            Button { showingShortcuts = true } label: { Label("Keyboard Shortcuts", systemImage: "keyboard") }
                .help("Keyboard shortcuts (?)")
        }
    }

    @ViewBuilder private var toast: some View {
        if let message = session.message {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored } // leave ⌘ shortcuts to the menus
        let s = session
        switch press.key {
        case .leftArrow: s.move(by: -1)
        case .rightArrow: s.move(by: 1)
        case .upArrow: s.move(by: s.mode == .grid ? -s.gridColumns : -1)
        case .downArrow: s.move(by: s.mode == .grid ? s.gridColumns : 1)
        case .return: s.mode = s.mode == .grid ? .single : .grid
        case .escape:
            if s.zoomed { s.zoomed = false } else if s.mode != .grid { s.mode = .grid } else { return .ignored }
        case .space:
            if s.mode == .grid { s.mode = .single } else { s.toggleZoom(onFace: false) }
        case .delete, .deleteForward: s.perform(.reject)
        default:
            switch press.characters.lowercased() {
            case "0", "1", "2", "3", "4", "5": s.perform(.rate(Int(press.characters)!))
            case "p": s.perform(.pick)
            case "x": s.perform(.reject)
            case "u": s.perform(.clearFlag)
            case "h": s.perform(.toggleHidden)
            case "z": s.toggleZoom(onFace: true)
            case "c": s.mode = s.mode == .compare ? .single : .compare
            case "k": s.keepFocusedRejectRest()
            case "a": s.acceptSuggestedRating()
            case "i": s.showingScores.toggle()
            case "?", "/": showingShortcuts = true
            default: return .ignored
            }
        }
        return .handled
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: CullingSession
    @ObservedObject var library: PhotoLibrary

    var body: some View {
        List(selection: Binding<Source?>(get: { session.source }, set: { if let s = $0 { session.select(s) } })) {
            Section("Library") {
                row(.allPhotos)
                row(.unreviewed)
                row(.favorites)
            }
            Section {
                row(.suggestedRejects)
                row(.bestShots)
            } header: {
                Text("Suggestions")
            } footer: {
                if let note = suggestionsNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Media Types") {
                row(.screenshots)
                row(.bursts)
            }
            if !library.albums.isEmpty {
                Section("Albums") {
                    ForEach(library.albums, id: \.localIdentifier) { album in
                        row(.album(id: album.localIdentifier, title: album.localizedTitle ?? "Untitled"))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary)
                Text(session.libraryName).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…") { model.chooseLibrary() }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .padding(10)
        }
    }

    private var suggestionsNote: String? {
        switch session.suggestionsStatus {
        case .loading: "Reading Apple's scores…"
        case .ready: "From Apple Photos' own scores."
        case .notAnalysed: "Photos hasn't analysed this library yet. Leave the Mac idle and plugged in, then reopen it."
        case .unavailable: "Needs Full Disk Access to read Apple's scores."
        }
    }

    private func row(_ source: Source) -> some View {
        Label(source.title, systemImage: source.systemImage)
            .badge(session.counts[source] ?? 0)
            .tag(source)
    }
}

struct StatusBar: View {
    @ObservedObject var session: CullingSession

    var body: some View {
        HStack(spacing: 14) {
            if !session.list.isEmpty {
                Text("\(session.cursor + 1) of \(session.list.count)").monospacedDigit()
            }
            Label("\(session.pickCount) picked", systemImage: "checkmark.circle")
            Label("\(session.rejectCount) rejected", systemImage: "xmark.circle")
            Spacer()
            if session.zoomed { Text("100%").monospacedDigit() }
            Text("? for shortcuts").foregroundStyle(.tertiary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Everything Winnow knows about a photo, one corner each so they never blur together:
/// top left your pick or reject, top right ♥ if it's a Favorite in Photos, bottom left your
/// own rating (or "Not rated" plus the suggested rating), bottom right a reason to reject.
struct PhotoBadges: View {
    let decision: Decision
    let suggestion: Suggestion?
    let isFavorite: Bool
    var large = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                FlagIcon(flag: decision.flag)
                Spacer(minLength: 0)
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                        .help("Favorite in Photos")
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 4) {
                RatingLabel(rating: decision.rating, suggested: suggestion?.stars ?? 0, compact: !large)
                Spacer(minLength: 0)
                if decision.flag == .none, let reason = suggestion?.reasons.first {
                    Text(reason.rawValue)
                        .font(large ? .callout : .caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.9), in: Capsule())
                        .foregroundStyle(.black)
                        .help("Suggested reject: " + (suggestion?.reasons.map(\.rawValue).joined(separator: ", ") ?? ""))
                }
            }
        }
        .font(large ? .title3 : .caption)
        .padding(large ? 8 : 5)
    }
}

struct FlagIcon: View {
    let flag: Flag

    var body: some View {
        switch flag {
        case .pick: Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).help("Picked")
        case .reject: Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .red).help("Rejected")
        case .none: EmptyView()
        }
    }
}

/// Your rating as yellow stars. Unrated photos say so, with the suggestion beside it in a
/// separate grey capsule so it can't be mistaken for a rating you gave.
struct RatingLabel: View {
    let rating: Int
    let suggested: Int
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if rating > 0 {
                Text(String(repeating: "★", count: rating))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .help("Your rating")
            } else {
                if !compact {
                    Text("Not rated").foregroundStyle(.secondary)
                }
                if suggested > 0 {
                    Label("\(suggested)★", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 5)
                        .background(.gray.opacity(0.55), in: Capsule())
                        .help("Suggested from Apple's scores. Press A to accept.")
                }
            }
        }
    }
}
