import SwiftUI
import DateGuessCore

/// The toolbar's Scan button. Once the app has dated photos, its menu can include them again.
struct ScanButton: View {
    @Environment(AppState.self) private var state
    /// A scan waiting for "Scan Again?" to be confirmed: true includes photos dated here.
    @State private var confirming: Bool?

    var body: some View {
        let title = state.scan.lastScan == nil ? "Scan Library" : "Scan Again"
        Group {
            if state.appliedIDs.isEmpty {
                Button {
                    scan(includeApplied: false)
                } label: {
                    Label(title, systemImage: "magnifyingglass")
                }
            } else {
                Menu {
                    Button("Scan Again, Including Photos I Dated Here") { scan(includeApplied: true) }
                } label: {
                    Label(title, systemImage: "magnifyingglass")
                } primaryAction: {
                    scan(includeApplied: false)
                }
            }
        }
        .disabled(state.isScanning)
        .help("Look through your library for photos without a real date. Photos you already dated here are skipped.")
        .alert(confirming == true ? "Scan again, including photos you dated here?" : "Scan the library again?",
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Scan Again") {
                let include = confirming == true
                confirming = nil
                state.startScan(includeApplied: include)
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("It looks through every photo again and runs in the background. Your guesses, choices and history are kept.")
        }
    }

    /// The first scan starts straight away; later ones ask first.
    private func scan(includeApplied: Bool) {
        if state.scan.lastScan == nil { state.startScan(includeApplied: includeApplied) } else { confirming = includeApplied }
    }
}

/// What the last scan found, by reason.
struct ScanSummary: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let last = state.scan.lastScan {
                Text("\(state.undatedSorted.count.formatted()) photos need a date").font(.headline)
                Text("Checked \(state.scan.totalAssets.formatted()) photos on \(last.formatted(date: .abbreviated, time: .shortened))."
                     + (state.appliedIDs.isEmpty ? "" : " \(state.appliedIDs.count.formatted()) you already dated here are skipped."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                let counts = Dictionary(grouping: state.undatedSorted, by: \.reason).mapValues(\.count)
                ForEach(UndatedReason.allCases, id: \.self) { reason in
                    if let n = counts[reason] {
                        HStack(alignment: .firstTextBaseline) {
                            Text(reason.explanation).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text(n.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                if state.scan.unverifiableCount > 0 {
                    Label("\(state.scan.unverifiableCount.formatted()) photos couldn’t be checked because their originals are only in iCloud. Turn on downloads in Settings ▸ Scanning to include them.",
                          systemImage: "icloud")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
    }
}

/// Settings ▸ Scanning: what counts as undated, albums of scans, and scanning sessions.
struct ScanSettingsView: View {
    @Environment(AppState.self) private var state

    var _albumSearch = State<String>(initialValue: "")
    private var albumSearch: String { get { _albumSearch.wrappedValue } nonmutating set { _albumSearch.wrappedValue = newValue } }
    var _newRuleLabel = State<String>(initialValue: "Scanning session")
    private var newRuleLabel: String { get { _newRuleLabel.wrappedValue } nonmutating set { _newRuleLabel.wrappedValue = newValue } }
    var _newRuleStart = State<Date>(initialValue: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
    private var newRuleStart: Date { get { _newRuleStart.wrappedValue } nonmutating set { _newRuleStart.wrappedValue = newValue } }
    var _newRuleEnd = State<Date>(initialValue: Date())
    private var newRuleEnd: Date { get { _newRuleEnd.wrappedValue } nonmutating set { _newRuleEnd.wrappedValue = newValue } }

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                Toggle("Photos whose file has no capture date", isOn: $state.settings.scan.deepCheck)
                Group {
                    Toggle("Trust photos that have a location", isOn: $state.settings.scan.skipGPSTagged)
                    Toggle("Download originals from iCloud when needed", isOn: $state.settings.scan.allowICloudDownloads)
                }
                .disabled(!state.settings.scan.deepCheck)
                Toggle("Include screenshots", isOn: $state.settings.scan.includeScreenshots)
            } header: {
                Text("What counts as undated")
            } footer: {
                Text("Photos with no date, an impossible date or a camera’s factory date (like Jan 1, 1970) always count. Scans usually carry the day they were scanned; the app reads the top of each file to tell. Photos with a location come from phones and GPS cameras, which keep good dates. Downloading from iCloud is slow.")
            }

            Section {
                if state.albums.isEmpty {
                    Text("No albums found.").foregroundStyle(.secondary)
                } else {
                    TextField("Search albums", text: _albumSearch.projectedValue)
                    let filtered = state.albums.filter { albumSearch.isEmpty || $0.title.localizedCaseInsensitiveContains(albumSearch) }
                    ForEach(filtered) { album in
                        Toggle(isOn: albumBinding(album.id)) {
                            HStack {
                                Text(album.title)
                                Spacer()
                                Text(album.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            } header: {
                Text("Albums of scans")
            } footer: {
                Text("Every photo in a checked album counts as undated, even if the scanner gave it a date.")
            }

            Section {
                ForEach(state.settings.scan.dateRangeRules) { rule in
                    HStack {
                        Text(rule.label)
                        Spacer()
                        Text("\(rule.start.shortDay) – \(rule.end.shortDay)").foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            state.settings.scan.dateRangeRules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                TextField("Name", text: _newRuleLabel.projectedValue)
                DatePicker("From", selection: _newRuleStart.projectedValue, displayedComponents: .date)
                DatePicker("To", selection: _newRuleEnd.projectedValue, displayedComponents: .date)
                HStack {
                    Spacer()
                    Button("Add Session") {
                        let cal = Calendar.current
                        let start = cal.startOfDay(for: min(newRuleStart, newRuleEnd))
                        let endDay = cal.startOfDay(for: max(newRuleStart, newRuleEnd))
                        let end = cal.date(byAdding: DateComponents(day: 1, second: -1), to: endDay) ?? endDay
                        state.settings.scan.dateRangeRules.append(DateRangeRule(label: newRuleLabel, start: start, end: end))
                    }
                }
            } header: {
                Text("Scanning sessions")
            } footer: {
                Text("Scanned a box of prints over a weekend? Add those days, and anything dated within them counts as undated.")
            }
        }
        .formStyle(.grouped)
    }

    private func albumBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { state.settings.scan.undatedAlbumIDs.contains(id) },
            set: { on in
                var ids = state.settings.scan.undatedAlbumIDs.filter { $0 != id }
                if on { ids.append(id) }
                state.settings.scan.undatedAlbumIDs = ids
            })
    }
}
