import Foundation
import Testing
@testable import WinnowKit
import WinnowCore

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

    @Test func ratingIsWrittenToPhotosAndNothingElse() {
        let d0 = Decision.untouched("a")
        let rated = d0.applying(.rate(4), currentFavorite: false)
        #expect(rated.rating == 4)
        #expect(PhotosChange(from: d0, to: rated, currentFavorite: false)
                == PhotosChange(rating: 4))
        #expect(d0.applying(.rate(9), currentFavorite: false).rating == 5)
        let cleared = rated.applying(.rate(0), currentFavorite: false)
        #expect(PhotosChange(from: rated, to: cleared, currentFavorite: false).rating == 0)
    }

    @Test func undoingARatingRestoresPhotosOwnRating() {
        // The photo already had 2 stars in Photos before Winnow touched it.
        var before = Decision.untouched("a")
        before.rating = 2
        let rated = before.applying(.rate(5), currentFavorite: false)
        let undo = Change(label: "Rate", before: [before], after: [rated]).reversed
        #expect(PhotosChange(from: undo.before[0], to: undo.after[0], currentFavorite: false).rating == 2)
    }

    @Test func sameRatingWritesNothing() {
        var d = Decision.untouched("a")
        d.rating = 3
        #expect(PhotosChange(from: d, to: d.applying(.rate(3), currentFavorite: false), currentFavorite: false).isEmpty)
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

@Suite struct RecommenderTests {
    /// 100 analysed photos with curation scores 0.00, 0.01, … 0.99 and otherwise healthy values.
    /// Overall is the same for all of them, so these tests also show it's curation that counts.
    func library(_ extra: [String: AppleScores] = [:]) -> [String: AppleScores] {
        var out: [String: AppleScores] = [:]
        for i in 0..<100 {
            out["p\(i)"] = AppleScores(overall: 0.5, curation: Double(i) / 100, failure: 0, noise: -0.05,
                                        blurriness: 0.9, exposure: 0.9)
        }
        return out.merging(extra) { _, new in new }
    }

    @Test func starsFollowLibraryPercentiles() {
        let r = Recommender(scores: library())
        #expect(r.hasScores)
        #expect(r.suggestion(forUUID: "p0")?.stars == 1)
        #expect(r.suggestion(forUUID: "p15")?.stars == 2)
        #expect(r.suggestion(forUUID: "p50")?.stars == 3)
        #expect(r.suggestion(forUUID: "p80")?.stars == 4)
        #expect(r.suggestion(forUUID: "p95")?.stars == 5)
    }

    @Test func bottomTenPercentIsLowScoreOnly() {
        let r = Recommender(scores: library())
        #expect(r.suggestion(forUUID: "p3")?.reasons == [.lowScore])
        #expect(r.suggestion(forUUID: "p50")?.suggestsReject == false)
    }

    @Test func failureSignalsBecomeReasons() {
        let bad = AppleScores(overall: 0.5, failure: -0.8, noise: -0.7, blurriness: 0.1, exposure: 0.2)
        let r = Recommender(scores: library(["bad": bad]))
        #expect(r.suggestion(forUUID: "bad")?.reasons == [.failed, .blurry, .exposure, .noisy])
        #expect(r.suggestion(forUUID: "bad")?.stars == 3) // a reject reason doesn't change the stars
    }

    @Test func portraitWithSharpSubjectIsNotBlurry() {
        // Soft background drags whole-frame blurriness down, but the subject is tack sharp.
        let portrait = AppleScores(overall: 0.9, failure: 0, noise: -0.05, blurriness: 0.1, exposure: 0.9,
                                   sharpSubject: 0.7, tastefullyBlurred: -0.2)
        let bokeh = AppleScores(overall: 0.9, failure: 0, noise: -0.05, blurriness: 0.1, exposure: 0.9,
                                sharpSubject: 0.0, tastefullyBlurred: 0.6)
        let shaky = AppleScores(overall: 0.5, failure: 0, noise: -0.05, blurriness: 0.1, exposure: 0.9,
                                sharpSubject: 0.0, tastefullyBlurred: -0.5)
        let r = Recommender(scores: library(["portrait": portrait, "bokeh": bokeh, "shaky": shaky]))
        #expect(r.suggestion(forUUID: "portrait")?.reasons.contains(.blurry) == false)
        #expect(r.suggestion(forUUID: "bokeh")?.reasons.contains(.blurry) == false)
        #expect(r.suggestion(forUUID: "shaky")?.reasons.contains(.blurry) == true)
    }

    @Test func fallsBackToOverallWithoutCuration() {
        var scores: [String: AppleScores] = [:]
        for i in 0..<100 { scores["p\(i)"] = AppleScores(overall: Double(i) / 100, failure: 0) }
        let r = Recommender(scores: scores)
        #expect(r.suggestion(forUUID: "p95")?.stars == 5)
        #expect(r.suggestion(forUUID: "p0")?.stars == 1)
    }

    @Test func screenshotsAreSuggestedEvenWithoutScores() {
        let r = Recommender(scores: library(), screenshots: ["shot", "p90"])
        #expect(r.suggestion(forUUID: "shot")?.reasons == [.screenshot])
        #expect(r.suggestion(forUUID: "p90")?.reasons.first == .screenshot)
    }

    @Test func unanalysedPhotosGetNoSuggestion() {
        let r = Recommender(scores: library(["new": AppleScores(overall: 0.5)]))
        #expect(r.suggestion(forUUID: "new") == nil)
        #expect(r.suggestion(forUUID: "missing") == nil)
    }

    @Test func placeholderLibraryHasNoScores() {
        // What a library Photos hasn't analysed looks like: every overall score 0.5.
        var placeholder: [String: AppleScores] = [:]
        for i in 0..<50 { placeholder["p\(i)"] = AppleScores(overall: 0.5, failure: 0) }
        let r = Recommender(scores: placeholder)
        #expect(!r.hasScores)
        #expect(r.suggestion(forUUID: "p1") == nil)
    }

    @Test func countsRejectsAndBest() {
        let r = Recommender(scores: library(), screenshots: ["shot"])
        let c = r.counts()
        #expect(c.rejects == 11) // p0–p9 low score, plus the screenshot
        #expect(c.best == 10)    // p90–p99
    }
}

@Suite struct CalibrationTests {
    @Test func perfectSignalScoresOneAndNoiseScoresHalf() {
        var scores: [String: AppleScores] = [:]
        var favorites = Set<String>()
        for i in 0..<100 {
            // overall separates favorites perfectly; curation is identical for everyone.
            scores["p\(i)"] = AppleScores(overall: Double(i), curation: 0.5, failure: 0)
            if i >= 90 { favorites.insert("p\(i)") }
        }
        let rows = Calibration.agreement(scores: scores, favorites: favorites)
        let overall = rows.first { $0.signal == "overall" }!
        let curation = rows.first { $0.signal == "curation" }!
        #expect(overall.auc == 1)
        #expect(curation.auc == 0.5)
        #expect(rows.first?.signal == "overall")
        #expect(overall.favorites == 10 && overall.others == 90)
    }

    @Test func reversedSignalScoresBelowHalf() {
        var scores: [String: AppleScores] = [:]
        for i in 0..<10 { scores["p\(i)"] = AppleScores(overall: Double(i), failure: 0) }
        let row = Calibration.agreement(scores: scores, favorites: ["p0", "p1"]).first { $0.signal == "overall" }!
        #expect(row.auc == 0)
    }

    @Test func unanalysedPhotosAreIgnored() {
        let scores = ["a": AppleScores(overall: 1, failure: 0), "b": AppleScores(overall: 0, failure: 0),
                      "c": AppleScores(overall: 5)] // not analysed
        let row = Calibration.agreement(scores: scores, favorites: ["a", "c"]).first { $0.signal == "overall" }!
        #expect(row.favorites == 1 && row.others == 1)
        #expect(row.auc == 1)
    }
}
