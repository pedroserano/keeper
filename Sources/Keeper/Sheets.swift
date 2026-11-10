import Photos
import SwiftUI
import KeeperUI

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

/// The shortcut guide for Keeper's photo lists (the Dates screens have their own sections).
struct ShortcutsSheet: View {
    var screen: String

    static let sections: [ShortcutSection] = [
        ShortcutSection("Deciding", [
            Shortcut(["F"], "Favorite or unfavorite in Photos"),
            Shortcut(["X"], "Reject (adds it to the delete queue); ⌫ does too"),
            Shortcut(["U"], "Clear the reject"),
            Shortcut(["1", "–", "5"], "Star rating; 0 clears it"),
            Shortcut(["H"], "Hide in Photos"),
            Shortcut(["A"], "Accept the suggested stars. In Sideways Photos: rotate the way proposed"),
            Shortcut(["N"], "In Sideways Photos: not sideways, leave it as it is"),
        ]),
        ShortcutSection("Looking closer", [
            Shortcut(["Z"], "100% zoom on the main face"),
            Shortcut(["C"], "Compare with its look-alikes, burst frames or nearby shots"),
            Shortcut(["I"], "Show Apple Photos' scores for this photo"),
            Shortcut(["⌘", "1"], "Grid; ⌘2 one photo, ⌘3 compare (double-click a photo opens it too)"),
        ]),
        ShortcutSection("Duplicates and Similar Shots", [
            Shortcut(["↑", "↓"], "Previous or next group; with ⇧, select groups"),
            Shortcut(["G"], "Select or deselect the group (or the selected groups)"),
            Shortcut(["K"], "Keep this one when merging. In compare: keep this one, reject the others"),
        ]),
    ]

    var body: some View {
        KeeperShortcutGuide(screen: screen, sections: Self.sections)
    }
}
