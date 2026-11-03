import Photos
import SwiftUI

struct DeleteQueueSheet: View {
    @EnvironmentObject private var session: CullingSession
    @Environment(\.dismiss) private var dismiss
    @State private var assets: [PHAsset] = []
    @State private var deleting = false

    private var favorites: Int { assets.filter(\.isFavorite).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(assets.count) Rejected Photos?").font(.title3.bold())
            Text("They move to Recently Deleted in Photos and stay there for 30 days. macOS will ask you to confirm.")
                .foregroundStyle(.secondary)
            if favorites > 0 {
                Label("\(favorites) of them \(favorites == 1 ? "is a Favorite" : "are Favorites").",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        AssetImage(asset: asset, pointSize: CGSize(width: 76, height: 76), fill: true)
                            .frame(width: 76, height: 76)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .frame(height: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete \(assets.count) Photos", role: .destructive) {
                    deleting = true
                    Task {
                        if await session.deleteRejected() { dismiss() }
                        deleting = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(assets.isEmpty || deleting)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { assets = session.rejectedAssets() }
    }
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Decide", [("F", "Favorite or unfavorite in Photos"),
                    ("X or ⌫", "Reject (adds to the delete queue)"),
                    ("U", "Clear reject"),
                    ("1 – 5", "Star rating"),
                    ("0", "Clear rating"),
                    ("H", "Hide in Photos"),
                    ("A", "Accept the suggested star rating")]),
        ("Move", [("← →", "Previous / next photo"),
                  ("↑ ↓", "Row up / down in the grid; in Duplicates or Similar Shots, previous / next group"),
                  ("Return", "Switch between grid and single photo"),
                  ("Esc", "Back out of zoom, then back to the grid")]),
        ("Look closer", [("Space", "In the grid: show the photo filling the window, Space again to go back. In a photo: 100% zoom on and off"),
                         ("Z", "100% zoom on the main face"),
                         ("C", "Compare with its look-alikes, burst frames or nearby shots"),
                         ("G", "In Duplicates or Similar Shots: tick or untick the group"),
                         ("K", "In compare: keep this one, reject the others. In Duplicates or Similar Shots: keep this one when merging"),
                         ("I", "Show Apple Photos' scores for this photo")]),
        ("Undo", [("⌘Z", "Undo"), ("⇧⌘Z", "Redo")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(groups, id: \.0) { group in
                    GridRow {
                        Text(group.0).font(.headline).gridCellColumns(2).padding(.top, 6)
                    }
                    ForEach(group.1, id: \.0) { key, action in
                        GridRow {
                            Text(key).font(.body.monospaced()).gridColumnAlignment(.trailing)
                            Text(action)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
