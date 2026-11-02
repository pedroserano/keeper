import Foundation
import Testing
@testable import WinnowKit
import WinnowCore

@Suite struct DecisionTests {
    /// What the session hands over: the decision with Photos' current Favorite and rating filled in.
    func fromPhotos(favorite: Bool = false, rating: Int = 0) -> Decision {
        Decision(assetID: "a", rating: rating, favorite: favorite, updatedAt: .distantPast)
    }

    @Test func favoriteTogglesAndUndoRestores() {
        let d0 = fromPhotos(favorite: false)
        let fav = d0.applying(.toggleFavorite, currentFavorite: false)
        #expect(PhotosChange(from: d0, to: fav) == PhotosChange(favorite: true))
        let undo = Change(label: "Favorite", before: [d0], after: [fav]).reversed
        #expect(PhotosChange(from: undo.before[0], to: undo.after[0]).favorite == false)
    }

    @Test func unfavoritingWorksOnPhotosFavorites() {
        let d0 = fromPhotos(favorite: true)
        #expect(PhotosChange(from: d0, to: d0.applying(.toggleFavorite, currentFavorite: true)).favorite == false)
    }

    @Test func favoriteFallsBackToPhotosWhenNotFilledIn() {
        let d0 = Decision.untouched("a")
        #expect(d0.applying(.toggleFavorite, currentFavorite: true).favorite == false)
        #expect(d0.applying(.toggleFavorite, currentFavorite: false).favorite == true)
    }

    @Test func rejectingAFavoriteLeavesItAFavorite() {
        // The delete sheet warns about favorites instead.
        let d0 = fromPhotos(favorite: true)
        let rejected = d0.applying(.reject, currentFavorite: true)
        #expect(PhotosChange(from: d0, to: rejected) == PhotosChange(inRejectAlbum: true))
        let cleared = rejected.applying(.clearFlag, currentFavorite: true)
        #expect(PhotosChange(from: rejected, to: cleared) == PhotosChange(inRejectAlbum: false))
    }

    @Test func ratingIsWrittenToPhotosAndNothingElse() {
        let d0 = fromPhotos()
        let rated = d0.applying(.rate(4), currentFavorite: false)
        #expect(rated.rating == 4)
        #expect(PhotosChange(from: d0, to: rated) == PhotosChange(rating: 4))
        #expect(d0.applying(.rate(9), currentFavorite: false).rating == 5)
        let cleared = rated.applying(.rate(0), currentFavorite: false)
        #expect(PhotosChange(from: rated, to: cleared).rating == 0)
    }

    @Test func undoingARatingRestoresPhotosOwnRating() {
        let before = fromPhotos(rating: 2) // already 2 stars in Photos
        let rated = before.applying(.rate(5), currentFavorite: false)
        let undo = Change(label: "Rate", before: [before], after: [rated]).reversed
        #expect(PhotosChange(from: undo.before[0], to: undo.after[0]).rating == 2)
    }

    @Test func sameRatingWritesNothing() {
        let d = fromPhotos(rating: 3)
        #expect(PhotosChange(from: d, to: d.applying(.rate(3), currentFavorite: false)).isEmpty)
    }

    @Test func hideToggles() {
        let d0 = fromPhotos()
        let hidden = d0.applying(.toggleHidden, currentFavorite: false)
        #expect(PhotosChange(from: d0, to: hidden).hidden == true)
        let shown = hidden.applying(.toggleHidden, currentFavorite: false)
        #expect(PhotosChange(from: hidden, to: shown).hidden == false)
    }

    @Test func undoingARejectLeavesTheAlbum() {
        let d0 = fromPhotos()
        let rejected = d0.applying(.reject, currentFavorite: false)
        let undo = Change(label: "Reject", before: [d0], after: [rejected]).reversed
        #expect(PhotosChange(from: undo.before[0], to: undo.after[0]) == PhotosChange(inRejectAlbum: false))
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
        let d = Decision(assetID: "x/L0/001", rating: 3, flag: .reject, favorite: true, seenAt: Date())
        try store.save([d, Decision(assetID: "y/L0/001", flag: .none)])
        let all = try store.all()
        #expect(all.count == 2)
        #expect(all["x/L0/001"]?.rating == 3)
        #expect(all["x/L0/001"]?.favorite == true)
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

@Suite struct LearningTests {
    /// Rated photos whose rating follows composition (your taste), while curation is unrelated noise
    /// (think: nostalgia) and overall is constant.
    func ratedByComposition(_ n: Int) -> [RatedPhoto] {
        (0..<n).map { i in
            let composition = Double(i % 50) / 50          // 0…0.98
            let curation = Double((i * 37) % 101) / 101    // unrelated to the rating
            let rating = 1 + Int(composition * 5)          // 1…5
            return RatedPhoto(uuid: "r\(i)", scores: AppleScores(overall: 0.5, curation: curation, failure: 0,
                                                                  composition: composition),
                              rating: rating)
        }
    }

    @Test func modelLearnsWhatDrivesYourRatings() {
        let photos = ratedByComposition(200)
        let model = RatingModel.fit(photos)!
        let composition = RatingModel.features.firstIndex { $0.0 == "composition" }!
        let strongest = model.weights.indices.max { abs(model.weights[$0]) < abs(model.weights[$1]) }!
        #expect(strongest == composition)
        #expect(model.weights[composition] > 0)
        #expect(model.predict(AppleScores(curation: 0.5, failure: 0, composition: 0.95))
                > model.predict(AppleScores(curation: 0.5, failure: 0, composition: 0.05)))
    }

    @Test func modelBeatsCurationWhenCurationIsntYourTaste() {
        let e = RatingEvaluation.evaluate(ratedByComposition(200))
        #expect(e.enoughRatings)
        #expect(e.model > 0.9)
        #expect(abs(e.curation) < 0.3)
        #expect(e.modelWins)
    }

    @Test func tooFewRatingsNeverWin() {
        let e = RatingEvaluation.evaluate(ratedByComposition(30))
        #expect(!e.enoughRatings)
        #expect(!e.modelWins)
    }

    @Test func recommenderRanksByModelWhenGiven() {
        var scores: [String: AppleScores] = [:]
        for i in 0..<100 {
            // Curation runs opposite to composition here; the model should follow composition.
            scores["p\(i)"] = AppleScores(overall: 0.5, curation: 1 - Double(i) / 100, failure: 0,
                                          composition: Double(i) / 100)
        }
        let model = RatingModel.fit(ratedByComposition(200))!
        let r = Recommender(scores: scores, model: model)
        #expect(r.suggestion(forUUID: "p99")?.stars == 5)
        #expect(r.suggestion(forUUID: "p0")?.stars == 1)
        #expect(Recommender(scores: scores).suggestion(forUUID: "p99")?.stars == 1) // curation says otherwise
    }

    @Test func solveHandlesASimpleSystem() {
        // 2x + y = 5, x + 3y = 10  →  x = 1, y = 3
        let x = RatingModel.solve([[2, 1], [1, 3]], [5, 10])!
        #expect(abs(x[0] - 1) < 1e-9 && abs(x[1] - 3) < 1e-9)
    }
}

@Suite struct ProtectionTests {
    func library() -> [String: AppleScores] {
        var out: [String: AppleScores] = [:]
        for i in 0..<100 {
            out["p\(i)"] = AppleScores(overall: 0.5, curation: Double(i) / 100, failure: 0, noise: -0.05,
                                       blurriness: 0.9, exposure: 0.9)
        }
        return out
    }

    @Test func meaningfulPhotosAreNotSuggestedRejects() {
        var scores = library()
        // High curation (something Photos thinks matters to you) but technically poor.
        scores["keepsake"] = AppleScores(overall: 0.2, curation: 0.95, failure: -0.8, noise: -0.05,
                                         blurriness: 0.1, exposure: 0.9)
        scores["dud"] = AppleScores(overall: 0.2, curation: 0.2, failure: -0.8, noise: -0.05,
                                    blurriness: 0.1, exposure: 0.9)
        let r = Recommender(scores: scores)
        let keepsake = r.suggestion(forUUID: "keepsake")!
        #expect(keepsake.protected)
        #expect(keepsake.reasons.contains(.failed)) // the reason still shows
        #expect(!keepsake.suggestsReject)
        #expect(r.suggestion(forUUID: "dud")!.suggestsReject)
    }

    @Test func screenshotsAreNeverProtected() {
        var scores = library()
        scores["shot"] = AppleScores(overall: 0.5, curation: 0.99, failure: 0)
        let r = Recommender(scores: scores, screenshots: ["shot"])
        #expect(r.suggestion(forUUID: "shot")!.suggestsReject)
    }

    @Test func calibrationSampleSpreadsAcrossTheRange() {
        var scores: [String: AppleScores] = [:]
        for i in 0..<1000 { scores["p\(i)"] = AppleScores(overall: 0.5, curation: Double(i) / 1000, failure: 0) }
        let r = Recommender(scores: scores, screenshots: ["p5"])
        let sample = r.calibrationSample(count: 150, excluding: ["p1", "p2"])
        #expect(sample.count == 150)
        #expect(Set(sample).count == 150)
        #expect(!sample.contains("p1") && !sample.contains("p5"))
        // About 15 from each tenth of the range. (Not exactly: the excluded photos shift the bin
        // edges by a photo or two.)
        let tenths = Dictionary(grouping: sample) { Int($0.dropFirst())! / 100 }.mapValues(\.count)
        #expect(tenths.count == 10)
        #expect(tenths.values.allSatisfy { (13...17).contains($0) })
        #expect(r.calibrationSample(count: 150, excluding: ["p1", "p2"]) == sample) // stable
    }
}
