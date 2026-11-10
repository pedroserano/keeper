import SwiftUI
import KeeperUI

/// Every date and place waiting to be written to Photos, from anywhere in Keeper, with one Apply.
struct ToApplyView: View {
    @Environment(AppState.self) private var state
    @Environment(\.showShortcuts) private var showShortcuts
    @State private var confirmApply = false

    var body: some View {
        let dates = state.waitingDates, places = state.waitingPlaces
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !dates.isEmpty { WaitingSection(title: "Dates", items: dates, dates: true) }
                if !places.isEmpty { WaitingSection(title: "Places", items: places, dates: false) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if dates.isEmpty && places.isEmpty {
                ContentUnavailableView("Nothing to Apply", systemImage: "tray",
                                       description: Text("Dates and places you set, here or with right-click › Set Date… and Set Location…, wait here until you apply them."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !dates.isEmpty || !places.isEmpty {
                KeeperActionBar(summary(dates.count, places.count), systemImage: "tray.and.arrow.up") {
                    if let p = state.applyProgress ?? state.places.applyProgress {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 120)
                    }
                    Button("Apply…") { confirmApply = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isApplyingAnything)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            KeeperStatusBar(detail: "Right-click a photo to leave it out")
        }
        .toolbar {
            KeeperToolbar(shortcuts: showShortcuts) { EmptyView() } action: { EmptyView() }
        }
        .alert("Apply \(summary(dates.count, places.count))?", isPresented: $confirmApply) {
            Button("Apply") { state.applyEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeper writes them to your Photos library. You can undo any of it from History.")
        }
    }

    private func summary(_ dates: Int, _ places: Int) -> String {
        var parts: [String] = []
        if dates > 0 { parts.append(dates == 1 ? "1 date" : "\(dates.formatted()) dates") }
        if places > 0 { parts.append(places == 1 ? "1 place" : "\(places.formatted()) places") }
        return parts.joined(separator: " and ")
    }
}

private struct WaitingSection: View {
    @Environment(AppState.self) private var state
    var title: String
    var items: [AppState.WaitingChange]
    var dates: Bool

    @AppStorage(ThumbnailSizeSlider.storageKey) private var scale = 1.0
    @AppStorage(PhotoShapePicker.storageKey) private var wholePhotos = false
    private var side: CGFloat { (140 * scale).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.bold())
                Text(AppState.photos(items.count)).foregroundStyle(.secondary)
                Spacer()
                Button("Leave All Out") { state.dontApply(items.map(\.id), dates: dates) }
                    .disabled(state.isApplyingAnything)
            }
            let ids = items.map(\.id)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side, maximum: side * 1.3), spacing: 14, alignment: .top)],
                      spacing: 14) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        AssetThumbnail(assetID: item.id, side: .infinity, height: side, showMarks: true, wholePhoto: wholePhotos)
                            .onTapGesture { PhotoZoom.shared.open(item.id, in: ids, scope: "main") }
                            .help("Click to see it filling the window")
                        Text(item.text).font(.callout.weight(.medium)).lineLimit(1)
                        Text(origin(item.origin)).font(.caption).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Leave Out") { state.dontApply([item.id], dates: dates) }
                            .disabled(state.isApplyingAnything)
                    }
                }
            }
        }
    }

    private func origin(_ o: AppState.WaitingChange.Origin) -> String {
        switch o {
        case .undated: "Selected in Undated Photos"
        case .places: "Selected in Places"
        case .elsewhere: dates ? "Set with Set Date…" : "Set with Set Location…"
        }
    }
}
