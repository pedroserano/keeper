import SwiftUI
import KeeperUI
import KeeperCore
import DateGuessCore

struct ReviewView: View {
    @Environment(AppState.self) private var state
    var goToPeople: () -> Void = {}

    @Environment(\.showShortcuts) private var showShortcuts
    var _filter = State<Filter>(initialValue: .toReview)
    private var filter: Filter { get { _filter.wrappedValue } nonmutating set { _filter.wrappedValue = newValue } }
    var _sort = State<Sort>(initialValue: .library)
    private var sort: Sort { get { _sort.wrappedValue } nonmutating set { _sort.wrappedValue = newValue } }
    var _groupFilter = State<UUID?>(initialValue: nil)
    private var groupFilter: UUID? { get { _groupFilter.wrappedValue } nonmutating set { _groupFilter.wrappedValue = newValue } }
    var _search = State<String>(initialValue: "")
    private var search: String { get { _search.wrappedValue } nonmutating set { _search.wrappedValue = newValue } }
    var _detailID = State<String?>(initialValue: nil)
    private var detailID: String? { get { _detailID.wrappedValue } nonmutating set { _detailID.wrappedValue = newValue } }
    var _confirmApply = State<Bool>(initialValue: false)
    private var confirmApply: Bool { get { _confirmApply.wrappedValue } nonmutating set { _confirmApply.wrappedValue = newValue } }
    /// The current photo (arrow keys, Return, G, A, N). Selected photos are the ones to date.
    @State private var cursor = GridCursor()
    var _rotateRequest = State<[String]?>(initialValue: nil)
    private var rotateRequest: [String]? { get { _rotateRequest.wrappedValue } nonmutating set { _rotateRequest.wrappedValue = newValue } }
    /// More than this many selected photos asks first before R rotates them all.
    static let rotateWithoutAsking = 10

    enum Filter: String, CaseIterable, Identifiable {
        case toReview = "All"
        case selected = "Selected"
        case low = "Unsure"
        /// Photos dated the day they were recovered (data recovery), not when they were taken.
        case recovered = "Recovered"
        case ignored = "Not Shown"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case library = "Library order"
        case confidence = "Most confident first"
        case year = "Estimated year"
        case clues = "Most clues first"
        case filename = "Filename"
        var id: String { rawValue }
    }

    private var visibleIDs: [String] {
        var items = state.undatedSorted.filter { state.estimates[$0.id] != nil }
        if let g = groupFilter, let group = state.groups.first(where: { $0.id == g }) {
            let ids = Set(group.assetIDs)
            items = items.filter { ids.contains($0.id) }
        }
        if !search.isEmpty {
            items = items.filter { $0.filename.localizedCaseInsensitiveContains(search) || $0.albums.contains { $0.localizedCaseInsensitiveContains(search) } }
        }
        items = items.filter { photo in
            let d = state.decision(photo.id)
            let level = state.effectiveEstimate(photo.id)?.confidenceLevel
            switch filter {
            case .toReview: return !d.ignored
            case .selected: return d.selected
            case .low: return !d.ignored && level == .low
            case .recovered: return !d.ignored && state.recoveryBatch(photo.id) != nil
            case .ignored: return d.ignored
            }
        }
        switch sort {
        case .library: break
        // Sort keys are worked out once per photo, not on every comparison.
        case .confidence:
            let keys = items.map { state.estimates[$0.id]?.estimate.confidence ?? 0 }
            items = zip(items, keys).sorted { $0.1 > $1.1 }.map(\.0)
        case .year:
            let keys = items.map { state.effectiveEstimate($0.id)?.year ?? 0 }
            items = zip(items, keys).sorted { $0.1 < $1.1 }.map(\.0)
        case .clues:
            // The same count the card shows ("3 clues"); ties keep library order.
            let counts = Dictionary(uniqueKeysWithValues: items.map { p in
                (p.id, state.estimates[p.id]?.evidence.filter(\.hasYearInfo).count ?? 0)
            })
            items = items.enumerated().sorted { a, b in
                let ca = counts[a.element.id] ?? 0, cb = counts[b.element.id] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }.map(\.element)
        case .filename:
            items.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        }
        return items.map(\.id)
    }

    var body: some View {
        let ids = visibleIDs
        let selectedCount = state.selectedForApply.count
        let actions = gridActions
        SelectableGrid(ids: ids, cursor: $cursor, actions: actions) { id, isCurrent in
            ReviewCard(assetID: id, isCurrent: isCurrent, onOpen: { detailID = id },
                       onSelect: { cursor.click(id, in: ids, modifiers: NSEvent.modifierFlags, actions) },
                       onToggle: { cursor.toggle(id, in: ids, extend: NSEvent.modifierFlags.contains(.shift), actions) },
                       onRotate: { rotate(state.decision(id).selected ? ids.filter { state.decision($0).selected } : [id]) })
        }
        .overlay { emptyState(ids) }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if state.people.isEmpty && !state.estimates.isEmpty {
                    KeeperActionBar("Birth years make guesses much better.", systemImage: "person.2") {
                        Button("Add People") { goToPeople() }
                    }
                    Divider()
                }
                if !ids.isEmpty { actionBar(ids, selectedCount) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GridStatusBar(ids: ids, cursor: $cursor)
        }
        // Menu items' shortcuts only work while the menu is open, so these keep ⌘A and ⇧⌘A working.
        .background {
            Group {
                Button("Select All Shown") { state.select(ids, true) }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Deselect All Shown") { state.select(ids, false) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .searchable(text: _search.projectedValue, placement: .toolbar, prompt: "Filenames or albums")
        .navigationSubtitle(selectedCount > 0 ? "\(selectedCount.formatted()) selected" : "\(ids.count.formatted()) photos")
        .toolbar { toolbarItems(ids, selectedCount) }
        .sheet(item: Binding(get: { detailID.map(IdentifiedString.init) }, set: { detailID = $0?.id })) { item in
            PhotoDetailSheet(assetID: item.id)
        }
        .alert("Rotate \((rotateRequest?.count ?? 0).formatted()) selected photos?",
               isPresented: Binding(get: { rotateRequest != nil }, set: { if !$0 { rotateRequest = nil } })) {
            Button("Rotate") { if let ids = rotateRequest { state.rotate(ids) }; rotateRequest = nil }
            Button("Cancel", role: .cancel) { rotateRequest = nil }
        } message: {
            Text("Each turns 90° clockwise in Photos. It’s an edit, so the original is kept and Image ▸ Revert to Original in Photos brings it back.")
        }
        .alert("Apply \(selectedCount.formatted()) new dates?", isPresented: _confirmApply.projectedValue) {
            Button("Apply Dates") { state.applySelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only photos without a real date that you selected are changed. Any whose date was changed in Photos since the last scan are skipped. Photos updates each date the same way Image ▸ Adjust Date and Time does: the photos aren’t replaced, and their places, people, albums and edits stay the same. You can undo this from History.")
        }
    }

    @ViewBuilder private func emptyState(_ ids: [String]) -> some View {
        if state.scan.lastScan == nil && !state.isScanning {
            ContentUnavailableView {
                Label("Find Your Undated Photos", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("The app looks for photos without a real date, like scanned prints, and guesses when each was taken. Nothing changes until you apply.")
            } actions: {
                Button("Scan Library") { state.startScan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else if state.estimates.isEmpty {
            ContentUnavailableView {
                Label(state.isScanning ? "Scanning Your Library…" : state.isEstimating ? "Guessing Dates…" : "Nothing to Review", systemImage: "sparkles")
            } description: {
                Text(state.isScanning || state.isEstimating ? "The first guesses show up here in a moment." : "No undated photos were found.")
            }
        } else if ids.isEmpty {
            if search.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Nothing matches “\(filter.rawValue)”."))
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarItems(_ ids: [String], _ selectedCount: Int) -> some ToolbarContent {
        KeeperToolbar(shortcuts: showShortcuts) {
            ShowMenu(selection: _filter.projectedValue)
        } action: {
            sortMenu
        }
    }

    /// Under the toolbar: what's selected, Set Date and Apply.
    private func actionBar(_ ids: [String], _ selectedCount: Int) -> some View {
        let hiddenSelected = ids.filter { state.decision($0).selected && state.decision($0).ignored }
        return KeeperActionBar(filter == .ignored
                        ? (hiddenSelected.isEmpty ? "Select photos to show them again (⌘A selects all, Shift-click a range)."
                           : "\(hiddenSelected.count.formatted()) selected · Show Again or N brings them back")
                        : selectedCount > 0
                        ? "\(selectedCount.formatted()) selected to date · Esc to deselect"
                        : "Select the photos whose guess is right (A accepts the current one, G or ⌘-click selects), then Apply.",
                        systemImage: "calendar") {
            checkMenu(ids)
            if !hiddenSelected.isEmpty {
                Button("Show \(hiddenSelected.count.formatted()) Again") { state.setIgnored(hiddenSelected, false) }
                    .help("Show the selected photos again (N)")
            }
            SetDateButton(state: state, ids: ids.filter { state.decision($0).selected && !state.decision($0).ignored })
            Button(selectedCount == 0 ? "Apply" : "Apply \(selectedCount.formatted())") { confirmApply = true }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0 || state.isApplying)
                .help("Set the selected photos’ dates in Photos")
        }
    }

    private var gridActions: GridActions {
        let state = state
        return GridActions(
            isSelected: { state.decision($0).selected },
            select: { state.select($0, $1) },
            accept: { state.select([$0], true) },
            // N on a selected photo hides (or shows again) every selected photo like it.
            decline: { id in
                let d = state.decision(id)
                let group = d.selected
                    ? state.decisions.filter { $0.value.selected && $0.value.ignored == d.ignored }.map(\.key) : [id]
                state.setIgnored(group, !d.ignored)
                if group.count > 1 {
                    state.banner = "\(d.ignored ? "Showed" : "Hid") \(group.count.formatted()) photos. ⌘Z undoes it."
                }
            },
            rotate: { rotate($0) },
            open: { detailID = $0 },
            message: { state.banner = $0 })
    }

    private func rotate(_ ids: [String]) {
        if ids.count > Self.rotateWithoutAsking { rotateRequest = ids } else { state.rotate(ids) }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: _sort.projectedValue) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            if !state.groups.isEmpty {
                Picker("Event or Group", selection: _groupFilter.projectedValue) {
                    Text("All Photos").tag(UUID?.none)
                    ForEach(state.groups) { g in Text(g.name).tag(UUID?.some(g.id)) }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort, or show one event or group")
    }

    /// Selecting many at once: ⌘A selects everything shown, ⇧⌘A deselects it.
    private func checkMenu(_ ids: [String]) -> some View {
        let confident = ids.filter { state.effectiveEstimate($0)?.confidenceLevel == .high }
        return Menu {
            Button("Select All Shown  ⌘A") { state.select(ids, true) }
            Button("Select Confident (\(confident.count.formatted()))") { state.select(confident, true) }
                .disabled(confident.isEmpty)
            Button("Select Medium or High Confidence") {
                state.select(ids.filter { state.effectiveEstimate($0)?.confidenceLevel != .low }, true)
            }
            Divider()
            Button("Deselect All Shown  ⇧⌘A") { state.select(ids, false) }
        } label: {
            Text("Select")
        }
        .fixedSize()
        .help("Select or deselect many photos at once (⌘A selects all shown)")
    }
}

struct IdentifiedString: Identifiable {
    var id: String
}

struct ReviewCard: View {
    @Environment(AppState.self) private var state
    var assetID: String
    /// The current photo (arrow keys, Return, A, N).
    var isCurrent = false
    var onOpen: () -> Void
    /// Clicking the picture highlights it.
    var onSelect: () -> Void = {}
    /// Clicking the circle selects or deselects it.
    var onToggle: () -> Void = {}
    var onRotate: () -> Void = {}
    var _showWhy = State<Bool>(initialValue: false)
    private var showWhy: Bool { get { _showWhy.wrappedValue } nonmutating set { _showWhy.wrappedValue = newValue } }
    @AppStorage(PhotoShapePicker.storageKey) private var wholePhotos = false

    var body: some View {
        if let computed = state.estimates[assetID], let estimate = state.effectiveEstimate(assetID), let photo = state.photo(assetID) {
            let decision = state.decision(assetID)
            let overridden = decision.isOverridden
            VStack(alignment: .leading, spacing: 6) {
                AssetThumbnail(assetID: assetID, side: .infinity, height: 170, showMarks: true, wholePhoto: wholePhotos)
                    .onTapGesture { onSelect() }
                    .selectedTint(decision.selected)
                    .currentPhotoBorder(isCurrent)
                    .overlay(alignment: .topLeading) {
                        SelectionCircle(selected: decision.selected,
                                        help: decision.selected ? "Selected: this date will be applied. Click to deselect."
                                            : "Select to apply this date (G or A). Shift-click selects a range.",
                                        action: onToggle)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Button(action: onOpen) {
                            Image(systemName: "info.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white, .black.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .help("Details and who’s in it")
                    }
                    .help("\(photo.filename) · now \(photo.libraryDate?.shortDay ?? "no date")")

                HStack(spacing: 5) {
                    SeasonIcon(season: estimate.season)
                    Text(estimate.displayString)
                        .font(.headline)
                        .lineLimit(1)
                    if overridden {
                        Image(systemName: "pencil").foregroundStyle(.secondary).help("You changed this guess")
                    }
                    Spacer(minLength: 4)
                    ConfidenceBadge(estimate: computed.estimate)
                }
                // On its own line, so the card's other details can't cut it off.
                if let batch = state.recoveryBatch(assetID) {
                    Label("Recovered \(batch.label)", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Its date in Photos is the day it was recovered, along with \((batch.count - 1).formatted()) others, not when it was taken")
                }
                HStack(spacing: 6) {
                    if let g = computed.groupName {
                        Label(g, systemImage: "square.stack").help("In the group “\(g)”")
                    }
                    Text(subtitle(computed))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                HStack(spacing: 4) {
                    YearComboBox(year: estimate.year, range: state.lowestYear...YearBounds.currentYear()) {
                        state.setOverride(assetID, year: $0, season: decision.overrideSeason)
                    }
                    .help("Type a year, or pick one from the list")
                    Menu {
                        Section("Season") {
                            ForEach(Season.allCases) { s in
                                Button {
                                    state.setOverride(assetID, year: decision.overrideYear, season: s)
                                } label: {
                                    Label("\(s.displayName) (\(DateEstimate.monthNames[s.representativeMonth - 1]))", systemImage: s.symbolName)
                                }
                            }
                        }
                        Section("Month") {
                            ForEach(1...12, id: \.self) { m in
                                Button(DateEstimate.monthNames[m - 1]) { state.setMonth(assetID, m) }
                            }
                        }
                        if overridden {
                            Divider()
                            Button("Use the Original Guess") { state.setOverride(assetID, year: nil, season: nil) }
                        }
                    } label: {
                        // Shows the exact month when there is one, otherwise the season.
                        Text(estimate.usedExactMonth ? DateEstimate.monthNames[max(1, min(12, estimate.month)) - 1] : estimate.seasonIsDefault ? "Season" : estimate.season.displayName)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Change the season or the exact month")
                    Spacer(minLength: 0)
                    Button { showWhy = true } label: {
                        Image(systemName: "questionmark.bubble")
                    }
                    .buttonStyle(.borderless)
                    .help("Why this date?")
                    .popover(isPresented: _showWhy.projectedValue, arrowEdge: .bottom) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Why \(estimate.displayString)?").font(.headline)
                                Text("Most likely \(computed.estimate.rangeText) · about \(Int(computed.estimate.confidence * 100))% confident within ±2 years")
                                    .font(.caption).foregroundStyle(.secondary)
                                EvidenceList(evidence: computed.evidence)
                            }
                            .padding(16)
                        }
                        .frame(width: 420, height: 380)
                    }
                }
                .controlSize(.small)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .opacity(decision.ignored ? 0.5 : 1)
            .contextMenu {
                let ids = state.reviewMenuIDs(assetID)
                PhotoMenu(
                    count: ids.count,
                    isSelected: decision.selected, select: { state.setSelected(assetID, $0) },
                    getInfo: onOpen, infoTitle: "Details & Who’s in It…",
                    showInPhotos: { Task { await state.showInPhotos(assetID) } },
                    setDate: { state.photoInfoRequest = PhotoInfoRequest(ids: ids, kind: .date, startDate: state.effectiveEstimate(assetID)?.date()) },
                    setLocation: { state.photoInfoRequest = PhotoInfoRequest(ids: ids, kind: .location) },
                    rotate: onRotate, rotateDisabled: state.isRotating,
                    hide: decision.ignored
                        ? PhotoMenu.Item("Show Again  N") { state.setIgnored(assetID, false) }
                        : PhotoMenu.Item("Don’t Show Again  N") { state.setIgnored(assetID, true) })
            }
        }
    }

    private func subtitle(_ c: ComputedEstimate) -> String {
        let e = c.estimate
        if !e.hasAnyEvidence { return "No clues found — please set the year yourself" }
        if e.onlyLimits {
            let hard = c.evidence.filter(\.isHardConstraint)
            let lo = hard.compactMap(\.yearLow).max(), hi = hard.compactMap(\.yearHigh).min()
            let span = switch (lo, hi) {
            case let (lo?, hi?): "\(lo)–\(hi)"
            case let (lo?, nil): "\(lo) or later"
            case let (nil, hi?): "\(hi) or earlier"
            default: e.rangeText
            }
            return "No real clues, only \(span) · set the year if you know it"
        }
        let used = c.evidence.filter { $0.hasYearInfo }.count
        var text = "Likely \(e.rangeText) · \(used) clue\(used == 1 ? "" : "s")"
        if e.seasonIsDefault { text += " · season unknown" }
        return text
    }
}

struct PhotoDetailSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var assetID: String

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            FacePreview(assetID: assetID, maxSide: 520)
                .onRotateKey { state.rotate([assetID]); return true }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let estimate = state.effectiveEstimate(assetID), let computed = state.estimates[assetID] {
                        HStack {
                            SeasonIcon(season: estimate.season)
                            Text(estimate.displayString).font(.title.weight(.semibold))
                            ConfidenceBadge(estimate: computed.estimate)
                        }
                        Text("Likely between \(computed.estimate.rangeText)").foregroundStyle(.secondary)
                    }
                    if let photo = state.photo(assetID) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(photo.filename).font(.headline)
                            Text("Currently dated: \(photo.libraryDate?.formatted(date: .long, time: .shortened) ?? "no date")")
                            Text(photo.reason.explanation)
                            if !photo.albums.isEmpty { Text("Albums: \(photo.albums.joined(separator: ", "))") }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Divider()
                    PhotoPeopleEditor(assetID: assetID)
                    SameEventStrip(assetID: assetID)
                    Divider()
                    EvidenceList(evidence: state.estimates[assetID]?.evidence ?? [])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 1000, height: 620)
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(16)
        }
    }
}

/// Who's in this photo according to Photos' name tags, and how old they look. Names are added in
/// Photos itself; here you can fill in a missing birth year or an age.
struct PhotoPeopleEditor: View {
    @Environment(AppState.self) private var state
    var assetID: String

    var body: some View {
        let hints = state.people(in: assetID)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Who’s in this photo?").font(.headline)
                Spacer()
                ShowInPhotosButton(assetID: assetID)
            }
            if hints.isEmpty {
                Text("Nobody here is named in Photos yet. Click Show in Photos and name them there; they show up here when you come back. Their birth year, and how old they look, date the photo.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(hints) { hint in
                if let person = state.people.first(where: { $0.id == hint.personID }) {
                    row(person, hint, hints)
                }
            }
        }
    }

    private func row(_ person: PersonInfo, _ hint: GroupPersonHint, _ hints: [GroupPersonHint]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(Theme.accent)
            Text(person.name.isEmpty ? "Unnamed" : person.name).fontWeight(.medium)
            if person.birthYear == nil {
                Text("born").foregroundStyle(.secondary)
                NumberField(title: "year", value: birthYear(person.id), range: 1850...YearBounds.currentYear(), width: 60)
                    .help("Needed before this person can date photos")
            } else {
                Text("looks about").foregroundStyle(.secondary)
                NumberField(title: "age", value: Binding(
                    get: { hint.approximateAge },
                    set: { age in
                        state.setPhotoPeople(assetID, hints.map { h in
                            var h = h
                            if h.personID == hint.personID { h.approximateAge = age }
                            return h
                        })
                    }), range: 0...110, width: 50)
                Text("years old").foregroundStyle(.secondary)
            }
            Spacer()
            if !hint.fromPhotos {
                // Added by hand in an earlier version of the app.
                Button {
                    state.setPhotoPeople(assetID, hints.filter { $0.personID != hint.personID })
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove from this photo (wasn’t tagged in Photos)")
            }
        }
    }

    private func birthYear(_ id: UUID) -> Binding<Int?> {
        Binding(
            get: { state.people.first { $0.id == id }?.birthYear },
            set: { year in state.updateBirthday(id) { $0.birthYear = year } })
    }
}

/// Undated photos that look like they're from the same event, with a way to date them all at once.
struct SameEventStrip: View {
    @Environment(AppState.self) private var state
    var assetID: String
    var _editing = State<EventDraft?>(initialValue: nil)
    private var editing: EventDraft? { get { _editing.wrappedValue } nonmutating set { _editing.wrappedValue = newValue } }

    var body: some View {
        let suggestion = state.eventSuggestion(containing: assetID) ?? []
        let links = state.estimates[assetID]?.matches ?? []
        var seen = Set([assetID])
        let matches = (suggestion + links).filter { seen.insert($0).inserted }
        let group = state.groupFor(assetID)
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Same event").font(.headline)
                Spacer()
                if group?.kind != .sameEvent {
                    Button {
                        editing = EventDraft(ids: [assetID] + matches)
                    } label: {
                        Label("Date This Event…", systemImage: "calendar.badge.plus")
                    }
                    .help("Pick the photos from the same event and give them all one date")
                } else if let group {
                    Text("In the event “\(group.name)”").foregroundStyle(.secondary)
                }
            }
            if matches.isEmpty {
                Text("No look-alikes found yet. Date This Event lets you look for more from the same day.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("These look like they’re from the same day or occasion, even if they were scanned at different times.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ThumbnailStrip {
                    HStack(spacing: 6) {
                        ForEach(matches, id: \.self) { id in
                            VStack(spacing: 2) {
                                AssetThumbnail(assetID: id, side: 72)
                                Text(state.effectiveEstimate(id)?.displayString ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 72)
                        }
                    }
                }
            }
        }
        .sheet(item: _editing.projectedValue) { draft in
            EventEditor(seed: draft.ids)
        }
    }
}

/// One date for every selected photo, instead of setting each photo's own controls.
struct SetDateButton: View {
    var state: AppState
    /// The selected photos shown.
    var ids: [String]
    @State private var showing = false
    /// No season or month keeps each photo's own guessed season.
    @State private var choice = DateChoice(year: YearBounds.currentYear() - 30)

    var body: some View {
        Button {
            // Start from the year most of them are guessed at.
            let years = ids.compactMap { state.effectiveEstimate($0)?.year }
            let common = Dictionary(grouping: years, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key
            choice = DateChoice(year: common ?? choice.year)
            showing = true
        } label: {
            Label("Set Date", systemImage: "calendar.badge.clock")
        }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(ids.isEmpty)
        .help(ids.isEmpty ? "Select photos first, then give them all one date (⌘D)"
              : "Give the \(ids.count.formatted()) selected photos one date (⌘D)")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DatePickerPanel(title: DatePickerPanel.title(ids.count), choice: $choice,
                            range: state.lowestYear...YearBounds.currentYear(), keepSeason: true,
                            note: "Nothing changes in Photos until you apply it.",
                            confirm: "Set Date", onCancel: { showing = false }) {
                state.setDate(ids, year: choice.year, season: choice.season, month: choice.month)
                showing = false
            }
        }
    }
}
