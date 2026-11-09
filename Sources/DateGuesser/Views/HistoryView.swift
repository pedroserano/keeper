import SwiftUI
import KeeperUI
import DateGuessCore

struct HistoryView: View {
    /// Dates' History or Places' History: each section of the sidebar has its own.
    enum Kind { case dates, places }
    var kind: Kind = .dates
    @Environment(\.showShortcuts) private var showShortcuts
    @Environment(AppState.self) private var state
    var _batchToUndo = State<ApplyBatch?>(initialValue: nil)
    private var batchToUndo: ApplyBatch? { get { _batchToUndo.wrappedValue } nonmutating set { _batchToUndo.wrappedValue = newValue } }
    @State private var placesToUndo: PlaceBatch?

    /// Photos this app dated that were moved in Photos since, grouped by how far they moved.
    private var shiftedSection: some View {
        let groups = Dictionary(grouping: state.dateShifts, by: \.days)
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        return Section {
            Text("Image ▸ Adjust Date and Time in Photos moves every selected photo by the same amount, so photos with different dates stay different. Set Date gives every photo in a group the same exact date.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(groups, id: \.key) { days, shifts in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(shifts.count.formatted()) moved \(Self.amount(days))").font(.headline)
                        Text(Self.range(shifts)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Keep") { state.keepShiftedDates(shifts) }
                            .help("Keep the dates they have now, and don’t list them again")
                        SetShiftedDateButton(state: state, shifts: shifts)
                    }
                    ThumbnailStrip {
                        LazyHStack(spacing: 6) {
                            ForEach(shifts.prefix(30)) { s in
                                VStack(spacing: 2) {
                                    AssetThumbnail(assetID: s.assetID, side: 64)
                                        .zoomable(s.assetID, in: shifts.map(\.assetID))
                                    Text(s.current.formatted(.dateTime.month(.abbreviated).year()))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .help("This app set \(s.appDate.formatted(date: .abbreviated, time: .omitted)); now \(s.current.formatted(date: .abbreviated, time: .omitted))")
                            }
                            if shifts.count > 30 {
                                Text("+\((shifts.count - 30).formatted())").foregroundStyle(.secondary).frame(width: 50)
                            }
                        }
                    }
                    .frame(height: 84)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label("Changed in Photos Since", systemImage: "calendar.badge.exclamationmark")
        }
    }

    /// "2 years earlier", "31 days later".
    static func amount(_ days: Int) -> String {
        let n = abs(days)
        let size: String
        if n >= 365, n % 365 <= 1 || n % 365 >= 364 {
            let years = Int((Double(n) / 365.25).rounded())
            size = years == 1 ? "1 year" : "\(years) years"
        } else if n == 0 {
            return "by less than a day"
        } else {
            size = n == 1 ? "1 day" : "\(n.formatted()) days"
        }
        return "\(size) \(days < 0 ? "earlier" : "later")"
    }

    static func range(_ shifts: [AppState.DateShift]) -> String {
        let dates = shifts.map(\.appDate)
        guard let a = dates.min(), let b = dates.max() else { return "" }
        let f = { (d: Date) in d.formatted(.dateTime.month(.abbreviated).year()) }
        return "· dated \(f(a) == f(b) ? f(a) : "\(f(a)) – \(f(b))") here"
    }

    /// Date and place changes together, newest first.
    private enum Item: Identifiable {
        case dates(ApplyBatch)
        case places(PlaceBatch)
        var id: UUID { switch self { case .dates(let b): b.id; case .places(let b): b.id } }
        var date: Date { switch self { case .dates(let b): b.date; case .places(let b): b.date } }
    }

    private var items: [Item] {
        switch kind {
        case .dates: state.journal.map(Item.dates).sorted { $0.date > $1.date }
        case .places: state.places.journal.map(Item.places).sorted { $0.date > $1.date }
        }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No Changes Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text(kind == .dates
                                                         ? "Each time you apply dates, the old ones are kept here so you can put them back."
                                                         : "Each time you apply places, the old ones are kept here so you can put them back."))
            } else {
                List {
                    if kind == .dates && !state.dateShifts.isEmpty { shiftedSection }
                    ForEach(items) { item in
                        switch item {
                        case .dates(let batch): dateSection(batch)
                        case .places(let batch): placeSection(batch)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { if kind == .dates { state.checkShiftedDates() } }
        .toolbar {
            if kind == .dates {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.checkShiftedDates()
                } label: {
                    Label("Check Dates", systemImage: "calendar.badge.exclamationmark")
                }
                .disabled(state.isCheckingShifts || state.journal.isEmpty)
                .help("Look for photos this app dated whose date was changed in Photos since")
            }
            }
            ToolbarItem(placement: .primaryAction) { ShortcutsToolbarButton(action: showShortcuts) }
        }

        .alert("Undo this change?", isPresented: Binding(get: { batchToUndo != nil }, set: { if !$0 { batchToUndo = nil } })) {
            Button("Restore Previous Dates") {
                if let batch = batchToUndo { state.undo(batch) }
                batchToUndo = nil
            }
            Button("Cancel", role: .cancel) { batchToUndo = nil }
        } message: {
            Text("The \(batchToUndo?.entries.count ?? 0) photos will get back the dates they had before.")
        }
        .alert("Remove these locations?", isPresented: Binding(get: { placesToUndo != nil }, set: { if !$0 { placesToUndo = nil } })) {
            Button("Remove Locations") {
                if let batch = placesToUndo { state.places.undo(batch) }
                placesToUndo = nil
            }
            Button("Cancel", role: .cancel) { placesToUndo = nil }
        } message: {
            Text("The \(placesToUndo?.entries.count ?? 0) photos will go back to having no location.")
        }
    }

    private func placeSection(_ batch: PlaceBatch) -> some View {
        Section {
            ThumbnailStrip {
                LazyHStack(spacing: 6) {
                    ForEach(batch.entries.prefix(30), id: \.assetID) { entry in
                        VStack(spacing: 2) {
                            AssetThumbnail(assetID: entry.assetID, side: 64)
                            PlaceLabel(point: entry.new, name: entry.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 64)
                    }
                }
            }
            .frame(height: 84)
            if !batch.failures.isEmpty {
                DisclosureGroup("\(batch.failures.count) couldn’t be changed") {
                    ForEach(batch.failures.keys.sorted().prefix(50), id: \.self) { id in
                        Text("\(id): \(batch.failures[id] ?? "")").font(.caption)
                    }
                }
            }
        } header: {
            HStack {
                Label(batch.date.formatted(date: .long, time: .shortened), systemImage: "mappin.and.ellipse")
                Text("· \(batch.entries.count.formatted()) locations" + (batch.undone ? " · undone" : ""))
                    .foregroundStyle(.secondary)
                Spacer()
                if !batch.undone {
                    Button("Undo…") { placesToUndo = batch }
                        .disabled(state.places.isApplying)
                }
            }
        }
    }

    private func dateSection(_ batch: ApplyBatch) -> some View {
                        Section {
                            ThumbnailStrip {
                                LazyHStack(spacing: 6) {
                                    ForEach(batch.entries.prefix(30), id: \.assetID) { entry in
                                        VStack(spacing: 2) {
                                            AssetThumbnail(assetID: entry.assetID, side: 64)
                                            Text(entry.newDate.formatted(.dateTime.month(.abbreviated).year()))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .frame(height: 84)
                            if !batch.failures.isEmpty {
                                DisclosureGroup("\(batch.failures.count) couldn’t be changed") {
                                    ForEach(batch.failures.keys.sorted().prefix(50), id: \.self) { id in
                                        Text("\(state.photo(id)?.filename ?? id): \(batch.failures[id] ?? "")")
                                            .font(.caption)
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(batch.date.formatted(date: .long, time: .shortened))
                                Text("· \(batch.entries.count.formatted()) photos" + (batch.undone ? " · undone"
                                     : (batch.undoneIDs?.isEmpty == false ? " · \(batch.undoneIDs!.count) put back" : "")))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !batch.undone {
                                    Button("Undo…") { batchToUndo = batch }
                                        .disabled(state.isApplying)
                                }
                            }
                        }
    }
}

/// One exact date, written to Photos, for a group of photos whose dates were shifted there.
private struct SetShiftedDateButton: View {
    var state: AppState
    var shifts: [AppState.DateShift]
    @State private var showing = false
    @State private var year = YearBounds.currentYear() - 30
    @State private var month = 1

    var body: some View {
        Button("Set Date…") {
            // Start from the date this app gave most of them.
            let calendar = Calendar.current
            let pairs = shifts.map { (calendar.component(.year, from: $0.appDate), calendar.component(.month, from: $0.appDate)) }
            if let top = Dictionary(grouping: pairs, by: { $0.0 * 12 + $0.1 }).max(by: { $0.value.count < $1.value.count })?.value.first {
                year = top.0
                month = top.1
            }
            showing = true
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.isApplying)
        .help("Give all of them one exact date in Photos")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Form {
                LabeledContent("Year") {
                    YearComboBox(year: year, range: state.lowestYear...YearBounds.currentYear()) { year = $0 }
                        .frame(width: 90)
                }
                Picker("Month", selection: $month) {
                    ForEach(1...12, id: \.self) { m in Text(DateEstimate.monthNames[m - 1]).tag(m) }
                }
                Text("Every one of the \(shifts.count.formatted()) photos gets \(DateEstimate.monthNames[month - 1]) 1, \(String(year)) in Photos. You can undo this from History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.grouped)
            .frame(width: 340)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button("Cancel") { showing = false }
                        .keyboardShortcut(.cancelAction)
                    Button(shifts.count == 1 ? "Set Date in Photos" : "Set Date for \(shifts.count.formatted()) Photos") {
                        state.setDateInPhotos(shifts, year: year, month: month)
                        showing = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .padding([.horizontal, .bottom], 16)
            }
        }
    }
}
