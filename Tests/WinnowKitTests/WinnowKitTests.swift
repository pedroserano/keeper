import Foundation
import Testing
@testable import WinnowKit

@Suite struct DecisionTests {
    @Test func pickRemembersOriginalFavoriteAndClearingRestoresIt() {
        let d0 = Decision.untouched("a")
        let picked = d0.applying(.pick, currentFavorite: false)
        #expect(picked.flag == .pick)
        #expect(picked.originalFavorite == false)
        #expect(PhotosChange(from: d0, to: picked, currentFavorite: false).favorite == true)

        // Photos now shows it as a favorite; clearing should put it back to not-favorite.
        let cleared = picked.applying(.clearFlag, currentFavorite: true)
        #expect(cleared.flag == .none)
        #expect(PhotosChange(from: picked, to: cleared, currentFavorite: true).favorite == false)
    }

    @Test func pickOnAnExistingFavoriteChangesNothingInPhotos() {
        let d0 = Decision.untouched("a")
        let picked = d0.applying(.pick, currentFavorite: true)
        let change = PhotosChange(from: d0, to: picked, currentFavorite: true)
        #expect(change.favorite == nil)
        #expect(change.isEmpty)
        // And clearing keeps it a favorite, because it was one before Winnow.
        let cleared = picked.applying(.clearFlag, currentFavorite: true)
        #expect(PhotosChange(from: picked, to: cleared, currentFavorite: true).isEmpty)
    }

    @Test func pickThenRejectRestoresFavoriteAndMovesIntoRejectAlbum() {
        let picked = Decision.untouched("a").applying(.pick, currentFavorite: false)
        let rejected = picked.applying(.reject, currentFavorite: true)
        let change = PhotosChange(from: picked, to: rejected, currentFavorite: true)
        #expect(change.favorite == false)
        #expect(change.inRejectAlbum == true)
        #expect(rejected.originalFavorite == false) // first value is kept
    }

    @Test func ratingTouchesNothingInPhotos() {
        let d0 = Decision.untouched("a")
        let rated = d0.applying(.rate(4), currentFavorite: false)
        #expect(rated.rating == 4)
        #expect(PhotosChange(from: d0, to: rated, currentFavorite: false).isEmpty)
        #expect(d0.applying(.rate(9), currentFavorite: false).rating == 5)
        #expect(rated.applying(.rate(0), currentFavorite: false).rating == 0)
    }

    @Test func hideToggles() {
        let d0 = Decision.untouched("a")
        let hidden = d0.applying(.toggleHidden, currentFavorite: false)
        #expect(PhotosChange(from: d0, to: hidden, currentFavorite: false).hidden == true)
        let shown = hidden.applying(.toggleHidden, currentFavorite: false)
        #expect(PhotosChange(from: hidden, to: shown, currentFavorite: false).hidden == false)
    }

    @Test func undoingARejectLeavesTheAlbum() {
        let d0 = Decision.untouched("a")
        let rejected = d0.applying(.reject, currentFavorite: false)
        let undo = Change(label: "Reject", before: [d0], after: [rejected]).reversed
        let change = PhotosChange(from: undo.before[0], to: undo.after[0], currentFavorite: false)
        #expect(change.inRejectAlbum == false)
        #expect(change.favorite == nil)
    }
}

@Suite struct HistoryTests {
    func change(_ label: String) -> Change {
        Change(label: label, before: [.untouched(label)], after: [Decision(assetID: label, flag: .reject)])
    }

    @Test func undoRedoOrder() {
        var h = History()
        h.record(change("a"))
        h.record(change("b"))
        #expect(h.undo()?.label == "b")
        #expect(h.undo()?.label == "a")
        #expect(h.undo() == nil)
        #expect(h.redo()?.label == "a")
        #expect(h.canRedo)
    }

    @Test func undoReturnsReversedChange() {
        var h = History()
        let c = change("a")
        h.record(c)
        let u = h.undo()!
        #expect(u.before == c.after)
        #expect(u.after == c.before)
        #expect(h.redo() == c)
    }

    @Test func newActionClearsRedo() {
        var h = History()
        h.record(change("a"))
        _ = h.undo()
        h.record(change("b"))
        #expect(!h.canRedo)
    }

    @Test func limitDropsOldest() {
        var h = History(limit: 2)
        h.record(change("a")); h.record(change("b")); h.record(change("c"))
        #expect(h.undoStack.map(\.label) == ["b", "c"])
    }
}

@Suite struct StoreTests {
    @Test func saveLoadRemove() throws {
        let store = try DecisionStore()
        let d = Decision(assetID: "x/L0/001", rating: 3, flag: .reject, originalFavorite: true, seenAt: Date())
        try store.save([d, Decision(assetID: "y/L0/001", flag: .pick)])
        let all = try store.all()
        #expect(all.count == 2)
        #expect(all["x/L0/001"]?.rating == 3)
        #expect(all["x/L0/001"]?.originalFavorite == true)
        #expect(try store.rejected().map(\.assetID) == ["x/L0/001"])
        try store.remove(["x/L0/001"])
        #expect(try store.all().count == 1)
    }

    @Test func settingsRoundTrip() throws {
        let store = try DecisionStore()
        #expect(try store.setting("source") == nil)
        try store.setSetting("source", to: "allPhotos")
        #expect(try store.setting("source") == "allPhotos")
    }

    @Test func storeURLIsStablePerLibrary() {
        let a = DecisionStore.url(forLibrary: URL(fileURLWithPath: "/Users/me/Pictures/Test.photoslibrary"))
        let b = DecisionStore.url(forLibrary: URL(fileURLWithPath: "/Users/me/Pictures/Test.photoslibrary"))
        let c = DecisionStore.url(forLibrary: URL(fileURLWithPath: "/Volumes/Ext/Test.photoslibrary"))
        #expect(a == b)
        #expect(a != c)
        #expect(a.lastPathComponent.hasPrefix("Test-"))
    }
}
