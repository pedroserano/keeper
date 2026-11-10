import SwiftUI
import DateGuessCore

/// Right-click › Set Date… or Set Location…: one date or one place for every photo picked. Like
/// every change, it waits in To Apply until you apply it.
public struct SetPhotoInfoSheet: View {
    public enum Kind: String, Identifiable, Sendable {
        case date, location
        public var id: String { rawValue }
    }

    var state: AppState?
    var ids: [String]
    var kind: Kind
    /// Closes the sheet; the text is what happened, to show (nil when cancelled).
    var onDone: (String?) -> Void
    @State private var choice: DateChoice
    @State private var place: PlaceChoice?

    public init(model: DatesModel?, ids: [String], kind: Kind, startDate: Date?, onDone: @escaping (String?) -> Void) {
        self.init(state: model?.state, ids: ids, kind: kind, startDate: startDate, onDone: onDone)
    }

    init(state: AppState?, ids: [String], kind: Kind, startDate: Date?, onDone: @escaping (String?) -> Void) {
        self.state = state
        self.ids = ids
        self.kind = kind
        self.onDone = onDone
        let calendar = Calendar.current
        let start = startDate ?? Date()
        _choice = State(initialValue: DateChoice(year: calendar.component(.year, from: start),
                                                 month: calendar.component(.month, from: start),
                                                 day: calendar.component(.day, from: start)))
    }

    private var count: String { ids.count == 1 ? "1 Photo" : "\(ids.count.formatted()) Photos" }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .date ? "Set Date for \(count)" : "Set Location for \(count)").font(.headline)
            if state == nil {
                ProgressView("Loading…").controlSize(.small)
            } else if kind == .date {
                DatePickerForm(choice: $choice, range: (state?.lowestYear ?? 1850)...YearBounds.currentYear(),
                               seasons: false, days: true,
                               note: "Each photo keeps its own time of day (the 1st without an exact day). It waits in To Apply until you apply it.")
                    .frame(height: 230)
            } else {
                PlaceSearchField { place = $0 }
                if let place {
                    Label { PlaceLabel(point: place.point, name: place.name.isEmpty ? nil : place.name) }
                        icon: { Image(systemName: "mappin.circle.fill").foregroundStyle(Theme.accent) }
                        .font(.callout.weight(.semibold))
                }
                Text("Replaces any location they have. It waits in To Apply until you apply it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(kind == .date ? "Set Date" : "Set Location") { write() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(state == nil || (kind == .location && place == nil))
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func write() {
        guard let state else { return }
        switch kind {
        case .date:
            guard let day = choice.date() else { return }
            onDone(state.queueDate(ids, day: day))
        case .location:
            guard let place else { return }
            onDone(state.queuePlace(ids, place))
        }
    }
}

/// Right-click › Set Date… or Set Location… on a Dates screen, shown by the screen around it.
struct PhotoInfoRequest: Identifiable {
    let id = UUID()
    var ids: [String]
    var kind: SetPhotoInfoSheet.Kind
    var startDate: Date?
}

extension View {
    /// Shows Set Date… / Set Location… when a Dates screen's right-click menu asks for it.
    func photoInfoSheet(_ state: AppState) -> some View {
        sheet(item: Binding(get: { state.photoInfoRequest }, set: { state.photoInfoRequest = $0 })) { request in
            SetPhotoInfoSheet(state: state, ids: request.ids, kind: request.kind, startDate: request.startDate) { message in
                state.photoInfoRequest = nil
                if let message { state.banner = message }
            }
        }
    }
}
