import SwiftUI

extension Notification.Name {
    /// Help ▸ Keyboard Shortcuts asks the window to show the guide.
    static let showKeyboardShortcuts = Notification.Name("showKeyboardShortcuts")
}

/// The keyboard shortcuts guide, shown with / or Help ▸ Keyboard Shortcuts.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    struct Shortcut: Identifiable {
        var keys: [String]
        var action: String
        var id: String { action }
    }

    struct Section: Identifiable {
        var title: String
        var items: [Shortcut]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Selecting photos (Undated Photos and Places)", items: [
            Shortcut(keys: ["Click"], action: "Select a photo"),
            Shortcut(keys: ["⌘", "Click"], action: "Add or remove a photo from the selection"),
            Shortcut(keys: ["⇧", "Click"], action: "Select every photo in between"),
            Shortcut(keys: ["Esc"], action: "Deselect all"),
        ]),
        Section(title: "Checking photos to change", items: [
            Shortcut(keys: ["Space"], action: "Check the selected photos (unchecks them if all are checked)"),
            Shortcut(keys: ["⇧", "Click ✓"], action: "Check or uncheck every photo in between"),
            Shortcut(keys: ["⌘", "A"], action: "Check all shown photos"),
            Shortcut(keys: ["⇧", "⌘", "A"], action: "Uncheck all shown photos"),
        ]),
        Section(title: "Dates", items: [
            Shortcut(keys: ["⌘", "D"], action: "Give all checked photos one date"),
            Shortcut(keys: ["Return"], action: "Confirm the date or dialog"),
            Shortcut(keys: ["Esc"], action: "Cancel"),
        ]),
        Section(title: "Places", items: [
            Shortcut(keys: ["⌘", "L"], action: "Give all checked photos one place"),
            Shortcut(keys: ["Return"], action: "Pick the first Apple Maps suggestion"),
        ]),
        Section(title: "Seeing a photo bigger (Events)", items: [
            Shortcut(keys: ["Click"], action: "Show the photo filling the window"),
            Shortcut(keys: ["Space"], action: "Show the photo under the pointer filling the window"),
            Shortcut(keys: ["←", "→"], action: "Previous or next photo"),
            Shortcut(keys: ["Esc"], action: "Back to the thumbnails (Space or a click works too)"),
        ]),
        Section(title: "Photos", items: [
            Shortcut(keys: ["R"], action: "Rotate the selected photos 90° clockwise in Photos (Review, photo details, and group photos in Events)"),
        ]),
        Section(title: "Anywhere", items: [
            Shortcut(keys: ["/"], action: "Show or hide this guide (the key marked ?)"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard Shortcuts")
                .font(.title2.bold())
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.headline)
                            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                                ForEach(section.items) { item in
                                    GridRow {
                                        HStack(spacing: 3) {
                                            ForEach(item.keys, id: \.self) { KeyCap(label: $0) }
                                        }
                                        .gridColumnAlignment(.trailing)
                                        .frame(minWidth: 110, alignment: .trailing)
                                        Text(item.action)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    Text("R, Space and / don’t work while you’re typing in a box, so typing a year or a search is safe.")
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
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        // / again closes it.
        .onHelpKey { dismiss(); return true }
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
