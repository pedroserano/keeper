import AppKit
import SwiftUI
import KeeperUI
import UniformTypeIdentifiers
import DateGuessCore

/// One list of everyone, edited in place. The people who appear in the most undated photos come
/// first, so filling in the top few birth years helps the most.
struct PeopleView: View {
    @Environment(\.showShortcuts) private var showShortcuts
    @Environment(AppState.self) private var state
    var _search = State<String>(initialValue: "")
    private var search: String { get { _search.wrappedValue } nonmutating set { _search.wrappedValue = newValue } }
    var _onlyMissing = State<Bool>(initialValue: false)
    private var onlyMissing: Bool { get { _onlyMissing.wrappedValue } nonmutating set { _onlyMissing.wrappedValue = newValue } }

    struct Counts { var tagged = 0; var undated = 0 }

    var body: some View {
        let counts = personCounts
        let rows = visiblePeople(counts)
        Group {
            if state.people.isEmpty {
                ContentUnavailableView {
                    Label("No People Yet", systemImage: "person.2")
                } description: {
                    Text("Bring in the people you’ve named in Photos. With a birth year, every photo of them can’t be from before they were born, and how old they look dates it.")
                } actions: {
                    if state.isImportingPeople {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Import from Photos") { importPeople() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Table(rows) {
                    TableColumn("Name") { person in
                        PersonNameCell(state: state, person: person, counts: counts[person.id] ?? Counts())
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn("Undated") { person in
                        Text((counts[person.id]?.undated ?? 0).formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(60)
                    TableColumn("Born") { person in
                        PersonBirthdayCell(state: state, personID: person.id)
                    }
                    .width(min: 240, ideal: 260)
                }
                .overlay {
                    if rows.isEmpty { ContentUnavailableView.search(text: search) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    summary(counts)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
        }
        .searchable(text: _search.projectedValue, placement: .toolbar, prompt: "Search people")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: _onlyMissing.projectedValue) {
                    Label("Missing Birth Year", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Show only people without a birth year")
                .disabled(state.people.isEmpty)
                if canAskContacts {
                    Button {
                        Task { await state.fillBirthdaysFromContacts() }
                    } label: {
                        Label("Birthdays from Contacts", systemImage: "person.crop.circle.badge.clock")
                    }
                    .help("Fill in missing birth years from the contact cards your Photos people are linked to")
                }
                Menu {
                    Button("Choose a Different Library…") { chooseLibrary() }
                } label: {
                    Label("Update from Photos", systemImage: "arrow.triangle.2.circlepath")
                } primaryAction: {
                    importPeople()
                }
                .help(state.taggedPeople.isEmpty ? "Import the people you’ve named in Photos" : "Bring in new names and tags from Photos")
                .disabled(state.isImportingPeople)
                ShortcutsToolbarButton(action: showShortcuts)
            }
        }
    }

    private var canAskContacts: Bool {
        let linked = Set(state.taggedPeople.filter { $0.contactID != nil || $0.contactMatch != nil }.map(\.id))
        return state.people.contains { $0.birthYear == nil && $0.photosPersonID.map(linked.contains) == true }
    }

    private func summary(_ counts: [UUID: Counts]) -> some View {
        let helped = Self.helped(people: state.people, undatedByPerson: undatedByPerson)
        let withYear = state.people.filter { $0.birthYear != nil }.count
        var text = "\(state.people.count) people · \(withYear) with a birth year · birth years help date \(helped.now.formatted()) of \(state.scan.undated.count.formatted()) undated photos"
        if helped.more > 0 {
            text += " · adding the top \(helped.top) missing would help \(helped.more.formatted()) more"
        }
        return Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(text)
    }

    /// Each person's undated photos (tags from Photos plus photos the user marked).
    private var undatedByPerson: [UUID: Set<String>] {
        var out: [UUID: Set<String>] = [:]
        for (id, assets) in state.taggedAssetsByPerson {
            out[id] = assets.filter { state.scan.undated[$0] != nil }
        }
        for (asset, hints) in state.photoPeople where state.scan.undated[asset] != nil {
            for h in hints { out[h.personID, default: []].insert(asset) }
        }
        return out
    }

    /// Undated photos a birth year already helps (each counted once), and how many more the `top`
    /// people without one would add.
    static func helped(people: [PersonInfo], undatedByPerson: [UUID: Set<String>], top: Int = 5)
        -> (now: Int, more: Int, top: Int) {
        var covered = Set<String>()
        for p in people where p.birthYear != nil { covered.formUnion(undatedByPerson[p.id] ?? []) }
        let missing = people.filter { $0.birthYear == nil }
            .map { undatedByPerson[$0.id] ?? [] }
            .sorted { $0.subtracting(covered).count > $1.subtracting(covered).count }
            .prefix(top)
        let more = missing.reduce(into: Set<String>()) { $0.formUnion($1) }.subtracting(covered).count
        return (covered.count, more, min(top, missing.count))
    }

    /// Tagged and undated photo counts per person (tags from Photos plus photos the user marked).
    private var personCounts: [UUID: Counts] {
        var out: [UUID: Counts] = [:]
        let tagged = state.taggedAssetsByPerson
        for (id, assets) in tagged {
            out[id] = Counts(tagged: assets.count, undated: assets.filter { state.scan.undated[$0] != nil }.count)
        }
        for (asset, hints) in state.photoPeople where state.scan.undated[asset] != nil {
            for h in hints where !(tagged[h.personID]?.contains(asset) ?? false) {
                out[h.personID, default: Counts()].undated += 1
                out[h.personID, default: Counts()].tagged += 1
            }
        }
        return out
    }

    /// The people in the most undated photos first, so filling in their birth years helps the most.
    private func visiblePeople(_ counts: [UUID: Counts]) -> [PersonInfo] {
        state.people
            .filter { p in
                (search.isEmpty || p.name.localizedCaseInsensitiveContains(search)) && (!onlyMissing || p.birthYear == nil)
            }
            .sorted { a, b in
                let ua = counts[a.id]?.undated ?? 0, ub = counts[b.id]?.undated ?? 0
                if ua != ub { return ua > ub }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// Uses the library chosen before; asks only the first time (or if it moved).
    private func importPeople() {
        if let url = state.savedLibraryURL, FileManager.default.fileExists(atPath: url.path) {
            state.importTaggedPeople(from: url)
        } else {
            chooseLibrary()
        }
    }

    private func chooseLibrary() { LibraryPicker.choose(state) }
}

/// Asks for the Photos library file, which the sandbox requires once before the app may read names
/// from it. The choice is remembered.
@MainActor
enum LibraryPicker {
    static func choose(_ state: AppState) {
        let panel = NSOpenPanel()
        panel.message = "Choose your Photos library (the file ending in “.photoslibrary”). You only do this once; it’s only read, never changed."
        panel.prompt = "Use This Library"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        if let type = UTType("com.apple.photos.library") { panel.allowedContentTypes = [type] }
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.importTaggedPeople(from: url)
    }
}

/// A person's picture, name, and what they're helping with.
struct PersonNameCell: View {
    /// Passed in rather than read from the environment: Table rows can be laid out before the
    /// environment reaches them, and reading a missing Observable from it crashes.
    var state: AppState
    var person: PersonInfo
    var counts: PeopleView.Counts

    var body: some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                if person.photosPersonID == nil {
                    // Added by hand in an earlier version of the app.
                    TextField("Name", text: Binding(
                        get: { person.name },
                        set: { name in
                            if let i = state.people.firstIndex(where: { $0.id == person.id }) { state.people[i].name = name }
                        }), prompt: Text("Name"))
                        .textFieldStyle(.plain)
                } else {
                    Text(person.name)
                        .help("Rename in Photos; the new name shows up here when you come back")
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(person.birthYear == nil && counts.undated > 0 ? .orange : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(person.photosPersonID == nil ? "Remove" : "Remove (Update from Photos Brings Them Back)", role: .destructive) {
                state.removePerson(person.id)
            }
        }
    }

    private var avatar: some View {
        Group {
            if let ref = person.referenceAssetIDs.first {
                AssetThumbnail(assetID: ref, side: 28, cornerRadius: 14)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var detail: String {
        var parts: [String] = []
        if person.birthdayFromContacts == true { parts.append("from Contacts") }
        if person.photosPersonID != nil { parts.append("in \(counts.tagged.formatted()) photos") }
        if person.birthYear == nil && counts.undated > 0 { parts.append("add a birth year to use") }
        if parts.isEmpty { return person.photosPersonID == nil ? "Not in Photos" : "" }
        return parts.joined(separator: " · ")
    }
}

/// Birth year, month and day, edited in place.
struct PersonBirthdayCell: View {
    /// Passed in rather than read from the environment: Table rows can be laid out before the
    /// environment reaches them, and reading a missing Observable from it crashes.
    var state: AppState
    var personID: UUID

    private var person: PersonInfo? { state.people.first { $0.id == personID } }

    var body: some View {
        if let person {
            HStack(spacing: 6) {
                NumberField(title: "Year", value: Binding(
                    get: { person.birthYear },
                    set: { year in state.updateBirthday(personID) { $0.birthYear = year } }),
                    range: 1850...YearBounds.currentYear(), width: 60)
                    .help(person.birthdayFromContacts == true ? "From their Contacts card" : "Birth year")
                Picker("Month", selection: Binding(
                    get: { person.birthMonth },
                    set: { month in state.updateBirthday(personID) { $0.birthMonth = month; if month == nil { $0.birthDay = nil } } })) {
                    Text("Month").tag(Int?.none)
                    ForEach(1...12, id: \.self) { m in
                        Text(DateEstimate.monthNames[m - 1]).tag(Int?.some(m))
                    }
                }
                .labelsHidden()
                .frame(width: 104)
                Picker("Day", selection: Binding(
                    get: { person.birthDay },
                    set: { day in state.updateBirthday(personID) { $0.birthDay = day } })) {
                    Text("Day").tag(Int?.none)
                    ForEach(1...31, id: \.self) { d in Text("\(d)").tag(Int?.some(d)) }
                }
                .labelsHidden()
                .frame(width: 64)
                .disabled(person.birthMonth == nil)
            }
            .controlSize(.small)
        }
    }
}
