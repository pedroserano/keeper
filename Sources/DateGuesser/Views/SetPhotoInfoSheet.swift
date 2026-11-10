import SwiftUI
import DateGuessCore

/// Right-click › Set Date or Set Location on photos in Keeper's albums: one date or one place for
/// every photo picked, written to Photos straight away and undoable from History.
public struct SetPhotoInfoSheet: View {
    public enum Kind: String, Identifiable, Sendable {
        case date, location
        public var id: String { rawValue }
    }

    var model: DatesModel?
    var ids: [String]
    var kind: Kind
    /// Closes the sheet; the text is what happened, to show (nil when cancelled).
    var onDone: (String?) -> Void
    @State private var day: Date
    @State private var place: PlaceChoice?
    @State private var writing = false

    public init(model: DatesModel?, ids: [String], kind: Kind, startDate: Date?, onDone: @escaping (String?) -> Void) {
        self.model = model
        self.ids = ids
        self.kind = kind
        self.onDone = onDone
        _day = State(initialValue: startDate ?? Date())
    }

    private var count: String { ids.count == 1 ? "1 Photo" : "\(ids.count.formatted()) Photos" }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .date ? "Set Date for \(count)" : "Set Location for \(count)").font(.headline)
            if model == nil {
                ProgressView("Loading…").controlSize(.small)
            } else if kind == .date {
                DatePicker("Date", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                Text("Each photo keeps its own time of day. You can undo this from Undated Photos › History.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                PlaceSearchField { place = $0 }
                if let place {
                    Label { PlaceLabel(point: place.point, name: place.name.isEmpty ? nil : place.name) }
                        icon: { Image(systemName: "mappin.circle.fill").foregroundStyle(Theme.accent) }
                        .font(.callout.weight(.semibold))
                }
                Text("Replaces any location they have. You can undo this from Places › History.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if writing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(writing)
                Button(kind == .date ? "Set Date" : "Set Location") { write() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model == nil || writing || (kind == .location && place == nil))
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func write() {
        guard let model else { return }
        writing = true
        Task {
            let message: String
            switch kind {
            case .date: message = await model.setDate(ids, to: day)
            case .location:
                guard let place else { writing = false; return }
                message = await model.state.places.setLocationInPhotos(ids, place)
            }
            writing = false
            onDone(message)
        }
    }
}
