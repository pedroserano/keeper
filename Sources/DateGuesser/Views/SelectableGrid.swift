import AppKit
import SwiftUI
import KeeperUI

/// The current photo in a Dates grid: the one the arrow keys move, Return opens, and G, A and N act
/// on. `anchor` is where Shift-click ranges start.
struct GridCursor: Equatable {
    var id: String?
    var anchor: String?

    /// Click makes a photo current; ⌘-click also selects or deselects it. Shift-click goes from the
    /// last photo clicked to this one, the way this photo goes: clicking one that isn't selected
    /// selects them all, clicking one that is deselects them all.
    mutating func click(_ id: String, in ids: [String], modifiers: NSEvent.ModifierFlags, _ actions: GridActions) {
        if modifiers.contains(.shift), let range = Self.range(from: anchor, to: id, in: ids) {
            actions.select(range.filter(actions.canSelect), !actions.isSelected(id))
        } else if modifiers.contains(.command) {
            if actions.canSelect(id) { actions.select([id], !actions.isSelected(id)) }
            anchor = id
        } else {
            anchor = id
        }
        self.id = id
    }

    /// The circle on a photo: selects or deselects it; with Shift, every photo from the last one
    /// clicked goes the same way.
    mutating func toggle(_ id: String, in ids: [String], extend: Bool, _ actions: GridActions) {
        let on = !actions.isSelected(id)
        if extend, let range = Self.range(from: anchor, to: id, in: ids) {
            actions.select(range.filter(actions.canSelect), on)
        } else if actions.canSelect(id) {
            actions.select([id], on)
        }
        anchor = id
        self.id = id
    }

    static func range(from anchor: String?, to id: String, in ids: [String]) -> [String]? {
        guard let anchor, let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) else { return nil }
        return Array(ids[min(a, b)...max(a, b)])
    }

    /// Moves `delta` photos (a row is `columns`), staying inside the list. The first key press with
    /// no current photo starts at the first one.
    static func moved(_ id: String?, by delta: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let id, let i = ids.firstIndex(of: id) else { return ids.first }
        return ids[min(max(0, i + delta), ids.count - 1)]
    }

    /// The photo to make current after this one leaves the list (the next, or else the one before).
    static func neighbour(of id: String, in ids: [String]) -> String? {
        guard let i = ids.firstIndex(of: id) else { return nil }
        return i + 1 < ids.count ? ids[i + 1] : i > 0 ? ids[i - 1] : nil
    }
}

/// The bottom bar of a Dates grid ("3 of 120"). It reads the cursor itself, so moving between
/// photos redraws only this bar and the grid, not the screen that filters and sorts the list.
struct GridStatusBar: View {
    var ids: [String]
    @Binding var cursor: GridCursor

    var body: some View {
        KeeperStatusBar(position: KeeperStatusBar.position(cursor.id.flatMap(ids.firstIndex(of:)), of: ids.count))
    }
}

/// What a Dates photo grid does for the keys every Keeper screen shares.
struct GridActions {
    var isSelected: (String) -> Bool
    var canSelect: (String) -> Bool = { _ in true }
    var select: ([String], Bool) -> Void
    /// A: accept the guess.
    var accept: (String) -> Void
    /// N: turn the guess down (hide the photo, or bring a hidden one back).
    var decline: (String) -> Void
    /// R: rotate clockwise.
    var rotate: ([String]) -> Void
    /// Return: the photo's details.
    var open: (String) -> Void
    var message: (String) -> Void
    /// Esc: every selected photo, shown or not (a screen whose count covers photos the filter
    /// hides). Nil deselects only the photos shown.
    var allSelected: (() -> [String])? = nil
}

/// A grid of photo cards that works the way Keeper's lists do: ← → ↑ ↓ move, Return (or ⌘I) opens, Space
/// shows the photo filling the window, G selects, A accepts, N declines, R rotates, Esc deselects.
struct SelectableGrid<Card: View>: View {
    var ids: [String]
    @Binding var cursor: GridCursor
    var actions: GridActions
    @ViewBuilder var card: (_ id: String, _ isCurrent: Bool) -> Card
    @State private var width: CGFloat = 900

    @AppStorage(ThumbnailSizeSlider.storageKey) private var scale = 1.0
    /// The toolbar's size slider scales this.
    private var minimum: CGFloat { (200 * scale).rounded() }
    static var spacing: CGFloat { 16 }
    static var padding: CGFloat { 20 }

    /// How many cards fit across: what `.adaptive(minimum:)` works out.
    private var columns: Int {
        max(1, Int((width - 2 * Self.padding + Self.spacing) / (minimum + Self.spacing)))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: (minimum * 1.3).rounded()), spacing: Self.spacing, alignment: .top)],
                          spacing: 20) {
                    ForEach(ids, id: \.self) { id in
                        card(id, id == cursor.id).id(id)
                    }
                }
                .padding(Self.padding)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: cursor.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
        // Keeper's rating keys act on this grid's current photo.
        .onAppear { DatesModel.gridCurrent = cursor.id }
        .onChange(of: cursor.id) { _, id in DatesModel.gridCurrent = id }
        .onDisappear { if DatesModel.gridCurrent == cursor.id { DatesModel.gridCurrent = nil } }
        .modifier(KeyCommandModifier(key: Self.left) { move(-1) })
        .modifier(KeyCommandModifier(key: Self.right) { move(1) })
        .modifier(KeyCommandModifier(key: Self.up) { move(-columns) })
        .modifier(KeyCommandModifier(key: Self.down) { move(columns) })
        .modifier(KeyCommandModifier(key: "\r") { onCurrent { actions.open($0) } })
        .modifier(KeyCommandModifier(key: "\u{3}") { onCurrent { actions.open($0) } })
        .modifier(KeyCommandModifier(key: "⌘i") { onCurrent { actions.open($0) } })
        .modifier(KeyCommandModifier(key: " ") { onCurrent { PhotoZoom.shared.open($0, in: ids, scope: "main") } })
        .modifier(KeyCommandModifier(key: "g") {
            onCurrent { id in if actions.canSelect(id) { actions.select([id], !actions.isSelected(id)) } }
        })
        .modifier(KeyCommandModifier(key: "a") { onCurrent { id in
            actions.accept(id)
            cursor.id = GridCursor.moved(id, by: 1, in: ids)
        } })
        .modifier(KeyCommandModifier(key: "n") { onCurrent { id in
            let next = GridCursor.neighbour(of: id, in: ids)
            actions.decline(id)
            cursor.id = next
        } })
        .modifier(KeyCommandModifier(key: "r") {
            guard free else { return false }
            let chosen = ids.filter(actions.isSelected)
            if !chosen.isEmpty { actions.rotate(chosen); return true }
            return onCurrent { actions.rotate([$0]) }
        })
        .modifier(KeyCommandModifier(key: "\u{1b}") {
            guard free else { return false }
            let chosen = actions.allSelected?() ?? ids.filter(actions.isSelected)
            guard !chosen.isEmpty else { return false }
            actions.select(chosen, false)
            actions.message("Deselected \(chosen.count.formatted()) \(chosen.count == 1 ? "photo" : "photos"). ⌘Z selects them again.")
            return true
        })
    }

    static var left: String { String(UnicodeScalar(NSLeftArrowFunctionKey)!) }
    static var right: String { String(UnicodeScalar(NSRightArrowFunctionKey)!) }
    static var up: String { String(UnicodeScalar(NSUpArrowFunctionKey)!) }
    static var down: String { String(UnicodeScalar(NSDownArrowFunctionKey)!) }

    /// Keys go to the zoomed photo or a sheet first.
    private var free: Bool {
        guard PhotoZoom.shared.request == nil, let window = NSApp.keyWindow else { return false }
        return window.sheetParent == nil && window.attachedSheet == nil
    }

    private func move(_ delta: Int) -> Bool {
        guard free, !ids.isEmpty else { return false }
        let next = GridCursor.moved(cursor.id, by: delta, in: ids)
        if NSEvent.modifierFlags.contains(.shift), let from = cursor.id ?? next, let next,
           let range = GridCursor.range(from: from, to: next, in: ids) {
            actions.select(range.filter(actions.canSelect), true)
        } else {
            cursor.anchor = next
        }
        cursor.id = next
        return true
    }

    private func onCurrent(_ perform: (String) -> Void) -> Bool {
        guard free, let id = cursor.id, ids.contains(id) else { return false }
        perform(id)
        return true
    }
}
