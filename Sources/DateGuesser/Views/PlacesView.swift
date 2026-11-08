import DateGuessCore
import MapKit
import SwiftUI
import KeeperUI

/// Where photos without a location were probably taken.
struct PlacesView: View {
    @Environment(AppState.self) private var state
    private var places: PlacesState { state.places }

    @State private var filter: Filter = .likely
    @State private var sort: Sort = .library
    /// The current photo (arrow keys, Return, G, A, N). Selected photos are the ones to place.
    @State private var cursor = GridCursor()
    @State private var detailID: String?
    @State private var confirmApply = false
    @State private var rotateRequest: [String]?
    @State private var confirmRescan = false
    @Environment(\.showShortcuts) private var showShortcuts

    enum Filter: String, CaseIterable, Identifiable {
        case likely = "Likely"
        case possible = "Possible"
        case unguessed = "No Guess"
        case checked = "Selected"
        case hidden = "Hidden"
        /// Not a filter: photos from one camera taken close together, placed with one search.
        case outings = "Outings"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case library = "Library order"
        case newest = "Newest first"
        case confidence = "Most confident first"
        var id: String { rawValue }
    }

    private var visibleIDs: [String] {
        var ids = places.order.filter { id in
            let d = places.decision(id)
            switch filter {
            case .likely: return !d.ignored && (d.override != nil || places.guesses[id]?.level == .high)
            case .possible: return !d.ignored && d.override == nil && places.guesses[id]?.level == .medium
            case .unguessed: return !d.ignored && places.guesses[id] == nil && d.override == nil
            case .checked: return !d.ignored && d.selected
            case .hidden: return d.ignored
            case .outings: return false
            }
        }
        switch sort {
        case .library: break
        case .newest: ids.reverse()
        case .confidence:
            let c = places.guesses
            ids.sort { (c[$0]?.estimate.confidence ?? 0) > (c[$1]?.estimate.confidence ?? 0) }
        }
        return ids
    }

    var body: some View {
        // Worked out once per redraw: both walk every photo missing a place.
        let checked = places.checkedForApply.count
        let outings = filter == .outings
        let ids = outings ? [] : visibleIDs
        Group {
            if outings {
                OutingsList()
            } else {
                photoGrid(ids, checked: checked)
            }
        }
        .navigationSubtitle(checked > 0 ? "\(checked.formatted()) selected" : outings
                            ? "\(places.outings.count.formatted()) outings" : "\(ids.count.formatted()) photos")
        .toolbar { toolbarItems(ids, checked) }
        .alert("Look for photos without a location again?", isPresented: $confirmRescan) {
            Button("Look Again") { places.startScan() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It checks every photo again and runs in the background. Your choices and history are kept.")
        }
        .alert("Set the location of \(checked.formatted()) photos?", isPresented: $confirmApply) {
            Button("Set Locations") { places.applyChecked() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos sets each location the same way Image ▸ Location does: the photos aren’t replaced, and their dates, people, albums and edits stay the same. Photos that got a location in Photos since the last scan are skipped. You can undo this from History.")
        }
    }

    private func photoGrid(_ ids: [String], checked: Int) -> some View {
        let actions = gridActions
        return SelectableGrid(ids: ids, cursor: $cursor, actions: actions) { id, isCurrent in
            PlaceCard(assetID: id, isCurrent: isCurrent,
                      onOpen: { detailID = id },
                      onSelect: { cursor.click(id, in: ids, modifiers: NSEvent.modifierFlags, actions) },
                      onToggle: { cursor.toggle(id, in: ids, extend: NSEvent.modifierFlags.contains(.shift), actions) },
                      onRotate: { rotate(places.decision(id).selected ? ids.filter { places.decision($0).selected } : [id]) })
        }
        .overlay { emptyState(ids) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !ids.isEmpty {
                KeeperActionBar(checked > 0
                                ? "\(checked.formatted()) selected to place · Esc to deselect"
                                : "Select the photos whose place is right (A accepts the current one, G or ⌘-click selects), then Apply.",
                                systemImage: "mappin.and.ellipse") {
                    // Here rather than in the toolbar: with the six filters, a toolbar Select menu
                    // pushed the filters into the » overflow menu.
                    checkMenu(ids)
                    SetPlaceButton(places: places, ids: ids.filter { places.decision($0).selected })
                    Button(checked == 0 ? "Apply" : "Apply \(checked.formatted())") { confirmApply = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(checked == 0 || places.isApplying)
                        .help("Set the selected photos’ locations in Photos")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GridStatusBar(ids: ids, cursor: $cursor)
        }
        .background {
            Group {
                Button("Select All Shown") { places.select(ids, true) }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Deselect All Shown") { places.select(ids, false) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .sheet(item: Binding(get: { detailID.map(IdentifiedString.init) }, set: { detailID = $0?.id })) { item in
            PlaceDetailSheet(assetID: item.id)
        }
        .alert("Rotate \((rotateRequest?.count ?? 0).formatted()) selected photos?",
               isPresented: Binding(get: { rotateRequest != nil }, set: { if !$0 { rotateRequest = nil } })) {
            Button("Rotate") { if let ids = rotateRequest { state.rotate(ids) }; rotateRequest = nil }
            Button("Cancel", role: .cancel) { rotateRequest = nil }
        } message: {
            Text("Each turns 90° clockwise in Photos. It’s an edit, so Image ▸ Revert to Original in Photos brings the original back.")
        }
    }

    private var gridActions: GridActions {
        let places = places, state = state
        return GridActions(
            isSelected: { places.decision($0).selected },
            canSelect: { !places.decision($0).ignored && places.effectivePoint($0) != nil },
            select: { places.select($0.filter { places.effectivePoint($0) != nil }, $1) },
            accept: { if places.effectivePoint($0) != nil { places.select([$0], true) } },
            decline: { places.setIgnored($0, !places.decision($0).ignored) },
            rotate: { rotate($0) },
            open: { detailID = $0 },
            message: { state.banner = $0 },
            allSelected: { places.allSelected })
    }

    private func rotate(_ ids: [String]) {
        if ids.count > ReviewView.rotateWithoutAsking { rotateRequest = ids } else { state.rotate(ids) }
    }

    @ViewBuilder private func emptyState(_ ids: [String]) -> some View {
        if places.scan.lastScan == nil {
            ContentUnavailableView {
                Label(places.isScanning ? "Looking for Photos Without a Location…" : "Find Where Photos Were Taken",
                      systemImage: "mappin.and.ellipse")
            } description: {
                if let p = places.scanProgress, p.total > 0 {
                    ProgressView(value: Double(p.done), total: Double(p.total)).frame(width: 240)
                } else {
                    Text("The app finds photos without a location and guesses where each was taken, from your photos that have one: ones taken around the same time, and ones that look alike. Place names and searches come from Apple Maps. Nothing changes until you apply.")
                }
            } actions: {
                Button("Find Photos Without a Location") { places.startScan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(places.isScanning)
            }
        } else if ids.isEmpty {
            ContentUnavailableView {
                Label(places.isGuessing ? "Guessing Places…" : "No Photos", systemImage: "mappin.slash")
            } description: {
                Text(places.isGuessing ? "The first guesses show up here in a moment."
                     : places.order.isEmpty ? "Every photo has a location." : "Nothing matches “\(filter.rawValue)”.")
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarItems(_ ids: [String], _ checked: Int) -> some ToolbarContent {
        // Show is one drop-down: six filters as buttons don't fit, and the toolbar then hides
        // things in a » menu.
        KeeperToolbar(photoShapeEnabled: filter != .outings, shortcuts: showShortcuts) {
            ShowMenu(selection: $filter,
                     help: "Which photos to show. Outings: photos from one camera taken close together, placed with one search.")
        } action: {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Look for Photos Without a Location Again…") { confirmRescan = true }
                    .disabled(places.isScanning)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort, or look through your library again")
        }
    }

    private func checkMenu(_ ids: [String]) -> some View {
        let confident = ids.filter { places.guesses[$0]?.level == .high }
        return Menu {
            Button("Select All Shown  ⌘A") { places.select(ids, true) }
            Button("Select Confident (\(confident.count.formatted()))") { places.select(confident, true) }
                .disabled(confident.isEmpty)
            Divider()
            Button("Deselect All Shown  ⇧⌘A") { places.select(ids, false) }
        } label: {
            Text("Select")
        }
        .fixedSize()
        .help("Select or deselect many photos at once (⌘A selects all shown)")
    }
}

/// "Annapolis, MD", or the coordinates until Apple Maps answers.
struct PlaceLabel: View {
    var point: GeoPoint
    var name: String?
    /// Only good to the area: names the town ("Around Annapolis, MD").
    var aroundOnly = false

    var body: some View {
        if aroundOnly, name == nil {
            Text(PlaceNames.shared.city(for: point).map { "Around \($0)" } ?? "Around " + Self.coordinates(point))
        } else {
            Text(name ?? PlaceNames.shared.name(for: point) ?? Self.coordinates(point))
        }
    }

    static func coordinates(_ p: GeoPoint) -> String {
        String(format: "%.4f°, %.4f°", p.lat, p.lon)
    }
}

private struct PlaceConfidence: View {
    var guess: PlaceGuessResult

    var body: some View {
        let color: Color = guess.level == .high ? .green : guess.level == .medium ? .orange : .secondary
        Text("\(Int((guess.estimate.confidence * 100).rounded()))%")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .help("About how likely this is the right spot")
    }
}

struct PlaceCard: View {
    @Environment(AppState.self) private var state
    var assetID: String
    /// The current photo (arrow keys, Return, A, N).
    var isCurrent = false
    var onOpen: () -> Void
    var onSelect: () -> Void = {}
    var onToggle: () -> Void = {}
    var onRotate: () -> Void = {}
    @State private var showWhy = false
    @State private var showSearch = false
    @AppStorage(PhotoShapePicker.storageKey) private var wholePhotos = false

    var body: some View {
        let places = state.places
        let decision = places.decision(assetID)
        let guess = places.guesses[assetID]
        VStack(alignment: .leading, spacing: 6) {
            AssetThumbnail(assetID: assetID, side: .infinity, height: 170, showMarks: true, wholePhoto: wholePhotos)
                .onTapGesture { onSelect() }
                .selectedTint(decision.selected)
                .currentPhotoBorder(isCurrent)
                .overlay(alignment: .topLeading) {
                    SelectionCircle(selected: decision.selected,
                                    help: decision.selected ? "Selected: this location will be set. Click to deselect."
                                        : "Select to set this location (G or A). Shift-click selects a range.",
                                    action: onToggle)
                        .disabled(decision.ignored || places.effectivePoint(assetID) == nil)
                        .opacity(decision.ignored ? 0.3 : 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button(action: onOpen) {
                        Image(systemName: "map.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Show on a map")
                }

            HStack(spacing: 5) {
                Image(systemName: decision.override != nil ? "mappin.circle.fill" : "mappin.and.ellipse")
                    .foregroundStyle(decision.override != nil ? Theme.accent : .secondary)
                Group {
                    if let choice = decision.override {
                        PlaceLabel(point: choice.point, name: choice.name)
                    } else if let guess {
                        PlaceLabel(point: guess.estimate.point, aroundOnly: guess.level != .high)
                    } else {
                        Text("No guess").foregroundStyle(.secondary)
                    }
                }
                .font(.headline)
                .lineLimit(1)
                Spacer(minLength: 4)
                if decision.override == nil, let guess { PlaceConfidence(guess: guess) }
            }
            Text(subtitle(guess, decision))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 4) {
                Button {
                    showSearch = true
                } label: {
                    Label(decision.override == nil ? "Set Place…" : "Change…", systemImage: "magnifyingglass")
                }
                .help("Search Apple Maps for the place")
                .popover(isPresented: $showSearch, arrowEdge: .bottom) {
                    PlaceSearchField { choice in
                        places.setOverride(assetID, choice)
                        showSearch = false
                    }
                    .frame(width: 340)
                    .padding(12)
                }
                if decision.override != nil, guess != nil {
                    Button("Use Guess") { places.setOverride(assetID, nil) }
                        .help("Go back to the app’s guess")
                }
                Spacer(minLength: 0)
                if let guess {
                    Button { showWhy = true } label: { Image(systemName: "questionmark.bubble") }
                        .buttonStyle(.borderless)
                        .help("Why this place?")
                        .popover(isPresented: $showWhy, arrowEdge: .bottom) {
                            PlaceWhy(guess: guess).frame(width: 380).padding(16)
                        }
                }
            }
            .controlSize(.small)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .opacity(decision.ignored ? 0.5 : 1)
        .contextMenu {
            Button(decision.selected ? "Deselect" : "Select") { places.setSelected(assetID, !decision.selected) }
                .disabled(decision.ignored || places.effectivePoint(assetID) == nil)
            Button("Show on a Map…") { onOpen() }
            Button("Show in Photos") { Task { await state.showInPhotos(assetID) } }
            Button(decision.selected ? "Rotate Selected Clockwise  R" : "Rotate Clockwise  R") { onRotate() }
                .disabled(state.isRotating)
            Divider()
            if decision.ignored {
                Button("Show This Photo Again  N") { places.setIgnored(assetID, false) }
            } else {
                Button("Leave Without a Location (Don’t Show Again)  N") { places.setIgnored(assetID, true) }
            }
        }
    }

    private func subtitle(_ guess: PlaceGuessResult?, _ decision: PlaceDecision) -> String {
        let date = state.places.date(assetID).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No date"
        if decision.override != nil { return "\(date) · you set this" }
        guard let guess else { return date }
        return "\(date) · \(guess.evidence.first?.summary ?? "")"
    }
}

/// The clues behind a place guess.
struct PlaceWhy: View {
    var guess: PlaceGuessResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Why here?").font(.headline)
            Text(guess.estimate.spreadKm < 2 ? "Probably within a kilometer or so of this spot"
                 : "Probably within about \(Int(guess.estimate.spreadKm.rounded())) km")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(guess.evidence.prefix(6).enumerated()), id: \.offset) { _, e in
                HStack(alignment: .top, spacing: 8) {
                    if let ref = e.referenceID {
                        AssetThumbnail(assetID: ref, side: 44, cornerRadius: 5)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.summary).font(.callout)
                        PlaceLabel(point: e.point).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(Int((e.weight * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("How often a clue like this is right")
                }
            }
        }
    }
}

/// Type a place; Apple Maps suggests matches.
struct PlaceSearchField: View {
    var onPick: (PlaceChoice) -> Void
    @State private var search = PlaceSearch()
    @State private var resolving = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search for a place or address", text: $search.query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if let first = search.suggestions.first { pick(first) }
                    else if !search.query.isEmpty { let text = search.query; Task { await finish { await search.resolve(text: text) } } }
                }
            if resolving {
                ProgressView().controlSize(.small)
            }
            ForEach(search.suggestions) { s in
                Button { pick(s) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title)
                        if !s.subtitle.isEmpty { Text(s.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if search.failed && search.suggestions.isEmpty && !search.query.isEmpty {
                Text("Apple Maps didn’t answer. Check your internet connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { focused = true }
    }

    private func pick(_ s: PlaceSearch.Suggestion) {
        Task { await finish { await search.resolve(s) } }
    }

    private func finish(_ choice: () async -> PlaceChoice?) async {
        resolving = true
        let result = await choice()
        resolving = false
        if let result { onPick(result) }
    }
}

/// One place for every checked photo.
struct SetPlaceButton: View {
    var places: PlacesState
    var ids: [String]
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Label("Set Place", systemImage: "mappin.and.ellipse")
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(ids.isEmpty)
        .help(ids.isEmpty ? "Select photos first, then give them all one place (⌘L)"
              : "Give the \(ids.count.formatted()) selected photos one place (⌘L)")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ids.count == 1 ? "Place for 1 photo" : "Place for \(ids.count.formatted()) photos").font(.headline)
                PlaceSearchField { choice in
                    places.setPlace(ids, choice)
                    showing = false
                }
                Text("Nothing changes in Photos until you click Apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 360)
            .padding(14)
        }
    }
}

/// The photo, its guess on a map, and the photos behind it. Clicking the map drops a pin there.
struct PlaceDetailSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var assetID: String
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        let places = state.places
        let guess = places.guesses[assetID]
        let choice = places.decision(assetID).override
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                AssetPreview(assetID: assetID, maxSide: 300)
                    .frame(width: 300)
                    .onRotateKey { state.rotate([assetID]); return true }
                VStack(alignment: .leading, spacing: 10) {
                    if let choice {
                        Label { PlaceLabel(point: choice.point, name: choice.name) } icon: { Image(systemName: "mappin.circle.fill") }
                            .font(.title3.bold())
                        Text("You set this place.").font(.callout).foregroundStyle(.secondary)
                    }
                    if let guess {
                        PlaceWhy(guess: guess)
                    } else if choice == nil {
                        Text("No guess for this photo. Search for the place, or click the map.").foregroundStyle(.secondary)
                    }
                    PlaceSearchField { places.setOverride(assetID, $0) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            MapReader { proxy in
                Map(position: $camera) {
                    if let guess {
                        MapCircle(center: coordinate(guess.estimate.point), radius: max(150, guess.estimate.spreadKm * 1000))
                            .foregroundStyle(.orange.opacity(0.15))
                        Marker("Guess", systemImage: "sparkles", coordinate: coordinate(guess.estimate.point))
                            .tint(.orange)
                        ForEach(Array(guess.evidence.prefix(6).enumerated()), id: \.offset) { _, e in
                            Annotation("", coordinate: coordinate(e.point)) {
                                Circle().fill(.blue.opacity(0.7)).frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            }
                        }
                    }
                    if let choice {
                        Marker(choice.name, systemImage: "mappin", coordinate: coordinate(choice.point))
                            .tint(.red)
                    }
                }
                .onTapGesture { location in
                    guard let c = proxy.convert(location, from: .local) else { return }
                    let point = GeoPoint(lat: c.latitude, lon: c.longitude)
                    places.setOverride(assetID, PlaceChoice(name: PlaceLabel.coordinates(point), point: point))
                    Task {
                        if let name = await PlaceNames.lookUp(point) {
                            PlaceNames.shared.remember(name, for: point)
                            if places.decision(assetID).override?.point == point {
                                places.setOverride(assetID, PlaceChoice(name: name, point: point))
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 300)
            Divider()
            HStack {
                Text("Click the map to put the pin there.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if choice != nil, guess != nil {
                    Button("Use Guess") { places.setOverride(assetID, nil) }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 780, height: 760)
    }

    private func coordinate(_ p: GeoPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
    }
}

/// Outings: photos from one camera taken close together, placed with one search.
struct OutingsList: View {
    @Environment(AppState.self) private var state
    @State private var showDone = false

    var body: some View {
        let places = state.places
        let outings = places.outings.filter { members in
            let open = members.filter { !places.decision($0).ignored }
            return !open.isEmpty && (showDone || open.contains { places.decision($0).override == nil })
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Photos from one camera taken within a couple of hours of each other. Give an outing one place, then Apply.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Show placed outings", isOn: $showDone)
                        .toggleStyle(.checkbox)
                }
                ForEach(outings, id: \.self) { members in
                    OutingRow(members: members)
                    Divider()
                }
            }
            .padding(20)
        }
        .overlay {
            if places.scan.lastScan != nil && outings.isEmpty {
                ContentUnavailableView("No Outings to Place", systemImage: "figure.walk",
                                       description: Text(places.outings.isEmpty
                                                         ? "Outings need photos with a real date. Scans and other undated photos are placed one by one."
                                                         : "Every outing has a place."))
            }
        }
    }
}

private struct OutingRow: View {
    @Environment(AppState.self) private var state
    var members: [String]
    @State private var showSearch = false
    @State private var detailID: String?

    var body: some View {
        let places = state.places
        let open = members.filter { !places.decision($0).ignored }
        let chosen = Set(open.compactMap { places.decision($0).override })
        let best = open.compactMap { places.guesses[$0] }.max { $0.estimate.confidence < $1.estimate.confidence }
        let guessed = open.filter { places.guesses[$0] != nil }
        let checked = open.filter { places.decision($0).selected }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(span(open)).font(.headline)
                Text("\(open.count.formatted()) photos" + (places.cameras[open[0]].map { " · \($0)" } ?? ""))
                    .foregroundStyle(.secondary)
                Spacer()
                if !checked.isEmpty {
                    Text("\(checked.count.formatted()) selected").font(.caption).foregroundStyle(Theme.accent)
                }
            }
            ThumbnailStrip {
                LazyHStack(spacing: 6) {
                    ForEach(open.prefix(40), id: \.self) { id in
                        AssetThumbnail(assetID: id, side: 84, showMarks: true)
                            .onTapGesture { detailID = id }
                            .help("Show on a map")
                    }
                    if open.count > 40 {
                        Text("+\((open.count - 40).formatted())").foregroundStyle(.secondary).frame(width: 60)
                    }
                }
            }
            .frame(height: 84)
            HStack(spacing: 8) {
                Image(systemName: chosen.isEmpty ? "mappin.and.ellipse" : "mappin.circle.fill")
                    .foregroundStyle(chosen.isEmpty ? Color.secondary : Theme.accent)
                if chosen.count == 1, let choice = chosen.first {
                    PlaceLabel(point: choice.point, name: choice.name).font(.callout.weight(.semibold))
                } else if chosen.count > 1 {
                    Text("\(chosen.count) different places").font(.callout)
                } else if let best {
                    PlaceLabel(point: best.estimate.point, aroundOnly: best.level != .high).font(.callout)
                    Text("guessed for \(guessed.count.formatted()) of \(open.count.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No guess").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showSearch = true
                } label: {
                    Label(chosen.isEmpty ? "Set Place…" : "Change…", systemImage: "magnifyingglass")
                }
                .popover(isPresented: $showSearch, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Place for \(open.count.formatted()) photos").font(.headline)
                        PlaceSearchField { choice in
                            places.setPlace(open, choice)
                            showSearch = false
                        }
                    }
                    .frame(width: 340)
                    .padding(12)
                }
                if chosen.isEmpty, let best, best.level == .high {
                    Button("Use Guess for All") {
                        let name = PlaceNames.shared.name(for: best.estimate.point) ?? PlaceLabel.coordinates(best.estimate.point)
                        places.setPlace(open, PlaceChoice(name: name, point: best.estimate.point))
                    }
                    .help("Give every photo in this outing the most confident guess")
                }
                Button(checked.count == open.count ? "Deselect" : "Select") {
                    places.select(open.filter { places.effectivePoint($0) != nil }, checked.count != open.count)
                }
                .disabled(open.allSatisfy { places.effectivePoint($0) == nil })
            }
            .controlSize(.small)
        }
        .sheet(item: Binding(get: { detailID.map(IdentifiedString.init) }, set: { detailID = $0?.id })) { item in
            PlaceDetailSheet(assetID: item.id)
        }
    }

    private func span(_ ids: [String]) -> String {
        let dates = ids.compactMap { state.places.date($0) }
        guard let first = dates.min(), let last = dates.max() else { return "No date" }
        let day = first.formatted(date: .abbreviated, time: .omitted)
        let from = first.formatted(date: .omitted, time: .shortened), to = last.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(first, inSameDayAs: last) { return from == to ? "\(day), \(from)" : "\(day), \(from) – \(to)" }
        return "\(day) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }
}
