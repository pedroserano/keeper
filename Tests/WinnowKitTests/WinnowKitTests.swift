import Foundation
import SQLite3
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

    @Test func featurePrintsRoundTrip() throws {
        let store = try DecisionStore()
        let v = FeatureVector((0..<768).map { cos(Float($0)) / 30 })
        try store.saveFeaturePrints(["u1": v, "u2": v])
        #expect(try store.featurePrintUUIDs() == ["u1", "u2"])
        let loaded = try store.featurePrints(for: ["u1"])
        #expect(loaded.count == 1)
        #expect(loaded["u1"]!.distance(to: v) < 0.001)
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

@Suite struct SimilarityTests {
    func date(_ s: Double) -> Date { Date(timeIntervalSinceReferenceDate: s) }

    /// A unit vector pointing mostly along `axis`, nudged by `wobble` toward the next axis.
    func vector(_ axis: Int, wobble: Float = 0) -> FeatureVector {
        var v = [Float](repeating: 0, count: 16)
        v[axis] = 1
        v[(axis + 1) % 16] = wobble
        return FeatureVector(v)
    }

    @Test func clustersChainByTimeGap() {
        let photos = [("a", date(0)), ("b", date(20)), ("c", date(45)),   // chained: each ≤ 30 s from the last
                      ("d", date(200)),                                   // alone
                      ("e", date(500)), ("f", date(505))]
        let clusters = Similarity.timeClusters(photos.map { (uuid: $0.0, date: $0.1) })
        #expect(clusters == [["a", "b", "c"], ["e", "f"]])
    }

    /// Everything taken a second apart, in the given order.
    func dates(_ ids: [String]) -> [String: Date] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, date(Double($0))) })
    }

    @Test func duplicatesAndSimilarShotsAreSeparateGroupings() {
        let ids = ["copy1", "copy2", "take", "other"]
        let vectors: [String: FeatureVector] = [
            "copy1": vector(0), "copy2": vector(0, wobble: 0.01),     // near-identical
            "take":  vector(0, wobble: 0.35),                          // same scene, different take
            "other": vector(5),                                         // different scene, same minute
        ]
        let when = ["copy1": date(0), "copy2": date(0), "take": date(1), "other": date(2)] // a copy keeps the time
        let dupes = Similarity.groups(clusters: [ids], vectors: vectors, dates: when, kind: .duplicate)
        let similar = Similarity.groups(clusters: [ids], vectors: vectors, dates: when, kind: .similar)
        #expect(dupes == [SimilarGroup(members: ["copy1", "copy2"], kind: .duplicate)])
        #expect(similar == [SimilarGroup(members: ["copy1", "copy2", "take"], kind: .similar)])
    }

    @Test func burstFramesAreSimilarNotDuplicates() {
        let ids = ["f1", "f2"]
        let vectors = ["f1": vector(0), "f2": vector(0, wobble: 0.01)]        // as alike as copies
        let when = ["f1": date(10.1), "f2": date(10.4)]                       // but 0.3 s apart
        #expect(Similarity.groups(clusters: [ids], vectors: vectors, dates: when, kind: .duplicate).isEmpty)
        #expect(Similarity.groups(clusters: [ids], vectors: vectors, dates: when, kind: .similar)
                == [SimilarGroup(members: ids, kind: .similar)])
    }

    @Test func copyWithoutSubsecondsIsStillADuplicate() {
        #expect(Similarity.sameMoment(date(5), date(5.43)))
        #expect(Similarity.sameMoment(date(5.43), date(5.435)))
        #expect(!Similarity.sameMoment(date(5.1), date(5.43)))   // two frames of a burst
        #expect(!Similarity.sameMoment(date(5), date(6.2)))
        let ids = ["original", "copy"]
        let vectors = ["original": vector(0), "copy": vector(0, wobble: 0.01)]
        #expect(Similarity.groups(clusters: [ids], vectors: vectors, dates: ["original": date(5.43), "copy": date(5)],
                                  kind: .duplicate) == [SimilarGroup(members: ids, kind: .duplicate)])
    }

    @Test func groupsDontChainAcrossGraduallyChangingShots() {
        // A looks like B and B like C, but A and C look nothing alike: no group may hold A and C.
        let ids = ["a", "b", "c"]
        let vectors = ["a": vector(0), "b": vector(0, wobble: 0.35), "c": vector(0, wobble: 0.8)]
        #expect(vectors["a"]!.distance(to: vectors["c"]!) > Similarity.similarDistance)
        #expect(vectors["b"]!.distance(to: vectors["c"]!) <= Similarity.similarDistance)
        let groups = Similarity.groups(clusters: [ids], vectors: vectors, dates: dates(ids), kind: .similar)
        #expect(groups == [SimilarGroup(members: ["a", "b"], kind: .similar)])
    }

    @Test func groupsStayWithinAMinute() {
        // One time cluster (each shot within 30 s of the last) spanning 100 s; the first and last
        // shots are identical but too far apart to be the same moment.
        let ids = ["p0", "p25", "p50", "p75", "p100"]
        let vectors = ["p0": vector(0), "p25": vector(3), "p50": vector(6), "p75": vector(9), "p100": vector(0)]
        let when = Dictionary(uniqueKeysWithValues: ids.map { ($0, date(Double($0.dropFirst())!)) })
        #expect(Similarity.groups(clusters: [ids], vectors: vectors, dates: when, kind: .duplicate).isEmpty)
    }

    @Test func photosInDifferentClustersAreNeverGrouped() {
        let vectors = ["a": vector(0), "b": vector(0)]
        #expect(Similarity.groups(clusters: [["a"], ["b"]], vectors: vectors, dates: dates(["a", "b"]),
                                  kind: .duplicate).isEmpty)
    }

    @Test func sizeCountsForTheReport() {
        let groups = [SimilarGroup(members: ["a", "b"], kind: .similar), SimilarGroup(members: ["c", "d"], kind: .similar),
                      SimilarGroup(members: ["e", "f", "g"], kind: .similar)]
        let stats = Similarity.sizeCounts(groups)
        #expect(stats.counts == [2: 2, 3: 1])
        #expect(stats.largest == 3)
    }

    @Test func quantizationKeepsDistances() {
        let a = FeatureVector((0..<768).map { sin(Float($0)) / 20 })
        let b = FeatureVector((0..<768).map { sin(Float($0) + 0.3) / 20 })
        let qa = FeatureVector(quantized: a.quantized)!, qb = FeatureVector(quantized: b.quantized)!
        #expect(a.quantized.count == 772)
        #expect(abs(qa.distance(to: qb) - a.distance(to: b)) < 0.005)
        #expect(qa.distance(to: qa) < 0.0001)
    }

    @Test func histogramCountsNearestNeighbours() {
        let vectors = ["a": vector(0), "b": vector(0, wobble: 0.01), "c": vector(9)]
        let h = Similarity.nearestNeighbourHistogram(clusters: [["a", "b", "c"]], vectors: vectors)
        #expect(h.first?.count == 2)               // a and b are each other's nearest, distance ≈ 0
        #expect(h.last?.count == 1)                // c's nearest is far
        #expect(h.map(\.count).reduce(0, +) == 3)
    }
}

@Suite struct GroupSuggestionTests {
    func library() -> [String: AppleScores] {
        var out: [String: AppleScores] = [:]
        for i in 0..<100 {
            out["p\(i)"] = AppleScores(overall: 0.5, curation: Double(i) / 100, failure: 0, noise: -0.05,
                                       blurriness: 0.9, exposure: 0.9)
        }
        return out
    }

    @Test func bestSimilarShotIsKeptAndTheRestAreSuggestedRejects() {
        let r = Recommender(scores: library(), groups: [SimilarGroup(members: ["p40", "p95", "p60"], kind: .similar)])
        #expect(r.suggestion(forUUID: "p95")!.group == GroupInfo(kind: .similar, size: 3, isBest: true))
        #expect(!r.suggestion(forUUID: "p95")!.suggestsReject)
        #expect(r.suggestion(forUUID: "p40")!.reasons.contains(.similar))
        // p60 is in the top 30% by curation, so normally protected; a better shot exists, so not here.
        #expect(r.suggestion(forUUID: "p60")!.suggestsReject)
    }

    @Test func largestCopyIsKeptEvenIfItScoresLower() {
        let files: [String: FileInfo] = [
            "p10": FileInfo(width: 4032, height: 3024, bytes: 3_400_000),
            "p90": FileInfo(width: 1024, height: 768, bytes: 300_000),
            "p50": FileInfo(width: 4032, height: 3024, bytes: 2_100_000),
        ]
        let r = Recommender(scores: library(), groups: [SimilarGroup(members: ["p90", "p10", "p50"], kind: .duplicate)],
                            files: files)
        #expect(r.suggestion(forUUID: "p10")!.group?.isBest == true)
        #expect(r.suggestion(forUUID: "p90")!.reasons.contains(.duplicate))
        #expect(r.suggestion(forUUID: "p50")!.reasons.contains(.duplicate))
        #expect(r.lookAlikes.count == 1 && r.lookAlikes[0].kind == .duplicate)
    }

    @Test func duplicatesAndSimilarShotsAreSeparateGroups() {
        let groups = [SimilarGroup(members: ["p20", "p30"], kind: .duplicate),
                      SimilarGroup(members: ["p20", "p30", "p99"], kind: .similar)]
        let r = Recommender(scores: library(), groups: groups)
        #expect(r.lookAlikes(.duplicate).map(\.members) == [["p30", "p20"]])
        #expect(Set(r.lookAlikes(.similar)[0].members) == ["p20", "p30", "p99"])
        #expect(r.lookAlike(forUUID: "p20", kind: .duplicate)?.kind == .duplicate)
        #expect(r.lookAlike(forUUID: "p99", kind: .duplicate) == nil)
        // p30 is the copy to keep but not the best of its similar shots; p20 is neither.
        #expect(r.suggestion(forUUID: "p30")!.reasons == [.similar])
        #expect(r.suggestion(forUUID: "p20")!.reasons.contains(.duplicate))
        #expect(r.suggestion(forUUID: "p20")!.reasons.contains(.similar))
        #expect(r.suggestion(forUUID: "p99")!.group?.isBest == true)
    }

    @Test func unanalysedDuplicatesStillGetSuggested() {
        var scores = library()
        scores["new"] = AppleScores(overall: 0.5) // not analysed by Photos yet
        let files = ["p80": FileInfo(width: 4000, height: 3000), "new": FileInfo(width: 800, height: 600)]
        let r = Recommender(scores: scores, groups: [SimilarGroup(members: ["p80", "new"], kind: .duplicate)], files: files)
        #expect(r.suggestion(forUUID: "new")?.reasons == [.duplicate])
        #expect(r.suggestion(forUUID: "p80")?.group?.isBest == true)
    }
}

@Suite struct LookAlikeAndMergeTests {
    func score(_ id: String) -> Double { Double(id.dropFirst()) ?? 0 } // "p70" scores 70

    @Test func largestDuplicateIsSuggested() {
        let files = ["p90": FileInfo(width: 1024, height: 768, bytes: 200_000),
                     "p10": FileInfo(width: 4032, height: 3024, bytes: 3_000_000)]
        let g = LookAlikes.build(groups: [SimilarGroup(members: ["p90", "p10"], kind: .duplicate)], score: score, files: files)[0]
        #expect(g.keeper == "p10")
        #expect(g.members == ["p10", "p90"])
    }

    @Test func biggerSimilarShotWinsUnlessItLooksMuchWorse() {
        let big = FileInfo(width: 4032, height: 3024, bytes: 3_000_000)
        let small = FileInfo(width: 1024, height: 768, bytes: 200_000)
        // The biggest file looks second best of three: it's kept over the best-looking small one.
        var g = LookAlikes.build(groups: [SimilarGroup(members: ["p90", "p50", "p10"], kind: .similar)], score: score,
                                 files: ["p90": small, "p50": big, "p10": small])[0]
        #expect(g.keeper == "p50")
        // Two files of the same size: the better-looking of them is kept.
        g = LookAlikes.build(groups: [SimilarGroup(members: ["p90", "p50", "p10"], kind: .similar)], score: score,
                             files: ["p90": small, "p50": big, "p10": big])[0]
        #expect(g.keeper == "p50")
        // All the same size: looks decide.
        g = LookAlikes.build(groups: [SimilarGroup(members: ["p10", "p90", "p50"], kind: .similar)], score: score, files: [:])[0]
        #expect(g.keeper == "p90")
        #expect(g.others == ["p50", "p10"])
    }

    @Test func pickingAnotherKeeperKeepsTheGroupsIdentity() {
        let g = LookAlikes.build(groups: [SimilarGroup(members: ["p10", "p90", "p50"], kind: .similar)], score: score, files: [:])[0]
        let picked = g.keeping("p10")
        #expect(picked.keeper == "p10")
        #expect(picked.members.first == "p10")
        #expect(Set(picked.members) == Set(g.members))
        #expect(picked.id == g.id)
        #expect(g.keeping("elsewhere") == g)
    }

    @Test func mergeCarriesRatingFavoriteAndAlbumsToTheKeeper() {
        let keeper = Decision(assetID: "k", rating: 2, favorite: false)
        let others = [Decision(assetID: "a", rating: 4, favorite: true), Decision(assetID: "b", rating: 1, favorite: false)]
        let merged = Merge.merged(keeper: keeper, others: others, albumsToAdd: ["album-1", "album-2"])
        #expect(merged[0].rating == 4)
        #expect(merged[0].favorite == true)
        #expect(merged[0].flag == Flag.none)
        #expect(merged.dropFirst().allSatisfy { $0.flag == .reject })
        #expect(PhotosChange(from: keeper, to: merged[0])
                == PhotosChange(favorite: true, rating: 4, addAlbums: ["album-1", "album-2"]))
        // Undo takes it out of exactly those albums again.
        #expect(PhotosChange(from: merged[0], to: keeper)
                == PhotosChange(favorite: false, rating: 2, removeAlbums: ["album-1", "album-2"]))
    }

    @Test func addedAlbumsPersist() throws {
        let store = try DecisionStore()
        try store.save([Decision(assetID: "k", addedAlbums: ["album-1"])])
        #expect(try store.all()["k"]?.addedAlbums == ["album-1"])
    }
}

@Suite struct AggressivenessTests {
    func library() -> [String: AppleScores] {
        var out: [String: AppleScores] = [:]
        for i in 0..<200 {
            let x = Double(i) / 200
            out["p\(i)"] = AppleScores(overall: 0.5, curation: x, failure: -0.5 * (1 - x), noise: -0.8 * (1 - x),
                                       blurriness: x, exposure: x)
        }
        return out
    }

    @Test func defaultIsWhatItWas() {
        let t = Recommender.Thresholds()
        #expect(t.failure == -0.25 && t.blurriness == 0.3 && t.exposure == 0.3 && t.noise == -0.5)
        #expect(t.lowScorePercentile == 0.10 && t.protectPercentile == 0.70)
    }

    @Test func moreAggressiveSuggestsMoreRejects() {
        let r = Recommender(scores: library())
        let counts = [0.0, 0.25, 0.5, 0.75, 1.0].map { r.with(aggressiveness: $0).counts().rejects }
        #expect(counts == counts.sorted())
        #expect(counts.first! < counts.last!)
    }

    @Test func starsDontMove() {
        let r = Recommender(scores: library())
        for id in ["p3", "p77", "p150", "p199"] {
            #expect(r.with(aggressiveness: 0).suggestion(forUUID: id)?.stars == r.with(aggressiveness: 1).suggestion(forUUID: id)?.stars)
        }
    }
}

@Suite struct FaceTests {
    func score(_ id: String) -> Double { Double(id.dropFirst()) ?? 0 }
    let big = FileInfo(width: 4032, height: 3024, bytes: 3_000_000)
    let small = FileInfo(width: 1024, height: 768, bytes: 200_000)

    @Test func blinkIsNotSuggestedWhenAnotherTakeHasEyesOpen() {
        // p90 is the biggest and best-looking, but someone blinked.
        let faces = ["p90": FaceInfo(eyesClosed: true, quality: 0.4), "p50": FaceInfo(eyesClosed: false, quality: 0.4)]
        let g = LookAlikes.build(groups: [SimilarGroup(members: ["p90", "p50"], kind: .similar)], score: score,
                                 files: ["p90": big, "p50": small], faces: faces)[0]
        #expect(g.keeper == "p50")
    }

    @Test func everyoneBlinkingChangesNothing() {
        let faces = ["p90": FaceInfo(eyesClosed: true), "p50": FaceInfo(eyesClosed: true)]
        #expect(LookAlikes.blinks(in: ["p90", "p50"], faces: faces).isEmpty)
        let g = LookAlikes.build(groups: [SimilarGroup(members: ["p90", "p50"], kind: .similar)], score: score,
                                 files: ["p90": big, "p50": small], faces: faces)[0]
        #expect(g.keeper == "p90")
    }

    @Test func eyesClosedIsAReasonOnlyNextToAnOpenTake() {
        var scores: [String: AppleScores] = [:]
        for i in 0..<100 {
            scores["p\(i)"] = AppleScores(overall: 0.5, curation: Double(i) / 100, failure: 0, noise: -0.05,
                                          blurriness: 0.9, exposure: 0.9)
        }
        let faces = ["p60": FaceInfo(eyesClosed: true), "p40": FaceInfo(eyesClosed: false), "p20": FaceInfo(eyesClosed: true)]
        let r = Recommender(scores: scores, groups: [SimilarGroup(members: ["p60", "p40"], kind: .similar)], faces: faces)
        #expect(r.suggestion(forUUID: "p60")!.reasons.contains(.eyesClosed))
        #expect(r.suggestion(forUUID: "p40")!.group?.isBest == true)
        #expect(!(r.suggestion(forUUID: "p20")?.reasons.contains(.eyesClosed) ?? false)) // on its own: maybe deliberate
    }

    @Test func readsMainFacesFromPhotosDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = dir.appendingPathComponent("Test.photoslibrary")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("database"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var db: OpaquePointer?
        #expect(sqlite3_open(library.appendingPathComponent("database/Photos.sqlite").path, &db) == SQLITE_OK)
        let sql = """
            CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT);
            CREATE TABLE ZDETECTEDFACE (Z_PK INTEGER PRIMARY KEY, ZASSETFORFACE INTEGER, ZSIZE REAL, ZEYESSTATE INTEGER,
                                        ZQUALITY REAL, ZDETECTIONTYPE INTEGER);
            INSERT INTO ZASSET VALUES (1, 'blink'), (2, 'open'), (3, 'background-blink'), (4, 'pet');
            INSERT INTO ZDETECTEDFACE (ZASSETFORFACE, ZSIZE, ZEYESSTATE, ZQUALITY, ZDETECTIONTYPE) VALUES
                (1, 0.20, 2, 0.6, 1), (1, 0.15, 1, 0.3, 1),   -- two main faces, one blinking
                (2, 0.20, 2, 0.5, 1),
                (3, 0.30, 2, 0.7, 1), (3, 0.05, 1, 0.2, 1),   -- the blinker is small, in the background
                (4, 0.30, 1, 0.5, 3);                          -- not a person
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let faces = try PhotosDatabase.readFaceInfo(inLibrary: library)
        #expect(faces["blink"] == FaceInfo(eyesClosed: true, quality: 0.3))
        #expect(faces["open"] == FaceInfo(eyesClosed: false, quality: 0.5))
        #expect(faces["background-blink"] == FaceInfo(eyesClosed: false, quality: 0.7))
        #expect(faces["pet"] == nil)
    }
}

@Suite struct GroupCarryOverTests {
    let groups = [SimilarGroup(members: ["a1", "a2"], kind: .duplicate),          // was a1, a2, a3
                  SimilarGroup(members: ["b1", "b2", "b3"], kind: .similar),       // was duplicates b1, b2
                  SimilarGroup(members: ["c2", "c3"], kind: .duplicate)]           // was c1, c2, c3
    let previous = [SimilarGroup(members: ["a1", "a2", "a3"], kind: .duplicate),
                    SimilarGroup(members: ["b1", "b2"], kind: .duplicate),
                    SimilarGroup(members: ["c1", "c2", "c3"], kind: .duplicate)]

    func map(_ selected: Set<String>, _ choices: [String: String] = [:]) -> GroupCarryOver.Result {
        GroupCarryOver.map(selected: selected, choices: choices, groups: groups, previous: previous)
    }

    @Test func tickOnAGoneDuplicateMovesToTheSimilarGroupHoldingItsPhotos() {
        let r = map(["d:b1", "s:x"])
        #expect(r.selected == ["s:b1", "s:x"])
        #expect(r.moved == 1 && r.leftAlone == 0)
    }

    @Test func tickOnADuplicateWhoseIdChangedFollowsIt() {
        // c1 dropped out, so the group is now named after c2.
        let r = map(["d:a1", "d:c1"])
        #expect(r.selected == ["d:a1", "d:c2"])
        #expect(r.moved == 1)
    }

    @Test func keeperPickFollowsThePickedPhoto() {
        let r = map([], ["d:b1": "b2", "d:c1": "c3", "s:b1": "b3"])
        #expect(r.choices == ["d:b1": "b2", "d:c2": "c3", "s:b1": "b3"])  // s:b1 already had a pick: kept
        #expect(r.moved == 1 && r.leftAlone == 1)
    }

    @Test func entriesWithNoNewHomeAreLeftAsTheyAre() {
        let r = map(["d:zz"], ["d:zz": "zz2"])
        #expect(r.selected == ["d:zz"] && r.choices == ["d:zz": "zz2"])
        #expect(r.moved == 0 && r.leftAlone == 2)
    }
}

@Suite struct RotationTests {
    @Test func degreesWrapToQuarterTurns() {
        #expect(Rotation(degrees: 90) == .clockwise90)
        #expect(Rotation(degrees: -90) == .clockwise270)
        #expect(Rotation(degrees: 360) == Rotation.none)
        #expect(Rotation(degrees: 450) == .clockwise90)
        #expect(Rotation.clockwise90.followed(by: .clockwise270) == Rotation.none)
        #expect(Rotation.clockwise90.inverse == .clockwise270)
    }

    @Test func undoingARotationRotatesBack() {
        let change = Change(label: "Rotate", before: [], after: [], rotations: ["p": 90])
        #expect(change.reversed.rotations == ["p": -90])
        #expect(Rotation(degrees: change.reversed.rotations["p"]!) == .clockwise270)
        var history = History()
        history.record(change)
        #expect(history.undo()?.rotations == ["p": -90])
        #expect(history.redo()?.rotations == ["p": 90])
    }
}
