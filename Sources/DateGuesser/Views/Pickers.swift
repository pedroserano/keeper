import SwiftUI
import DateGuessCore

// The one date picker and the one place picker every screen uses, so setting a date or a place
// looks and works the same wherever you do it.

/// A date as you pick it: a year, then a season or a month, then (where it makes sense) a day.
struct DateChoice: Equatable {
    var year: Int
    var season: Season?
    var month: Int?
    var day: Int?

    /// Noon on the day picked (the 1st without one; January without a month).
    func date(calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month ?? season?.representativeMonth ?? 1,
                                           day: day ?? 1, hour: 12))
    }
}

/// Year, then season or month, then an optional exact day.
struct DatePickerForm: View {
    @Binding var choice: DateChoice
    var range: ClosedRange<Int>
    /// Offer "Keep Each Photo's Season" (a nil season and month).
    var keepSeason = false
    var seasons = true
    var days = false
    var note: String

    var body: some View {
        Form {
            LabeledContent("Year") {
                YearComboBox(year: choice.year, range: range) { choice.year = $0 }
                    .frame(width: 90)
            }
            Picker(seasons ? "Season or Month" : "Month", selection: monthTag) {
                if keepSeason { Text("Keep Each Photo’s Season").tag("keep") }
                if seasons {
                    Section("Season") {
                        ForEach(Season.allCases) { s in Text(s.displayName).tag("s\(s.rawValue)") }
                    }
                }
                Section("Month") {
                    ForEach(1...12, id: \.self) { m in Text(DateEstimate.monthNames[m - 1]).tag("m\(m)") }
                }
            }
            if days, let month = choice.month {
                Toggle("Exact Day", isOn: Binding(get: { choice.day != nil }, set: { choice.day = $0 ? 1 : nil }))
                if let day = choice.day {
                    Picker("Day", selection: Binding(get: { day }, set: { choice.day = $0 })) {
                        ForEach(1...Self.daysIn(month: month, year: choice.year), id: \.self) { Text("\($0)").tag($0) }
                    }
                }
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    private var monthTag: Binding<String> {
        Binding(
            get: { choice.month.map { "m\($0)" } ?? choice.season.map { "s\($0.rawValue)" } ?? (keepSeason ? "keep" : "m1") },
            set: { tag in
                if tag.hasPrefix("m") {
                    choice.month = Int(tag.dropFirst()); choice.season = nil
                    if let d = choice.day, let m = choice.month { choice.day = min(d, Self.daysIn(month: m, year: choice.year)) }
                } else if tag.hasPrefix("s") {
                    choice.season = Season(rawValue: String(tag.dropFirst())); choice.month = nil; choice.day = nil
                } else {
                    choice.season = nil; choice.month = nil; choice.day = nil
                }
            })
    }

    static func daysIn(month: Int, year: Int) -> Int {
        let calendar = Calendar.current
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return 31 }
        return calendar.range(of: .day, in: .month, for: date)?.count ?? 31
    }
}

/// The date picker with its title and buttons, for a popover or a sheet.
struct DatePickerPanel: View {
    var title: String
    @Binding var choice: DateChoice
    var range: ClosedRange<Int>
    var keepSeason = false
    var seasons = true
    var days = false
    var note: String
    var confirm: String
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding([.horizontal, .top], 16)
            DatePickerForm(choice: $choice, range: range, keepSeason: keepSeason, seasons: seasons, days: days, note: note)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirm, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 360)
    }

    static func title(_ count: Int) -> String { count == 1 ? "Date for 1 Photo" : "Date for \(count.formatted()) Photos" }
}

/// The place picker: search Apple Maps, pick a result.
struct PlacePickerPanel: View {
    var count: Int
    var note = "Nothing changes in Photos until you apply it."
    var onPick: (PlaceChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(count == 1 ? "Place for 1 Photo" : "Place for \(count.formatted()) Photos").font(.headline)
            PlaceSearchField(onPick: onPick)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 360)
        .padding(14)
    }
}

/// A button that opens the place picker.
struct PlacePickerButton: View {
    var title: String
    var count: Int
    var help: String
    var shortcut: KeyEquivalent?
    var note = "Nothing changes in Photos until you apply it."
    var onPick: (PlaceChoice) -> Void
    @State private var showing = false

    var body: some View {
        let button = Button { showing = true } label: { Label(title, systemImage: "mappin.and.ellipse") }
            .help(help)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                PlacePickerPanel(count: count, note: note) { choice in
                    onPick(choice)
                    showing = false
                }
            }
        if let shortcut { button.keyboardShortcut(shortcut, modifiers: .command) } else { button }
    }
}
