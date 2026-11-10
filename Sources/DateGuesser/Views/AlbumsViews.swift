import DateGuessCore
import KeeperCore
import KeeperUI
import SwiftUI

/// Albums to make from photos taken in one place over a few days or weeks: "2026-08 Hartford".
struct AlbumSuggestionsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.showShortcuts) private var showShortcuts
    @State private var confirming: AlbumSuggestions.Suggestion?
    private var albums: AlbumsState { state.albumTools }

    var body: some View {
        let shown = albums.shownSuggestions
        List {
            Section {
                ForEach(shown) { s in
                    SuggestionRow(suggestion: s, create: { confirming = s }, dismiss: { albums.dismiss(s) })
                }
            } footer: {
                Text("Photos with a location taken in one place, with no more than two days between them and \(Int(AlbumSuggestions.maxSpanDays)) days in all. Photos without a location from those days join when Places is sure they were taken there. Groups an album already holds (one with a year and month in its name) aren’t suggested.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView {
                    Label(albums.isSuggesting ? "Looking for Albums to Make…" : "No Albums to Suggest",
                          systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text(state.places.scan.lastScan == nil
                         ? "Suggestions come from where your photos were taken. Open Places to find them first."
                         : "Every group of photos taken in one place already has an album, or was dismissed.")
                }
            }
        }
        .navigationSubtitle("\(shown.count.formatted()) suggested")
        .toolbar {
            ToolbarItem {
                Button { albums.refreshSuggestions() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(albums.isSuggesting)
                    .help("Look for albums to make again")
            }
            ToolbarItem { ShortcutsToolbarButton(action: showShortcuts) }
        }
        .onAppear { if albums.suggestions.isEmpty { albums.refreshSuggestions() } }
        .alert("Make the album “\(confirming.flatMap(albums.name) ?? "")”?",
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Make Album") { if let s = confirming { albums.create(s) }; confirming = nil }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("A new album with \((confirming?.ids.count ?? 0).formatted()) photos is added to Photos. The photos themselves don’t change.")
        }
    }
}

private struct SuggestionRow: View {
    @Environment(AppState.self) private var state
    var suggestion: AlbumSuggestions.Suggestion
    var create: () -> Void
    var dismiss: () -> Void

    var body: some View {
        let albums = state.albumTools
        let name = albums.name(for: suggestion)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let name {
                    TextField("Album name", text: Binding(
                        get: { name },
                        set: { albums.names[suggestion.id] = $0 }))
                        .textFieldStyle(.plain)
                        .font(.headline)
                } else {
                    Text("\(albums.month(for: suggestion)) · finding the place…")
                        .font(.headline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(dates).foregroundStyle(.secondary)
                Text("\(suggestion.ids.count.formatted()) photos").foregroundStyle(.secondary).monospacedDigit()
                Button("Dismiss", action: dismiss)
                Button("Make Album…", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(albums.isCreating || name == nil)
            }
            ThumbnailStrip {
                HStack(spacing: 6) {
                    ForEach(suggestion.ids.prefix(14), id: \.self) { id in
                        AssetThumbnail(assetID: id, side: 84, showMarks: true)
                            .onTapGesture { PhotoZoom.shared.open(id, in: suggestion.ids, scope: "main") }
                            .help("Click to see it full size")
                    }
                    if suggestion.ids.count > 14 {
                        Text("+\((suggestion.ids.count - 14).formatted())").foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var dates: String {
        let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let a = suggestion.start.formatted(f), b = suggestion.end.formatted(f)
        return a == b ? a : "\(a) – \(b)"
    }
}

/// Albums holding two exact copies of a photo (the same original file, rating and Favorite): the
/// later copy in each can come out of the album. Photos are never deleted from the library.
struct AlbumDuplicatesView: View {
    @Environment(AppState.self) private var state
    @Environment(\.showShortcuts) private var showShortcuts
    @State private var confirming: AlbumDuplicates?
    private var albums: AlbumsState { state.albumTools }

    var body: some View {
        let found = albums.duplicates
        List {
            Section {
                ForEach(found) { album in
                    DuplicateAlbumRow(album: album, remove: { confirming = album })
                }
            } footer: {
                Text("Exact copies: the same original file, as Photos fingerprints it, with the same edits, rating and Favorite. Look-alikes, like a resized version or another crop of the same scan, aren’t copies and aren’t listed. In each album the copy that comes first stays; the later ones can come out of the album. They stay in your library.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let removal = albums.lastRemoval {
                KeeperActionBar("Took \(removal.assetIDs.count.formatted()) out of “\(removal.title)”.",
                                systemImage: "arrow.uturn.backward") {
                    Button("Put Back") { albums.putBack() }.disabled(albums.isRemoving)
                }
            }
        }
        .overlay {
            if found.isEmpty {
                ContentUnavailableView {
                    Label(albums.isReadingDuplicates ? "Looking Through Your Albums…"
                          : albums.duplicatesProblem != nil ? "Can’t Read Your Albums" : "No Duplicates in Albums",
                          systemImage: "square.on.square")
                } description: {
                    Text(albums.duplicatesProblem.map { "\($0) Keeper needs Full Disk Access to compare the photos in your albums." }
                         ?? "None of your albums holds two exact copies of a photo.")
                }
            }
        }
        .navigationSubtitle("\(found.count.formatted()) albums")
        .toolbar {
            ToolbarItem {
                Button { albums.refreshDuplicates() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(albums.isReadingDuplicates)
                    .help("Look through your albums again")
            }
            ToolbarItem { ShortcutsToolbarButton(action: showShortcuts) }
        }
        .onAppear { albums.refreshDuplicates() }
        .alert(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Remove from Album") { if let a = confirming { albums.removeExtras(from: a) }; confirming = nil }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("Only the later copies come out of this album. No photo is deleted: they stay in your library and in any other albums, and the first copy stays in this one.")
        }
    }

    private var confirmTitle: String {
        guard let a = confirming else { return "" }
        let n = a.extras.count
        return "Remove \(n.formatted()) duplicate \(n == 1 ? "copy" : "copies") from “\(a.title)”?"
    }
}

private struct DuplicateAlbumRow: View {
    @Environment(AppState.self) private var state
    var album: AlbumDuplicates
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(album.title, systemImage: "rectangle.stack").font(.headline)
                Spacer()
                Text("\(album.extras.count.formatted()) to remove").foregroundStyle(.secondary)
                Button("Remove from Album…", action: remove)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.albumTools.isRemoving)
            }
            ForEach(album.groups, id: \.self) { group in
                let ids = group.map(AlbumsState.assetID)
                HStack(spacing: 8) {
                    ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                        VStack(spacing: 4) {
                            AssetThumbnail(assetID: id, side: 96, showMarks: true)
                                .opacity(i == 0 ? 1 : 0.75)
                                .onTapGesture { PhotoZoom.shared.open(id, in: ids, scope: "main") }
                                .help("Click to see it full size")
                            Text(i == 0 ? "Stays" : "Comes out")
                                .font(.caption)
                                .foregroundStyle(i == 0 ? Color.secondary : Color.orange)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Photos in no album that were taken during an album's days, near where its photos were taken.
struct AlbumAdditionsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.showShortcuts) private var showShortcuts
    @State private var confirming: AlbumAdditions.Addition?
    private var albums: AlbumsState { state.albumTools }

    var body: some View {
        let found = albums.additions
        List {
            Section {
                ForEach(found) { a in
                    AdditionRow(addition: a, add: { confirming = a })
                }
            } footer: {
                Text("Photos that aren’t in any album, taken between an album’s first and last photo and within \(Int(AlbumAdditions.areaKm)) km of where its photos were taken at the time. Only albums covering \(Int(AlbumAdditions.maxSpanDays)) days or less are used. Photos without a location count when Places is sure where they were taken. Deselect a photo that doesn’t belong; Not in Album keeps it from being suggested again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if found.isEmpty {
                ContentUnavailableView {
                    Label(albums.isLookingForAdditions ? "Looking Through Your Albums…" : "Nothing Missing from Albums",
                          systemImage: "plus.rectangle.on.rectangle")
                } description: {
                    Text(state.places.scan.lastScan == nil
                         ? "This uses where your photos were taken. Open Places to find them first."
                         : "No photo outside your albums was taken during an album’s days, in the same place.")
                }
            }
        }
        .navigationSubtitle("\(found.count.formatted()) albums")
        .toolbar {
            ToolbarItem {
                Button { albums.refreshAdditions() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(albums.isLookingForAdditions)
                    .help("Look for photos missing from albums again")
            }
            ToolbarItem { ShortcutsToolbarButton(action: showShortcuts) }
        }
        .onAppear { if albums.additions.isEmpty { albums.refreshAdditions() } }
        .alert(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Add to Album") { if let a = confirming { albums.add(a) }; confirming = nil }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("The photos are added to the album in Photos. Nothing is removed, and the photos themselves don’t change.")
        }
    }

    private var confirmTitle: String {
        guard let a = confirming else { return "" }
        let n = albums.ticked(a).count
        return "Add \(n.formatted()) \(n == 1 ? "photo" : "photos") to “\(a.title)”?"
    }
}

private struct AdditionRow: View {
    @Environment(AppState.self) private var state
    var addition: AlbumAdditions.Addition
    var add: () -> Void

    var body: some View {
        let albums = state.albumTools
        let ticked = albums.ticked(addition).count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(addition.title, systemImage: "rectangle.stack").font(.headline)
                Text(dates).foregroundStyle(.secondary)
                Spacer()
                Text("\(addition.ids.count.formatted()) may belong").foregroundStyle(.secondary)
                if ticked < addition.ids.count {
                    Button("Not in Album") { albums.dismissUnticked(addition) }
                        .help("The unticked photos don’t belong: don’t suggest them for this album again")
                } else {
                    Button("Dismiss") { albums.dismissAll(addition) }
                        .help("None of these belong: don’t suggest them for this album again")
                }
                Button(ticked == addition.ids.count ? "Add to Album…" : "Add \(ticked.formatted())…", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(albums.isAdding || ticked == 0)
            }
            ThumbnailStrip {
                // Lazy: an album can have hundreds of candidates, and loading every thumbnail at
                // once stalled the screen.
                LazyHStack(spacing: 6) {
                    // Every one is shown (the strip scrolls): only photos you can see get added.
                    ForEach(addition.ids, id: \.self) { id in
                        let on = albums.isTicked(id, in: addition)
                        AssetThumbnail(assetID: id, side: 84, showMarks: true)
                            .opacity(on ? 1 : 0.4)
                            .overlay(alignment: .topLeading) {
                                SelectionCircle(selected: on, help: on ? "Will be added. Click to leave it out." : "Left out. Click to add it.") {
                                    albums.toggle(id, in: addition)
                                }
                            }
                            .onTapGesture { PhotoZoom.shared.open(id, in: addition.ids, scope: "main") }
                            .help("Click to see it full size")
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var dates: String {
        let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let a = addition.start.formatted(f), b = addition.end.formatted(f)
        return a == b ? a : "\(a) – \(b)"
    }
}
