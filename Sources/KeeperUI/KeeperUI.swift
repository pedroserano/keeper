// The pieces every Keeper screen shares, so the culling lists and the Dates screens look and
// behave alike: photo corners, the current-photo border, the selection circle, the Favorite,
// star and RAW marks, the message bubble, the action and status bars, and the shortcut guide.

import SwiftUI

public enum PhotoStyle {
    /// Corner radius of a photo in a grid.
    public static let cornerRadius: CGFloat = 6
    /// Width of the accent border round the current photo.
    public static let borderWidth: CGFloat = 3
}

extension View {
    /// The accent border round the current photo (the one the arrow keys move and Return opens).
    public func currentPhotoBorder(_ isCurrent: Bool, cornerRadius: CGFloat = PhotoStyle.cornerRadius) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: PhotoStyle.borderWidth)
                .allowsHitTesting(false)
        }
    }

    /// The light accent wash over a selected photo.
    public func selectedTint(_ selected: Bool, cornerRadius: CGFloat = PhotoStyle.cornerRadius) -> some View {
        overlay {
            if selected {
                RoundedRectangle(cornerRadius: cornerRadius).fill(Color.accentColor.opacity(0.18)).allowsHitTesting(false)
            }
        }
    }
}

/// The circle at a photo's top left, as in Photos: filled with a checkmark when selected.
public struct SelectionCircle: View {
    var selected: Bool
    var help: String
    var action: () -> Void

    public init(selected: Bool, help: String, action: @escaping () -> Void) {
        self.selected = selected
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, selected ? Color.accentColor : .black.opacity(0.25))
                .shadow(color: .black.opacity(0.5), radius: 1.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(5)
        .help(help)
    }
}

// MARK: Marks on a photo

/// "RAW", for a photo whose original is a RAW file.
public struct RawTag: View {
    var large: Bool
    public init(large: Bool = false) { self.large = large }

    public var body: some View {
        Text("RAW")
            .font(.system(size: large ? 11 : 8, weight: .bold))
            .padding(.horizontal, large ? 5 : 3)
            .padding(.vertical, 1)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
            .help("RAW original")
    }
}

/// ♥ for a Favorite in Photos.
public struct FavoriteHeart: View {
    public init() {}

    public var body: some View {
        Image(systemName: "heart.fill")
            .foregroundStyle(.pink)
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .help("Favorite in Photos")
    }
}

/// The photo's star rating, in yellow.
public struct StarsTag: View {
    var stars: Int
    public init(stars: Int) { self.stars = stars }

    public var body: some View {
        Text(String(repeating: "★", count: max(0, min(5, stars))))
            .foregroundStyle(.yellow)
            .padding(.horizontal, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .help("\(stars)-star rating")
    }
}

/// RAW and ♥ at the top right, stars at the bottom left: the same corners as in the culling lists.
public struct PhotoMarks: View {
    var isFavorite: Bool
    var stars: Int
    var isRaw: Bool
    var large: Bool

    public init(isFavorite: Bool, stars: Int, isRaw: Bool, large: Bool = false) {
        self.isFavorite = isFavorite
        self.stars = stars
        self.isRaw = isRaw
        self.large = large
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                Spacer(minLength: 0)
                if isRaw { RawTag(large: large) }
                if isFavorite { FavoriteHeart() }
            }
            Spacer(minLength: 0)
            HStack {
                if stars > 0 { StarsTag(stars: stars) }
                Spacer(minLength: 0)
            }
        }
        .font(large ? .title3 : .caption)
        .padding(large ? 8 : 5)
        .allowsHitTesting(isRaw || isFavorite || stars > 0)
    }
}

// MARK: Messages and bars

/// The message bubble at the top of a screen. It goes away by itself after 10 seconds, or with ×.
public struct KeeperToast: View {
    @Binding var message: String?
    public static let seconds: Double = 10

    public init(message: Binding<String?>) { _message = message }

    public var body: some View {
        ZStack {
            if let text = message {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.tint)
                    Text(text).lineLimit(3)
                    Button { message = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .padding(.top, 10)
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(Self.seconds))
                    if !Task.isCancelled, message == text { withAnimation { message = nil } }
                }
            }
        }
        .animation(.default, value: message)
    }
}

/// The bar under the toolbar that says what's selected and holds the main action, on the right.
public struct KeeperActionBar<Actions: View>: View {
    var text: String
    var systemImage: String?
    var actions: Actions

    public init(_ text: String, systemImage: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.text = text
        self.systemImage = systemImage
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(.tint) }
            Text(text).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            actions
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// The bar at the bottom of a screen: where you are in the list, anything else worth a glance,
/// and the reminder that ? shows the shortcuts.
public struct KeeperStatusBar: View {
    var position: String?
    var detail: String?

    public init(position: String? = nil, detail: String? = nil) {
        self.position = position
        self.detail = detail
    }

    public var body: some View {
        HStack(spacing: 14) {
            if let position { Text(position).monospacedDigit() }
            Spacer()
            if let detail { Text(detail).monospacedDigit() }
            Text("? for shortcuts").foregroundStyle(.tertiary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// "3 of 120".
    public static func position(_ index: Int?, of count: Int) -> String? {
        guard count > 0 else { return nil }
        guard let index else { return "\(count.formatted()) photos" }
        return "\((index + 1).formatted()) of \(count.formatted())"
    }
}

// MARK: Shortcuts

public struct Shortcut: Identifiable, Sendable {
    public var keys: [String]
    public var action: String
    public var id: String { keys.joined() + action }

    public init(_ keys: [String], _ action: String) {
        self.keys = keys
        self.action = action
    }
}

public struct ShortcutSection: Identifiable, Sendable {
    public var title: String
    public var items: [Shortcut]
    public var id: String { title }

    public init(_ title: String, _ items: [Shortcut]) {
        self.title = title
        self.items = items
    }

    /// The keys that work the same on every screen.
    public static let everywhere = ShortcutSection("Every screen", [
        Shortcut(["←", "→", "↑", "↓"], "Move between photos"),
        Shortcut(["Return"], "Open the photo"),
        Shortcut(["Space"], "See the photo bigger; Space again to go back"),
        Shortcut(["Esc"], "Back out one step: zoom, the open photo, then the selection"),
        Shortcut(["G"], "Select or deselect the current photo (⌘-click and Shift-click too)"),
        Shortcut(["⌘", "A"], "Select every photo shown"),
        Shortcut(["⇧", "⌘", "A"], "Deselect them all"),
        Shortcut(["A"], "Accept Keeper's suggestion"),
        Shortcut(["N"], "Turn the suggestion down"),
        Shortcut(["R"], "Rotate 90° clockwise in Photos (the selected photos, or the current one)"),
        Shortcut(["⌘", "Z"], "Undo"),
        Shortcut(["⇧", "⌘", "Z"], "Redo"),
        Shortcut(["?"], "Show or hide this guide"),
    ])
}

/// The keyboard shortcuts guide: the keys for this screen first, then the ones every screen shares.
public struct KeeperShortcutGuide: View {
    var screen: String
    var sections: [ShortcutSection]
    var footnote: String?
    @Environment(\.dismiss) private var dismiss

    public init(screen: String, sections: [ShortcutSection], footnote: String? = nil) {
        self.screen = screen
        self.sections = sections
        self.footnote = footnote
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboard Shortcuts").font(.title2.bold())
                Text(screen).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections + [.everywhere]) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.headline)
                            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                                ForEach(section.items) { item in
                                    GridRow {
                                        HStack(spacing: 3) {
                                            ForEach(Array(item.keys.enumerated()), id: \.offset) { KeyCap(label: $0.element) }
                                        }
                                        .gridColumnAlignment(.trailing)
                                        .frame(minWidth: 110, alignment: .trailing)
                                        Text(item.action).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    Text(footnote ?? "Letter keys and Space don't work while you're typing in a box, so typing a year or a search is safe.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 600)
    }
}

/// The keyboard button every screen has in the same place in its toolbar.
public struct ShortcutsToolbarButton: View {
    var action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        Button(action: action) { Label("Keyboard Shortcuts", systemImage: "keyboard") }
            .help("Keyboard shortcuts (?)")
    }
}

private struct KeyCap: View {
    var label: String

    var body: some View {
        Text(label)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.tertiary, lineWidth: 0.5))
    }
}

// MARK: The toolbar every photo screen shares

/// The toolbar of every photo screen, in one order on the right: Show, photo shape, the screen's own
/// action (Sort, New Group, Delete Rejected…), then the keyboard button, always farthest right.
/// Screens only choose what goes in each slot, so they can't drift apart.
public struct KeeperToolbar<Show: View, Action: View>: ToolbarContent {
    var show: Show
    var showsPhotoShape: Bool
    var photoShapeEnabled: Bool
    var action: Action
    var shortcuts: () -> Void

    public init(photoShape: Bool = true, photoShapeEnabled: Bool = true,
                shortcuts: @escaping () -> Void,
                @ViewBuilder show: () -> Show, @ViewBuilder action: () -> Action) {
        self.show = show()
        self.showsPhotoShape = photoShape
        self.photoShapeEnabled = photoShapeEnabled
        self.action = action()
        self.shortcuts = shortcuts
    }

    public var body: some ToolbarContent {
        ToolbarItem { show }
        ToolbarItem {
            if showsPhotoShape { PhotoShapePicker().disabled(!photoShapeEnabled) }
        }
        ToolbarItem { action }
        ToolbarItem { ShortcutsToolbarButton(action: shortcuts) }
    }
}

/// The Show drop-down: the current choice, with the icon filled in when it isn't the first one.
public struct ShowMenu<Choice: Hashable & CaseIterable & RawRepresentable>: View
    where Choice.RawValue == String, Choice.AllCases: RandomAccessCollection {
    @Binding var selection: Choice
    var help: String

    public init(selection: Binding<Choice>, help: String = "Which photos to show") {
        _selection = selection
        self.help = help
    }

    public var body: some View {
        let first = Choice.allCases.first == selection
        Menu {
            Picker("Show", selection: $selection) {
                ForEach(Array(Choice.allCases), id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(selection.rawValue, systemImage: first ? "line.3.horizontal.decrease.circle"
                                                         : "line.3.horizontal.decrease.circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help(help)
    }
}

/// Squares or whole photos. One setting for every grid, so they all show photos the same way.
public struct PhotoShapePicker: View {
    public static let storageKey = "gridWholePhotos"
    @AppStorage(PhotoShapePicker.storageKey) private var wholePhotos = false

    public init() {}

    public var body: some View {
        Picker("Photo Shape", selection: $wholePhotos) {
            Label("Squares", systemImage: "square.grid.3x3.square").tag(false)
            Label("Whole Photos", systemImage: "aspectratio").tag(true)
        }
        .pickerStyle(.segmented)
        .help("Grid shows photos as squares, or whole at their own shape")
    }
}
