import AppKit
import Photos
import SwiftUI
import WinnowKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: CullingSession
    @State private var showingDelete = false
    @State private var showingShortcuts = false
    @State private var keyMonitor: Any?

    var body: some View {
        NavigationSplitView {
            Sidebar(session: session, library: session.library)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            detail
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
        .onAppear(perform: installKeyMonitor)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Culling keys are handled for the whole window, so they always act on the selected photo,
    /// wherever you last clicked (sidebar, toolbar, a photo). SwiftUI keyboard focus moved
    /// whenever you clicked something else, which made keys work only some of the time.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
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

    /// Returns true if the key was a culling key and has been used. Left alone: shortcuts with
    /// ⌘ ⌃ or ⌥ (they belong to the menus), typing in a text field, and anything while a sheet is open.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !showingDelete, !showingShortcuts, let window = event.window,
              window.sheetParent == nil, window.attachedSheet == nil else { return false }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if let text = window.firstResponder as? NSText, text.isEditable { return false }

        let s = session
        switch event.keyCode {
        case 123: s.move(by: -1)                                           // ←
        case 124: s.move(by: 1)                                            // →
        case 126: s.move(by: s.mode == .grid ? -s.gridColumns : -1)        // ↑
        case 125: s.move(by: s.mode == .grid ? s.gridColumns : 1)          // ↓
        case 36, 76: s.mode = s.mode == .grid ? .single : .grid            // Return, Enter
        case 53:                                                           // Esc
            if s.zoomed { s.zoomed = false } else if s.mode != .grid { s.mode = .grid } else { return false }
        case 49:                                                           // Space
            if s.mode == .grid { s.mode = .single } else { s.toggleZoom(onFace: false) }
        case 51, 117: s.perform(.reject)                                   // ⌫, ⌦
        default:
            // Shift is kept, so "?" arrives as "?".
            switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
            case "0", "1", "2", "3", "4", "5": s.perform(.rate(Int(event.charactersIgnoringModifiers!)!))
            case "x": s.perform(.reject)
            case "u": s.perform(.clearFlag)
            case "f": s.perform(.toggleFavorite)
            case "h": s.perform(.toggleHidden)
            case "z": s.toggleZoom(onFace: true)
            case "c": s.mode = s.mode == .compare ? .single : .compare
            case "k": s.keepFocusedRejectRest()
            case "a": s.acceptSuggestedRating()
            case "i": s.showingScores.toggle()
            case "?", "/": showingShortcuts = true
            default: return false
            }
        }
        return true
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
                if session.suggestionsStatus == .ready { row(.calibrate) }
            } header: {
                Text("Suggestions")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let note = suggestionsNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    if session.suggestionsStatus == .ready {
                        Button(session.learning == .learning ? "Learning…" : "Learn from My Ratings") {
                            session.learnFromRatings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(session.learning == .learning)
                        .help("Fit the suggested stars to the ratings you've given in Photos")
                    }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
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
            .background(.bar)
        }
    }

    private var suggestionsNote: String? {
        switch session.suggestionsStatus {
        case .loading: return "Reading Apple's scores…"
        case .notAnalysed: return "Photos hasn't analysed this library yet. Leave the Mac idle and plugged in, then reopen it."
        case .unavailable: return "Needs Full Disk Access to read Apple's scores."
        case .ready: break
        }
        func pct(_ x: Double) -> String { String(format: "%.2f", x) }
        switch session.learning {
        case .waiting, .learning:
            return "Stars from Photos' curation score. Learning from your ratings…"
        case .fitted(let e):
            return "Stars fitted to your \(e.rated) ratings. Agreement with your ratings: \(pct(e.model)), "
                + "vs \(pct(e.curation)) for Photos' curation alone."
        case .usingCuration(let e) where !e.enoughRatings:
            return "Stars from Photos' curation score. Rate at least \(RatingModel.minimumRatings) photos "
                + "(you've rated \(e.rated)) to fit them to your taste: try Rate to Calibrate."
        case .usingCuration(let e):
            return "Stars from Photos' curation score, which already agrees with your \(e.rated) ratings "
                + "as well as a fitted model (\(pct(e.curation)) vs \(pct(e.model)))."
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
/// top left a reject, top right ♥ if it's a Favorite in Photos, bottom left your
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
                if decision.flag == .none, let suggestion, let reason = suggestion.reasons.first {
                    // Orange: suggested reject. Grey: same issue, but Photos thinks the photo matters
                    // to you, so it's kept out of Suggested Rejects.
                    Text(reason.rawValue)
                        .font(large ? .callout : .caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(suggestion.protected ? Color.gray.opacity(0.6) : Color.orange.opacity(0.9),
                                    in: Capsule())
                        .foregroundStyle(suggestion.protected ? .white : .black)
                        .help(suggestion.protected
                              ? "Photos thinks this one matters to you, so it isn't a suggested reject"
                              : "Suggested reject: " + suggestion.reasons.map(\.rawValue).joined(separator: ", "))
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
