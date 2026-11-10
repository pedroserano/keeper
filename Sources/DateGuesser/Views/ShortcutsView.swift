import SwiftUI
import KeeperUI

extension Notification.Name {
    /// Help ▸ Keyboard Shortcuts asks the window to show the guide.
    static let showKeyboardShortcuts = Notification.Name("showKeyboardShortcuts")
}

/// The keyboard shortcuts guide for the Dates screens, shown with ? or the keyboard button.
struct ShortcutsView: View {
    var screen = "Dates"

    static let sections: [ShortcutSection] = [
        ShortcutSection("Review and Places", [
            Shortcut(["A"], "Accept the guess: select the photo to apply, and go to the next"),
            Shortcut(["N"], "Don’t show the photo again (in Not Shown: show it again)"),
            Shortcut(["Return"], "The photo's details (in Places, its map); ⌘I too"),
            Shortcut(["⌘", "D"], "Give every selected photo one date"),
            Shortcut(["⌘", "L"], "Give every selected photo one place"),
        ]),
        ShortcutSection("Events", [
            Shortcut(["Click"], "Show the photo filling the window (Space over it too)"),
            Shortcut(["←", "→"], "Previous or next photo while it fills the window"),
        ]),
        ShortcutSection("Dialogs", [
            Shortcut(["Return"], "Confirm the date, place or dialog"),
            Shortcut(["Esc"], "Cancel"),
        ]),
    ]

    var body: some View {
        KeeperShortcutGuide(screen: screen, sections: Self.sections)
            // ? again closes it.
            .onHelpKey { dismissGuide(); return true }
    }

    @Environment(\.dismiss) private var dismissGuide
}
