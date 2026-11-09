import SwiftUI
import DateGuessCore
import KeeperUI

/// Events and groups in one place: likely events among undated photos (even when they were scanned
/// years apart), suggested groups, and the events and groups you've saved.
struct EventsView: View {
    @Environment(AppState.self) private var state
    @State private var editing: EventDraft?
    @State private var openGroup: IdentifiedUUID?
    @State private var showingNewGroup = false
    @State private var suggestions: [GroupSuggestion] = []
    @State var page: Page = .suggested
    @Environment(\.showShortcuts) private var showShortcuts
    /// Shown inside Undated Photos (its Events button) rather than from the sidebar: Show is then
    /// Undated's filters joined to Events, and Suggested or Confirmed sits beside it.
    var undated: Undated?

    struct Undated {
        var filter: Binding<ReviewView.Filter>
        var showEvents: Binding<Bool>
    }

    enum Page: String, CaseIterable, Identifiable {
        case suggested = "Suggested"
        case confirmed = "Confirmed"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            switch page {
            case .suggested: suggestedList
            case .confirmed: confirmedList
            }
        }
        .toolbar {
            KeeperToolbar(shortcuts: showShortcuts) {
                if let undated {
                    HStack(spacing: 8) {
                    ShowMenuWithView(selection: undated.filter, showView: undated.showEvents,
                                     title: "Events", systemImage: "square.stack", viewHelp: ReviewView.eventsHelp)
                    Picker("Events", selection: $page) {
                        ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Suggested events, or the events you confirmed")
                    }
                } else {
                    ShowMenu(selection: $page, help: "Suggested events, or the events you confirmed")
                }
            } action: {
                Button {
                    showingNewGroup = true
                } label: {
                    Label("New Group", systemImage: "plus")
                }
                .help("Gather photos you know go together, and say what you know about them")
                .disabled(state.undatedSorted.isEmpty)
            }
        }
        .onAppear { suggestions = state.groupSuggestions() }
        .onChange(of: state.groups) { _, _ in suggestions = state.groupSuggestions() }
        .modifier(EventDateConfirmations(state: state, active: openGroup == nil))
        .sheet(item: $editing) { draft in
            EventEditor(seed: draft.ids)
        }
        .sheet(item: $openGroup) { item in
            GroupSheet(groupID: item.id)
        }
        .sheet(isPresented: $showingNewGroup) {
            PhotoPickerSheet(groupID: nil) { id in openGroup = IdentifiedUUID(id: id) }
        }
    }

    /// Events you confirmed, each with one date you can change for all its photos at once.
    private var confirmedList: some View {
        let confirmed = state.groups.filter { $0.kind == .sameEvent }
        let others = state.groups.filter { $0.kind != .sameEvent }
        return List {
            Section {
                ForEach(confirmed) { g in
                    ConfirmedEventRow(state: state, group: g, onOpen: { openGroup = IdentifiedUUID(id: g.id) })
                        .contextMenu {
                            Button("Edit…") { openGroup = IdentifiedUUID(id: g.id) }
                            Button("Delete Event", role: .destructive) { state.groups.removeAll { $0.id == g.id } }
                        }
                }
            } header: {
                Text("Confirmed Events")
            } footer: {
                Text("Change an event’s year or month here and every photo in it gets the new date, selected for Apply. Photos you already applied keep their date.")
            }
            if !others.isEmpty {
                Section("Groups") {
                    ForEach(others) { g in
                        Button {
                            openGroup = IdentifiedUUID(id: g.id)
                        } label: {
                            GroupRow(state: state, group: g)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit…") { openGroup = IdentifiedUUID(id: g.id) }
                            Button("Delete", role: .destructive) { state.groups.removeAll { $0.id == g.id } }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if confirmed.isEmpty && others.isEmpty {
                ContentUnavailableView("No Confirmed Events", systemImage: "square.stack",
                                       description: Text("Click Same Event on a suggestion, and it shows up here."))
            }
        }
        .navigationSubtitle("\(confirmed.count.formatted()) confirmed")
    }

    private var suggestedList: some View {
        let events = state.eventSuggestions
        return List {
            if state.isFindingEvents {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(events.isEmpty
                         ? "Comparing your photos to find events. This takes a minute or two."
                         : "Updating events. These are from last time and may change.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if !events.isEmpty {
                Section {
                    ForEach(events.prefix(200), id: \.self) { ids in
                        EventCard(state: state, ids: ids, onOpen: { editing = EventDraft(ids: $0) })
                    }
                } header: {
                    Text("Suggested Events")
                } footer: {
                    Text("Click a photo (or press Space over it) to see it bigger. Click × to leave out one that doesn’t belong. Same Event gives them one shared date and selects them for Apply.")
                }
            }
            if !suggestions.isEmpty {
                Section("Suggested Groups") {
                    ForEach(suggestions.prefix(40)) { s in
                        HStack(spacing: 12) {
                            Thumbnails(ids: s.assetIDs, side: 44, limit: 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).lineLimit(1)
                                Text(s.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Make Group") {
                                let g = state.createGroup(name: s.title, assetIDs: s.assetIDs, kind: s.kind)
                                openGroup = IdentifiedUUID(id: g.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if events.isEmpty && suggestions.isEmpty && !state.isFindingEvents {
                ContentUnavailableView(state.isEstimating ? "Looking for Events…" : "No Suggestions", systemImage: "square.stack",
                                       description: Text(state.isEstimating
                                           ? "Events show up here once photos have been compared."
                                           : "Events you’ve confirmed are under Confirmed."))
            }
        }
        .navigationSubtitle(events.isEmpty ? "" : "\(events.count.formatted()) suggested")
    }
}

struct IdentifiedUUID: Identifiable {
    var id: UUID
}

struct EventDraft: Identifiable {
    var id: String { AppState.eventKey(ids) }
    var ids: [String]
}

/// A short row of thumbnails, with "+N" for the rest.
struct Thumbnails: View {
    @AppStorage(PhotoShapePicker.storageKey) private var wholePhotos = false
    var ids: [String]
    var side: CGFloat
    var limit: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ids.prefix(limit), id: \.self) { id in
                AssetThumbnail(assetID: id, side: side, wholePhoto: wholePhotos)
                    .zoomable(id, in: ids)
            }
            if ids.count > limit {
                Text("+\(ids.count - limit)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct EventCard: View {
    @AppStorage(PhotoShapePicker.storageKey) private var wholePhotos = false
    /// Passed in, not read from the environment (see PersonNameCell).
    var state: AppState
    var ids: [String]
    var onOpen: ([String]) -> Void
    /// Photos the user clicked to leave out of this event.
    @State private var excluded: Set<String> = []

    private var kept: [String] { ids.filter { !excluded.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(sharedGuess ?? "Event").font(.headline)
                    .help("The date all these photos get if you click Same Event, from all their clues together")
                Text("\(kept.count) photos").foregroundStyle(.secondary)
                Spacer()
                Button("Not One Event") { state.dismissEvent(ids) }
                    .buttonStyle(.borderless)
                Button("Date with Related Photos…") { onOpen(kept) }
                    .help("Give these a date, and look for more photos from the same event")
                Button("Same Event") {
                    state.saveEvent(kept, name: sharedGuess.map { "Event, \($0)" } ?? "Event (\(kept.count) photos)",
                                    year: nil, month: nil, season: nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(kept.count < 2)
                .help("They’ll share one date, worked out from all their clues together, and be selected for Apply")
            }
            ThumbnailStrip {
                HStack(spacing: 6) {
                    ForEach(ids.prefix(12), id: \.self) { id in
                        let out = excluded.contains(id)
                        AssetThumbnail(assetID: id, side: 80, showMarks: true, wholePhoto: wholePhotos)
                            .opacity(out ? 0.35 : 1)
                            .zoomable(id, in: ids)
                            .help("Click or press Space to see it bigger")
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    if out { excluded.remove(id) } else { excluded.insert(id) }
                                } label: {
                                    Image(systemName: out ? "plus.circle.fill" : "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white, out ? Theme.accent : .black.opacity(0.45))
                                        .shadow(radius: 1)
                                        .padding(3)
                                }
                                .buttonStyle(.plain)
                                .help(out ? "Left out. Click to put it back" : "Leave this one out")
                            }
                    }
                    if ids.count > 12 { Text("+\(ids.count - 12)").foregroundStyle(.secondary).padding(.horizontal, 6) }
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// The date this event gets if saved now, with every photo's clues pooled (e.g. "July 1979").
    /// Until that's computed, the most common of the photos' own guesses.
    private var sharedGuess: String? {
        if let combined = state.eventEstimates[AppState.eventKey(ids)] { return combined.displayString }
        let guesses = ids.compactMap { state.effectiveEstimate($0)?.displayString }
        return Dictionary(grouping: guesses, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
}

/// A confirmed event with its one date, which can be changed for all its photos at once.
struct ConfirmedEventRow: View {
    /// Passed in, not read from the environment (see PersonNameCell).
    var state: AppState
    var group: PhotoGroup
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Thumbnails(ids: group.assetIDs, side: 44, limit: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).lineLimit(1)
                        Text(EventDateControls.detail(state, group))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit the event or its photos")
            Spacer(minLength: 8)
            EventDateControls(state: state, group: group)
        }
        .controlSize(.small)
        .padding(.vertical, 4)
    }
}

/// One date for a whole confirmed event: pick the year and the season or month, then OK. Photos not
/// yet applied just get the new date; ones already dated in Photos are changed there after asking once
/// (undoable from History), and the menu can put back the dates they had before.
struct EventDateControls: View {
    var state: AppState
    var group: PhotoGroup
    /// The year and month being picked; nothing changes until OK.
    @State private var draft: PendingDate?

    struct PendingDate: Equatable { var year: Int; var month: Int?; var season: Season? }

    /// The event's date as shown: the most common among its photos.
    struct Shown { var year: Int; var month: Int?; var season: Season?; var text: String; var mixed: Bool }

    static func shown(_ state: AppState, _ group: PhotoGroup) -> Shown? {
        let estimates = state.openMembers(group).compactMap { state.effectiveEstimate($0) }
        let mixed = Set(estimates.map(\.displayString)).count > 1
        if let e = Dictionary(grouping: estimates, by: \.displayString).max(by: { $0.value.count < $1.value.count })?.value.first {
            return Shown(year: e.year, month: e.usedExactMonth ? e.month : nil, season: e.seasonIsDefault ? nil : e.season,
                         text: e.displayString, mixed: mixed)
        }
        let calendar = Calendar.current
        let pairs = state.datesInPhotos(group).values
            .map { (calendar.component(.year, from: $0), calendar.component(.month, from: $0)) }
        guard let top = Dictionary(grouping: pairs, by: { $0.0 * 12 + $0.1 }).max(by: { $0.value.count < $1.value.count })?.value.first
        else { return nil }
        return Shown(year: top.0, month: top.1, season: nil, text: "\(DateEstimate.monthNames[top.1 - 1]) \(top.0)",
                     mixed: Set(pairs.map { $0.0 * 12 + $0.1 }).count > 1)
    }

    static func detail(_ state: AppState, _ group: PhotoGroup) -> String {
        let open = state.openMembers(group).count, applied = state.appliedMembers(group).count
        let other = state.otherMembers(group).count
        let given = group.yearFrom != nil && group.yearFrom == group.yearTo
        var parts = ["\(group.assetIDs.count) photos"]
        if let shown = shown(state, group) { parts.append(shown.mixed ? "mostly \(shown.text)" : shown.text) }
        if open > 0 { parts.append(given ? "your date" : "shared guess") }
        if applied > 0 { parts.append(open == 0 && other == 0 ? "applied" : "\(applied) applied") }
        if other > 0 { parts.append(open == 0 && applied == 0 ? "dated in Photos" : "\(other) dated in Photos") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let open = state.openMembers(group)
        let applied = state.appliedMembers(group)
        /// Already dated in Photos: changing these asks first.
        let inPhotos = applied + state.otherMembers(group)
        let given = group.yearFrom != nil && group.yearFrom == group.yearTo
        HStack(spacing: 6) {
            if let shown = Self.shown(state, group) {
                let saved = PendingDate(year: shown.year, month: shown.month, season: shown.season)
                let current = draft ?? saved
                YearComboBox(year: current.year, range: state.lowestYear...YearBounds.currentYear(), reset: state.eventDateResets) { y in
                    draft = PendingDate(year: y, month: current.month, season: current.season)
                }
                .help("The year for every photo in this event")
                Menu {
                    Section("Season") {
                        ForEach(Season.allCases) { s in
                            Button {
                                draft = PendingDate(year: current.year, month: nil, season: s)
                            } label: {
                                Label(s.displayName, systemImage: s.symbolName)
                            }
                        }
                    }
                    Section("Month") {
                        ForEach(1...12, id: \.self) { m in
                            Button(DateEstimate.monthNames[m - 1]) {
                                draft = PendingDate(year: current.year, month: m, season: nil)
                            }
                        }
                    }
                    if given && !open.isEmpty {
                        Divider()
                        Button("Use the Shared Guess") { state.setEventDate(group.id, year: nil, month: nil, season: nil) }
                    }
                    if !applied.isEmpty {
                        Divider()
                        Button("Undo Applied Dates…") {
                            state.eventDateRequest = .init(groupID: group.id, count: applied.count, undo: true)
                        }
                    }
                } label: {
                    Text(current.month.map { DateEstimate.monthNames[max(1, min(12, $0)) - 1] } ?? current.season?.displayName ?? "Season")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("The season or month for every photo in this event")
                let changed = draft.map { $0 != saved } ?? false
                Button("OK") {
                    if let d = draft, d != saved { change(d, open: open, inPhotos: inPhotos) }
                    draft = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(!changed)
                .help(changed ? (inPhotos.isEmpty ? "Give every photo in this event this same date"
                                 : "Give every photo in this event this same date; you’ll be asked once before photos in Photos change")
                      : "Pick a year and a month or season, then click OK")
                Button {
                    draft = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Keep the date it has")
                .opacity(changed ? 1 : 0)
                .disabled(!changed)
            } else {
                Text("Photos not found").foregroundStyle(.secondary)
                    .help("Its photos are no longer in your Photos library")
            }
        }
        .disabled(state.isApplying)
    }

    private func change(_ p: PendingDate, open: [String], inPhotos: [String]) {
        // A year alone still means one date for every photo: the event's month.
        var p = p
        if p.month == nil && p.season == nil { p.month = state.eventShownMonth(group) }
        if !open.isEmpty { state.setEventDate(group.id, year: p.year, month: p.month, season: p.season) }
        if !inPhotos.isEmpty {
            state.eventDateRequest = .init(groupID: group.id, year: p.year, month: p.month, season: p.season, count: inPhotos.count)
        }
    }
}

/// Asks before an event's dates are changed or put back in Photos. Attached outside lists, since an
/// alert from inside a list row doesn't reliably appear.
struct EventDateConfirmations: ViewModifier {
    var state: AppState
    /// False while a sheet with its own confirmations is showing.
    var active = true

    func body(content: Content) -> some View {
        let request = active ? state.eventDateRequest : nil
        content.alert(title(request), isPresented: Binding(
            get: { request != nil },
            set: { shown in
                // Dismissed without a choice (Escape): treat as Cancel.
                if !shown, state.eventDateRequest != nil { cancel() }
            })) {
            if let r = request {
                Button(r.undo ? "Undo Applied Dates" : "Change in Photos") {
                    state.eventDateRequest = nil
                    if r.undo {
                        state.undoAppliedDates(r.groupID)
                    } else {
                        state.changeAppliedDates(r.groupID, year: r.year, month: r.month, season: r.season)
                    }
                }
            }
            Button("Cancel", role: .cancel) { cancel() }
        } message: {
            Text(request?.undo == true
                 ? "Each photo gets back the date it had before this app changed it. Photos whose date you changed in Photos yourself are left alone."
                 : "They’re already dated in your Photos library, so this changes them there. You can undo it from History.")
        }
    }

    private func cancel() {
        state.eventDateRequest = nil
        state.eventDateResets += 1
    }

    private func title(_ r: AppState.EventDateRequest?) -> String {
        guard let r else { return "" }
        if r.undo { return "Put back the earlier dates of \(r.count) photos?" }
        let when = r.month.map { "\(DateEstimate.monthNames[$0 - 1]) \(r.year)" } ?? r.season.map { "\($0.displayName) \(r.year)" } ?? String(r.year)
        return "Change the date of \(r.count) photos in Photos to \(when)?"
    }
}

/// A saved event or group in the list.
struct GroupRow: View {
    /// Passed in, not read from the environment (see PersonNameCell).
    var state: AppState
    var group: PhotoGroup

    var body: some View {
        HStack(spacing: 12) {
            Thumbnails(ids: group.assetIDs, side: 44, limit: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts = ["\(group.assetIDs.count) photos", group.kind == .sameEvent ? "one event" : "same era"]
        if let first = group.assetIDs.first, group.kind == .sameEvent, let e = state.effectiveEstimate(first) {
            parts.append(e.displayString)
        }
        if !group.hint.isEmpty { parts.append(group.hint) }
        return parts.joined(separator: " · ")
    }
}

/// Everything about one saved event or group: what you know, and its photos.
struct GroupSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var groupID: UUID
    @State private var selected: Set<String> = []
    @State private var adding = false

    var body: some View {
        let group = state.groups.first { $0.id == groupID }
        VStack(spacing: 0) {
            if let group {
                HStack(spacing: 0) {
                    GroupEditor(groupID: groupID)
                        .frame(width: 370)
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("\(group.assetIDs.count) photos").font(.headline)
                            Spacer()
                            if !selected.isEmpty {
                                Button("Remove \(selected.count) from Group") {
                                    state.remove(Array(selected), from: groupID)
                                    selected.removeAll()
                                }
                            }
                            Button("Add Photos…") { adding = true }
                        }
                        .padding(12)
                        ScrollView {
                            PhotoGrid(ids: group.assetIDs, selected: $selected)
                                .padding(12)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Button("Delete Group", role: .destructive) {
                    state.groups.removeAll { $0.id == groupID }
                    dismiss()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 900, height: 600)
        .photoZoomHost(scope: "group")
        .modifier(EventDateConfirmations(state: state, active: !adding))
        .sheet(isPresented: $adding) {
            PhotoPickerSheet(groupID: groupID) { _ in }
        }
    }
}

/// A grid of photos; click to select. Shows every photo, including ones already dated here (a rescan
/// leaves those out of the undated list, but they're still in their events).
struct PhotoGrid: View {
    @Environment(AppState.self) private var state
    var ids: [String]
    @Binding var selected: Set<String>

    var body: some View {
        let applied = state.appliedIDs
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 10)], spacing: 10) {
            ForEach(ids, id: \.self) { id in
                GroupPhotoCell(assetID: id, photo: state.photo(id), isSelected: selected.contains(id),
                               applied: applied.contains(id))
                    .zoomable(id, in: ids, openOnClick: false)
                    .onTapGesture {
                        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                    }
            }
        }
        // R turns the selected photos.
        .onRotateKey {
            let chosen = ids.filter(selected.contains)
            guard !chosen.isEmpty else { return false }
            state.rotate(chosen)
            return true
        }
    }
}

/// Pick undated photos for a new group, or to add to an existing one.
struct PhotoPickerSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    /// Nil makes a new group.
    var groupID: UUID?
    var onCreate: (UUID) -> Void
    @State private var selected: Set<String> = []
    @State private var name = ""
    @State private var onlyUngrouped = true
    @State private var search = ""

    private var photos: [String] {
        let grouped = Set(state.groups.flatMap(\.assetIDs))
        let current = Set(state.groups.first { $0.id == groupID }?.assetIDs ?? [])
        return state.undatedSorted.filter { p in
            if current.contains(p.id) { return false }
            if onlyUngrouped && grouped.contains(p.id) { return false }
            if search.isEmpty { return true }
            return p.filename.localizedCaseInsensitiveContains(search)
                || p.albums.contains { $0.localizedCaseInsensitiveContains(search) }
        }
        .map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if groupID == nil {
                TextField("Group name", text: $name, prompt: Text("Name, e.g. Grandma’s 80th birthday"))
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
            } else {
                Text("Add Photos").font(.title2.weight(.semibold))
            }
            HStack {
                TextField("Search filenames or albums", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle("Only photos not in a group", isOn: $onlyUngrouped)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Select All") { selected.formUnion(photos) }
            }
            ScrollView {
                PhotoGrid(ids: photos, selected: $selected)
            }
            .overlay {
                if photos.isEmpty { ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle") }
            }
            HStack {
                Text("\(selected.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button(groupID == nil ? "Create Group" : "Add \(selected.count)") {
                    let ids = state.undatedSorted.map(\.id).filter { selected.contains($0) }
                    if let groupID {
                        state.add(ids, to: groupID)
                    } else {
                        let g = state.createGroup(name: name.isEmpty ? "New group" : name, assetIDs: ids)
                        onCreate(g.id)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 780, height: 600)
        .photoZoomHost(scope: "picker")
    }
}

struct GroupPhotoCell: View {
    @AppStorage(PhotoShapePicker.storageKey) private var wholePhotos = false
    var assetID: String
    var photo: UndatedPhoto?
    var isSelected: Bool
    var applied = false

    var body: some View {
        AssetThumbnail(assetID: assetID, side: 120, height: 100, showMarks: true, wholePhoto: wholePhotos)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : .white, isSelected ? .white : .clear)
                    .shadow(radius: 2)
                    .padding(5)
            }
            .overlay(alignment: .topLeading) {
                if applied {
                    Label("Applied", systemImage: "checkmark.seal.fill")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .padding(5)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 3)
            )
            .contentShape(Rectangle())
            .help(help)
    }

    private var help: String {
        guard let photo else { return applied ? "Already dated with this app" : "" }
        return photo.albums.isEmpty ? photo.filename : "\(photo.filename)\nAlbums: \(photo.albums.joined(separator: ", "))"
    }
}

/// Edits everything the user knows about one group.
struct GroupEditor: View {
    @Environment(AppState.self) private var state
    var groupID: UUID

    /// Binds by ID (not index) so deleting or reordering groups can't point at the wrong one.
    private var groupBinding: Binding<PhotoGroup>? {
        guard let current = state.groups.first(where: { $0.id == groupID }) else { return nil }
        let state = self.state, id = groupID
        return Binding(
            get: { state.groups.first { $0.id == id } ?? current },
            set: { new in
                if let i = state.groups.firstIndex(where: { $0.id == id }) { state.groups[i] = new }
            })
    }

    var body: some View {
        if let group = groupBinding {
            Form {
                Section {
                    TextField("Name", text: group.name)
                    Picker("These photos are from", selection: group.kind) {
                        ForEach(GroupKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                }
                if group.wrappedValue.kind == .sameEvent {
                    Section {
                        LabeledContent("Date") {
                            EventDateControls(state: state, group: group.wrappedValue)
                        }
                        TextField("Notes", text: group.hint, prompt: Text("e.g. At the lake"), axis: .vertical)
                            .lineLimit(1...3)
                    } header: {
                        Text("When")
                    } footer: {
                        Text("Every photo in the event gets this date. Ones already applied are changed in Photos after asking.")
                    }
                } else {
                    Section("What you know") {
                        TextField("Notes", text: group.hint, prompt: Text("e.g. Lake Tahoe trip, late 70s"), axis: .vertical)
                            .lineLimit(1...3)
                        LabeledContent("Years") {
                            HStack {
                                NumberField(title: "From", value: group.yearFrom, range: YearBounds.earliestPhotoYear...YearBounds.currentYear())
                                Text("to")
                                NumberField(title: "To", value: group.yearTo, range: YearBounds.earliestPhotoYear...YearBounds.currentYear())
                            }
                        }
                        Picker("Season", selection: group.season) {
                            Text("Unknown").tag(Season?.none)
                            ForEach(Season.allCases) { s in
                                Label(s.displayName, systemImage: s.symbolName).tag(Season?.some(s))
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// Confirm which photos belong to an event, add ones it may have missed, and date it once.
struct EventEditor: View {
    @AppStorage(PhotoShapePicker.storageKey) private var wholePhotos = false
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var seed: [String]

    @State private var included: Set<String> = []
    @State private var candidates: [String] = []
    @State private var name = ""
    @State private var year: Int?
    @State private var month: Int?
    @State private var season: Season?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Event name", text: $name, prompt: Text("Name, e.g. Lake Tahoe trip"))
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                Spacer()
                Text("\(included.count) photos").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("In this event. Click ✓ to leave one out, or the photo to see it bigger.").font(.headline)
                    grid(seed + candidates.filter { included.contains($0) })
                    if !candidates.isEmpty {
                        Text("Might also be from this event. Click + to add.").font(.headline)
                        grid(candidates.filter { !included.contains($0) })
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("When was it?").font(.headline)
                NumberField(title: "Year", value: $year, range: state.lowestYear...YearBounds.currentYear(), width: 70)
                Picker("Month", selection: $month) {
                    Text("Month unknown").tag(Int?.none)
                    ForEach(1...12, id: \.self) { m in Text(DateEstimate.monthNames[m - 1]).tag(Int?.some(m)) }
                }
                .labelsHidden()
                .fixedSize()
                if month == nil {
                    Picker("Season", selection: $season) {
                        Text("Season unknown").tag(Season?.none)
                        ForEach(Season.allCases) { s in Text(s.displayName).tag(Season?.some(s)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Event") {
                    let ids = state.undatedSorted.map(\.id).filter { included.contains($0) }
                    state.saveEvent(ids, name: name.isEmpty ? "Event (\(ids.count) photos)" : name,
                                    year: year, month: month, season: season)
                    state.banner = year == nil
                        ? "Saved \(ids.count) photos as one event with one shared date, and selected them in Review."
                        : "Dated \(ids.count) photos together and selected them in Review, ready to apply."
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(included.count < 2)
            }
            Text(year == nil ? "Without a year, the photos still get one shared guess from all their clues combined." : "Every photo in the event gets this date and is selected in Review. Nothing changes in Photos until you click Apply there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 780, height: 620)
        .photoZoomHost(scope: "editor")
        .onAppear {
            included = Set(seed)
            candidates = state.eventCandidates(for: seed)
            // Start from the current shared guess, so often only a tweak is needed.
            let guesses = seed.compactMap { state.effectiveEstimate($0) }
            if let common = Dictionary(grouping: guesses, by: \.year).max(by: { $0.value.count < $1.value.count }) {
                year = common.key
                let seasons = common.value.filter { !$0.seasonIsDefault }.map(\.season)
                season = Dictionary(grouping: seasons, by: { $0 }).max { $0.value.count < $1.value.count }?.key
            }
        }
    }

    private func grid(_ ids: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 130), spacing: 8)], spacing: 8) {
            ForEach(ids, id: \.self) { id in
                let on = included.contains(id)
                AssetThumbnail(assetID: id, side: 104, showMarks: true, wholePhoto: wholePhotos)
                    .opacity(on ? 1 : 0.6)
                    .zoomable(id, in: ids)
                    .help((state.effectiveEstimate(id)?.displayString).map { "\($0) · click or press Space to see it bigger" }
                          ?? "Click or press Space to see it bigger")
                    .overlay(alignment: .topTrailing) {
                        Button {
                            if on { included.remove(id) } else { included.insert(id) }
                        } label: {
                            Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                                .font(.title3)
                                .foregroundStyle(on ? Theme.accent : .white)
                                .shadow(radius: 2)
                                .padding(5)
                        }
                        .buttonStyle(.plain)
                        .help(on ? "In this event. Click to leave it out" : "Click to add it to this event")
                    }
            }
        }
    }
}
