import AppKit
import Photos
import SwiftUI
import KeeperKit

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
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if let gap = session.accessGap { AccessBanner(gap: gap, session: session) }
                        if session.source == .dateRange { DateRangeBar(session: session) }
                        // Only while photos are selected (⌘A, ⌘-click, Shift-click or G).
                        if session.selectsPhotos, !session.list.isEmpty,
                           !session.selectedPhotos.isEmpty || session.selectingAll,
                           session.source == .rejected || session.source == .sideways
                               || session.suggestionsStatus == .ready {
                            AcceptRatingsBar(session: session)
                        }
                    }
                }
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
            // Filling the window keeps the status bar at the bottom and messages at the top.
            ContentUnavailableView(emptyTitle, systemImage: "photo.on.rectangle",
                                   description: Text(emptyDetail))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch session.mode {
            case .grid: GridView()
            case .single: SingleView()
            case .compare: CompareView()
            }
        }
    }

    private var emptyTitle: String {
        switch session.filter {
        case .all: "No photos in \(session.source.title)"
        case .notRejected: "Every photo here is rejected"
        case .unrated: "Every photo here has a rating"
        case .favorites: "No favorites"
        case .rejects: "No rejected photos"
        }
    }

    /// "0.4%" early on (so a long scan doesn't sit at 0%), "37%" later.
    private func percent(_ done: Int, _ total: Int) -> String {
        guard total > 0 else { return "0%" }
        let p = Double(done) / Double(total) * 100
        return p < 10 ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%"
    }

    private var emptyDetail: String {
        if session.source.isGroups {
            switch session.similarity {
            case .waiting:
                return "Keeper is about to scan for look-alikes."
            case .indexing(let done, let total):
                return "Still scanning: \(percent(done, total)) done\(timeLeft(session)). Look-alikes appear here when the scan finishes."
            case .ready:
                return "Every group of look-alikes has been merged or culled."
            }
        }
        if session.source == .sideways && session.filter == .all {
            switch session.orientationScan {
            case .waiting:
                return "Keeper checks which way up your photos are after the look-alikes scan."
            case .scanning(let done, let total):
                return "Still checking: \(done.formatted()) of \(total.formatted()) photos (\(percent(done, total))). Photos that look sideways or upside down appear here as they're found."
            case .ready:
                return "No photos look sideways at this confidence. Lower Minimum confidence in the sidebar to see less certain ones."
            }
        }
        return session.source == .unreviewed && session.filter == .all
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
            // A toolbar menu button (icon and the current choice) rather than a labelled menu picker,
            // which sits off-centre in the toolbar. The icon fills in while a filter is on.
            Menu {
                Picker("Show", selection: $session.filter) {
                    ForEach(CullingSession.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(session.filter.rawValue,
                      systemImage: session.filter == .all ? "line.3.horizontal.decrease.circle"
                                                          : "line.3.horizontal.decrease.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .fixedSize()
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
              window.identifier != SettingsWindowMarker.identifier,
              window.sheetParent == nil, window.attachedSheet == nil else { return false }
        if let text = window.firstResponder as? NSText, text.isEditable { return false }
        // ⌘A: select every photo in the list, as in Photos.
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a", session.selectsPhotos, !session.list.isEmpty {
            Task { await session.selectAllPhotos() }
            return true
        }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }

        let s = session
        switch event.keyCode {
        case 123: s.move(by: -1)                                           // ←
        case 124: s.move(by: 1)                                            // →
        case 126, 125:                                                     // ↑, ↓
            let step = event.keyCode == 126 ? -1 : 1
            if s.mode == .grid && s.sections != nil {                          // a group at a time
                s.moveGroup(by: step, extending: event.modifierFlags.contains(.shift))
            }
            else { s.move(by: s.mode == .grid ? step * s.gridColumns : step) }
        case 36, 76: s.openWithReturn()                                    // Return, Enter
        case 53:                                                           // Esc
            if s.zoomed { s.zoomed = false } else if s.mode != .grid { s.mode = .grid }
            else if !s.selectedPhotos.isEmpty { s.deselectAllPhotos() } else { return false }
        case 49:                                                           // Space
            s.spacePressed()
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
            case "g": s.toggleSelectionAtCursor()
            case "r": s.rotateTarget()
            case "a": if s.source == .sideways { s.rotateSideways() } else { s.acceptSuggestedRating() }
            case "n": if s.source == .sideways { s.dismissSideways() } else { return false }
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
                row(.rejected)
                row(.dateRange)
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
                        AggressivenessSlider(session: session)
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
            Section {
                row(.duplicates)
                row(.similarShots)
            } header: {
                Text("Look-alikes")
            } footer: {
                Text(similarityNote).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                row(.sideways)
            } header: {
                Text("Orientation")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(orientationNote).font(.caption).foregroundStyle(.secondary)
                    SidewaysConfidenceSlider(session: session)
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

    private var similarityNote: String {
        switch session.similarity {
        case .waiting:
            return "Looking for photos taken close together…"
        case .indexing(let done, let total):
            let pct = total > 0 ? Int((Double(done) / Double(total) * 100).rounded()) : 0
            return "Scanning for look-alikes: \(pct)% (\(done.formatted()) of \(total.formatted()))\(timeLeft(session)). "
                + "Groups appear when the scan finishes. It keeps going in the background and picks up where it left off."
        case .ready(let groups):
            return groups == 0 ? "No duplicates or similar shots found."
                : "In each group the best-looking photo is kept, or its largest copy. Merge a group to "
                + "move the rest to Rejected; merged groups leave the list."
        }
    }

    private var orientationNote: String {
        let network = session.orientationNetwork ? ""
            : " The orientation network didn't load, so only faces, people and text are used."
        switch session.orientationScan {
        case .waiting:
            return "Checks which way up each photo is, after the look-alikes scan."
        case .scanning(let done, let total):
            let pct = total > 0 ? Int((Double(done) / Double(total) * 100).rounded()) : 0
            return "Checking which way up: \(pct)% (\(done.formatted()) of \(total.formatted())). "
                + "It keeps going in the background and picks up where it left off." + network
        case .ready(let checked):
            return "Checked \(checked.formatted()) photos for ones that are sideways or upside down." + network
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
            .badge(badge(source))
            .tag(source)
    }

    /// A count of 0 hides a badge, so lists you work through to the end show "0" instead.
    private func badge(_ source: Source) -> Text? {
        guard let n = session.counts[source] else { return nil }
        if n == 0, ![.unreviewed, .duplicates, .similarShots, .suggestedRejects, .sideways].contains(source) { return nil }
        return Text(n.formatted())
    }
}

struct StatusBar: View {
    @ObservedObject var session: CullingSession

    var body: some View {
        HStack(spacing: 14) {
            if !session.list.isEmpty {
                Text("\(session.cursor + 1) of \(session.list.count)").monospacedDigit()
            }
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

/// Everything Keeper knows about a photo, one corner each so they never blur together:
/// top left a reject, top right ♥ if it's a Favorite in Photos, bottom left your
/// own rating (or "Not rated" plus the suggested rating), bottom right a reason to reject.
struct PhotoBadges: View {
    let decision: Decision
    let suggestion: Suggestion?
    let isFavorite: Bool
    var isRaw = false
    var large = false
    /// Sideways Photos: the proposed turn and how sure it is.
    var turn: OrientationRecord? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                FlagIcon(flag: decision.flag)
                Spacer(minLength: 0)
                if isRaw {
                    Text("RAW")
                        .font(.system(size: large ? 11 : 8, weight: .bold))
                        .padding(.horizontal, large ? 5 : 3)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .help("RAW original")
                }
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
                if let turn {
                    TurnLabel(turn: turn, large: large)
                } else if decision.flag == .none, let suggestion, let reason = suggestion.reasons.first {
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

/// "↻ 90° · 87%": the turn Sideways Photos proposes.
struct TurnLabel: View {
    let turn: OrientationRecord
    var large = false

    var body: some View {
        Label("\(turn.rotation.shortLabel) · \(Int((turn.confidence * 100).rounded()))%", systemImage: "rotate.right")
            .labelStyle(.titleOnly)
            .font(large ? .callout.monospacedDigit() : .caption2.monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.blue.opacity(0.85), in: Capsule())
            .foregroundStyle(.white)
            .help("Proposed: \(turn.rotation.label). Confidence \(Int((turn.confidence * 100).rounded()))%, "
                  + "from \(turn.evidence.isEmpty ? "no strong cue" : turn.evidence). A rotates it, N leaves it.")
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

/// ", about 9 minutes left", or nothing until there's a pace to go on.
@MainActor func timeLeft(_ session: CullingSession) -> String {
    guard let left = session.similarityTimeLeft else { return "" }
    let minutes = Int((Double(left.components.seconds) / 60).rounded(.up))
    return minutes <= 1 ? ", about a minute left" : ", about \(minutes) minutes left"
}

/// FR-15: how readily photos are suggested as rejects, with a preview of what lands in each queue.
/// Sideways Photos lists only proposals at least this sure.
struct SidewaysConfidenceSlider: View {
    @ObservedObject var session: CullingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Minimum confidence: \(Int((session.sidewaysMinConfidence * 100).rounded()))%").font(.caption)
            Slider(value: $session.sidewaysMinConfidence, in: 0.2...0.9, step: 0.05)
                .controlSize(.mini)
                .help("Higher shows fewer, surer proposals; lower finds more sideways photos with a few false alarms")
        }
    }
}

struct AggressivenessSlider: View {
    @ObservedObject var session: CullingSession
    @State private var value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Reject suggestions: \(label(value ?? session.aggressiveness))").font(.caption)
            Slider(value: Binding(get: { value ?? session.aggressiveness },
                                  set: { value = $0; session.previewAggressiveness($0) }),
                   in: 0...1, step: 0.05) { editing in
                if !editing, let value { session.setAggressiveness(value) }
            }
            .controlSize(.mini)
            .help("Conservative suggests a reject only when a photo is clearly bad and leaves more photos "
                  + "protected; aggressive suggests more. Stars don't change.")
            HStack {
                Text("Conservative")
                Spacer()
                Text("Aggressive")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            if let p = session.aggressivenessPreview {
                Text("\(p.rejects.formatted()) suggested rejects · \(p.best.formatted()) best shots")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: session.aggressiveness) { value = nil }
    }

    private func label(_ v: Double) -> String {
        switch v {
        case ..<0.3: "conservative"
        case ..<0.45: "cautious"
        case ...0.55: "balanced"
        case ...0.7: "keen"
        default: "aggressive"
        }
    }
}

/// Explains what Keeper can't see and how to let it.
struct AccessBanner: View {
    let gap: CullingSession.AccessGap
    @ObservedObject var session: CullingSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open System Settings") { NSWorkspace.shared.open(settingsURL) }
            Button("Not Now") { session.dismissAccessGap() }
        }
        .font(.callout)
        .padding(10)
        .background(.yellow.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var title: String {
        switch gap {
        case .limitedPhotos: "Keeper can see only some of your photos"
        case .noDatabase: "Keeper can't read this library's database"
        }
    }

    private var detail: String {
        switch gap {
        case .limitedPhotos:
            "You gave Keeper access to selected photos only, so counts, suggestions and look-alikes cover just "
                + "those. Allow full access in Privacy & Security → Photos, then reopen the library."
        case .noDatabase:
            "You can still cull by hand, but suggestions, file sizes, faces and look-alike keepers need Apple's "
                + "scores from it. Turn on Keeper in Privacy & Security → Full Disk Access, then reopen the library."
        }
    }

    private var settingsURL: URL {
        switch gap {
        case .limitedPhotos: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!
        case .noDatabase: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        }
    }
}

/// Above Date Range: which days to show.
struct DateRangeBar: View {
    @ObservedObject var session: CullingSession

    var body: some View {
        HStack(spacing: 10) {
            DatePicker("From", selection: Binding(get: { session.dateRange.lowerBound },
                                                  set: { session.setDateRange(from: $0, to: session.dateRange.upperBound) }),
                       displayedComponents: .date)
            DatePicker("To", selection: Binding(get: { session.dateRange.upperBound },
                                                set: { session.setDateRange(from: session.dateRange.lowerBound, to: $0) }),
                       displayedComponents: .date)
            Menu("Quick Pick") {
                Button("Last 30 Days") { last(days: 30) }
                Button("Last 12 Months") { last(days: 365) }
                Divider()
                Button("This Year") { year(offset: 0) }
                Button("Last Year") { year(offset: -1) }
            }
            .fixedSize()
            Spacer()
            if let n = session.counts[.dateRange] {
                Text("\(n.formatted()) photos").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .datePickerStyle(.field)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func last(days: Int) {
        let today = Date()
        session.setDateRange(from: Calendar.current.date(byAdding: .day, value: 1 - days, to: today)!, to: today)
    }

    private func year(offset: Int) {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date()) + offset
        let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let last = calendar.date(from: DateComponents(year: year, month: 12, day: 31))!
        session.setDateRange(from: first, to: last)
    }
}


/// Above every photo list but the group ones, while photos are picked (⌘A, the circle, ⌘-click,
/// Shift-click, G; Esc unpicks them all): give the picked ones with no rating yet their suggested stars, or in
/// Rejected take the reject off them.
struct AcceptRatingsBar: View {
    @ObservedObject var session: CullingSession
    @State private var counting = false
    @State private var pending: Change?

    var body: some View {
        let selected = session.selectedPhotos.count
        HStack(spacing: 12) {
            Text(session.selectingAll ? "Selecting all photos…"
                 : "\(selected.formatted()) of \(session.list.count.formatted()) photos selected · Esc to deselect")
                .foregroundStyle(.secondary)
            Spacer()
            if counting || session.selectingAll { ProgressView().controlSize(.small) }
            if session.source == .sideways {
                Button("Not Sideways") { session.dismissSideways() }
                    .disabled(selected == 0)
                    .help("Leave the selected photos as they are; they stop showing here (N, ⌘Z undoes)")
                Button("Rotate Selected") { session.rotateSideways() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == 0)
                    .help("Turn each selected photo the way shown on it, as an edit in Photos (A for one photo, ⌘Z undoes)")
            } else if session.source == .rejected {
                Button("Unreject Selected") { session.unrejectSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == 0)
                    .help("Take the reject off the selected photos (⌘Z undoes)")
            } else {
                Button("Accept Suggested Ratings…") {
                    counting = true
                    Task {
                        pending = await session.suggestedRatingsToAccept()
                        counting = false
                        if pending == nil { session.show("None of the selected photos is unrated with a suggested rating.") }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected == 0 || counting)
                .help("Rate the selected photos that have no stars yet with Photos' suggested rating")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .confirmationDialog(title, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Rate \(pending?.after.count.formatted() ?? "") Photos") {
                if let change = pending { session.acceptSuggestedRatings(change) }
                pending = nil
            }
        } message: {
            Text("""
                Each gets the stars shown on it, saved in Photos, and counts as reviewed. \
                Selected photos you've already rated or rejected are left alone. ⌘Z undoes them all.
                """)
        }
    }

    private var title: String {
        let n = pending?.after.count ?? 0
        return "Accept suggested ratings for \(n.formatted()) \(n == 1 ? "photo" : "photos")?"
    }
}
