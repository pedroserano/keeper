// One open library: what's being culled, where the cursor is, and every decision made.
//
// Built for big libraries: the photo list is PhotoKit's own lazy fetch result, so opening never
// loads every photo. Filters that must look at every photo, and the sidebar counts, run in the
// background.
//
// Decisions apply instantly to the screen and Winnow's database, then are written to Photos
// in order on a serial queue. If a Photos write fails, that decision is rolled back.

import AppKit
import os
import Photos
import SwiftUI
import WinnowCore
import WinnowKit

let log = Logger(subsystem: "local.winnow", category: "session")

/// The photos being culled, in order. Indexes into a PhotoKit fetch result instead of holding
/// the photos, so a 100,000-photo library costs almost nothing until photos are on screen.
struct AssetList: @unchecked Sendable {
    let result: PHFetchResult<PHAsset>
    /// Positions in `result` that pass the filter, in display order; nil means all of them.
    let positions: [Int]?
    /// False when `positions` is in a custom order (suggestions are sorted by score).
    var ascending = true

    var count: Int { positions?.count ?? result.count }
    var isEmpty: Bool { count == 0 }
    var indices: Range<Int> { 0..<count }

    func asset(at index: Int) -> PHAsset { result.object(at: positions?[index] ?? index) }

    func index(of asset: PHAsset) -> Int? {
        let position = result.index(of: asset)
        guard position != NSNotFound else { return nil }
        guard let positions else { return position }
        guard ascending else { return positions.firstIndex(of: position) }
        // Binary search: positions are ascending.
        var lo = 0, hi = positions.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if positions[mid] == position { return mid }
            if positions[mid] < position { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    static let empty = AssetList(result: PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil), positions: nil)
}

@MainActor
final class CullingSession: ObservableObject {
    enum Mode: String { case grid, single, compare }

    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all = "All", unflagged = "Unflagged", favorites = "Favorites", rejects = "Rejects"
        var id: String { rawValue }
    }

    enum SuggestionsStatus: Equatable {
        case loading
        case ready
        case notAnalysed        // Photos hasn't scored this library yet
        case unavailable(String)
    }

    let library: PhotoLibrary
    let store: DecisionStore
    let libraryName: String
    let libraryURL: URL

    @Published private(set) var source: Source = .allPhotos
    @Published private(set) var recommender: Recommender?
    @Published private(set) var suggestionsStatus = SuggestionsStatus.loading

    enum LearningStatus: Equatable {
        case waiting
        case learning
        /// Stars follow a model of your own ratings.
        case fitted(RatingEvaluation)
        /// Stars follow curation: too few ratings, or your ratings agree with curation as well.
        case usingCuration(RatingEvaluation)
    }

    @Published private(set) var learning = LearningStatus.waiting
    /// Unrated photos spread across the score range, for "Rate to Calibrate". Kept between launches.
    @Published private(set) var calibrationSample: [String] = []
    /// The Apple-scores panel in single view (I).
    @Published var showingScores = false
    @Published var filter: Filter = .all { didSet { if filter != oldValue { reload() } } }
    @Published var newestFirst = false { didSet { if newestFirst != oldValue { reload() } } }
    @Published var mode: Mode = .grid { didSet { modeChanged(from: oldValue) } }
    @Published private(set) var list = AssetList.empty
    /// True while a filter is being worked out in the background.
    @Published private(set) var loading = false
    @Published private(set) var cursor = 0
    @Published private(set) var decisions: [String: Decision] = [:]
    @Published private(set) var history = History()
    @Published private(set) var counts: [Source: Int] = [:]

    @Published var zoomed = false
    @Published private(set) var zoomOnFace = false
    @Published private(set) var compareGroup: [PHAsset] = []
    @Published private(set) var compareFocus = 0
    @Published var allowDownloads = false
    @Published var message: String?

    /// Set by the grid so ↑ ↓ move a whole row.
    var gridColumns = 1

    private var filterTask: Task<Void, Never>?
    private var countsTask: Task<Void, Never>?
    private var writes: Task<Void, Never>?
    /// Ratings and Favorites Winnow has written that Photos hasn't reported back yet, so the
    /// stars and heart don't flicker back to the old value while the write is under way.
    private var pendingRatings: [String: Int] = [:]
    private var pendingFavorites: [String: Bool] = [:]
    private var photosWritesInFlight: [String: Int] = [:]
    private var messageTask: Task<Void, Never>?

    init(library: PhotoLibrary, store: DecisionStore, libraryURL: URL) {
        self.library = library
        self.store = store
        self.libraryURL = libraryURL
        self.libraryName = libraryURL.deletingPathExtension().lastPathComponent
        let started = ContinuousClock.now
        decisions = (try? store.all()) ?? [:]
        if let json = try? store.setting("calibrationSample"), let data = json.data(using: .utf8) {
            calibrationSample = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        if let json = try? store.setting("source"), let data = json.data(using: .utf8),
           let saved = try? JSONDecoder().decode(Source.self, from: data) {
            source = saved
        }
        log.notice("open: loaded \(self.decisions.count) decisions in \(started.duration(to: .now))")
        library.onChange = { [weak self] change in self?.libraryChanged(change) }
        reload(restoreFrom: (try? store.setting("cursor.\(source.key)")) ?? nil)
        refreshCounts()
        loadSuggestions()
    }

    // MARK: Suggestions

    /// Reads Apple's scores for every photo (one read-only query, well under a second for
    /// 200,000 photos) and builds the suggestions from them, in the background.
    func loadSuggestions() {
        suggestionsStatus = .loading
        let url = libraryURL, library = library
        Task { [weak self] in
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .utility) { () -> Result<Recommender, Error> in
                do {
                    let scores = try PhotosDatabase.readAppleScores(inLibrary: url)
                    return .success(Recommender(scores: scores, screenshots: library.uuids(in: .screenshots)))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(let r):
                log.notice("open: read \(r.scores.count) photos' Apple scores in \(started.duration(to: .now))")
                self.recommender = r
                self.suggestionsStatus = r.hasScores ? .ready : .notAnalysed
                if self.source.isSuggestion { self.reload() }
                self.refreshCounts()
                if r.hasScores {
                    self.saveCalibration(r)
                    self.learnFromRatings()
                }
            case .failure(let error):
                self.suggestionsStatus = .unavailable(error.localizedDescription)
                if self.source.isSuggestion { self.loading = false }
            }
        }
    }

    /// Measures how well each of Apple's scores ranks your Favorites above the rest, and saves the
    /// summary to ~/Documents/Winnow/out/score-calibration.csv. Summary numbers only, no per-photo data.
    private func saveCalibration(_ r: Recommender) {
        let library = library, libraryName = libraryName
        Task.detached(priority: .background) {
            let favorites = library.uuids(in: .favorites)
            let rows = Calibration.agreement(scores: r.scores, favorites: favorites)
            var csv = "library,signal,auc,favorites,others,favoritesMean,othersMean\n"
            for row in rows {
                csv += [libraryName, row.signal, String(format: "%.4f", row.auc), String(row.favorites),
                        String(row.others), String(format: "%.4f", row.favoritesMean),
                        String(format: "%.4f", row.othersMean)].joined(separator: ",") + "\n"
            }
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Winnow/out")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? csv.write(to: dir.appendingPathComponent("score-calibration.csv"), atomically: true, encoding: .utf8)
            log.notice("calibration: \(rows.count) signals against \(favorites.count) favorites")
        }
    }

    /// Reads the ratings you've given in Photos, checks how well a model of them predicts ratings it
    /// wasn't fitted to, and switches the stars to that model if it beats curation. Background work;
    /// a few seconds for a big library.
    func learnFromRatings() {
        guard let base = recommender, base.hasScores, learning != .learning else { return }
        learning = .learning
        let library = library, libraryName = libraryName, existingSample = calibrationSample
        Task { [weak self] in
            let started = ContinuousClock.now
            let (evaluation, updated, sample) = await Task.detached(priority: .utility) {
                let ratings = library.photoRatings()
                let rated = ratings.compactMap { uuid, rating -> RatedPhoto? in
                    guard let s = base.scores[uuid], s.isAnalysed else { return nil }
                    return RatedPhoto(uuid: uuid, scores: s, rating: rating)
                }
                let evaluation = RatingEvaluation.evaluate(rated)
                let model = evaluation.modelWins ? RatingModel.fit(rated) : nil
                let updated = Recommender(scores: base.scores, screenshots: base.screenshots, model: model)
                let sample = existingSample.isEmpty
                    ? updated.calibrationSample(excluding: Set(ratings.keys)) : existingSample
                Self.saveLearningReport(evaluation, model: model, libraryName: libraryName)
                return (evaluation, updated, sample)
            }.value
            guard let self else { return }
            log.notice("learning: \(evaluation.rated) ratings, model \(evaluation.model), curation \(evaluation.curation) in \(started.duration(to: .now))")
            self.recommender = updated
            self.learning = updated.model != nil ? .fitted(evaluation) : .usingCuration(evaluation)
            if self.calibrationSample != sample {
                self.calibrationSample = sample
                if let data = try? JSONEncoder().encode(sample) {
                    try? self.store.setSetting("calibrationSample", to: String(decoding: data, as: UTF8.self))
                }
            }
            if self.source.isSuggestion { self.reload() }
            self.refreshCounts()
        }
    }

    /// Summary of what was learned, in ~/Documents/Winnow/out/rating-calibration.csv: how well each
    /// way of ranking agrees with your ratings, and the model's weights. No per-photo data.
    nonisolated private static func saveLearningReport(_ e: RatingEvaluation, model: RatingModel?, libraryName: String) {
        var csv = "library,measure,value\n"
        let rows: [(String, String)] = [
            ("ratings", String(e.rated)), ("distinctRatings", String(e.distinctRatings)),
            ("agreement.model.heldOut", String(format: "%.4f", e.model)),
            ("agreement.curation", String(format: "%.4f", e.curation)),
            ("agreement.overall", String(format: "%.4f", e.overall)),
            ("usingModel", String(model != nil)),
        ] + (model.map { m in zip(RatingModel.features, m.weights).map { ("weight.\($0.0)", String(format: "%.4f", $1)) } } ?? [])
        for (measure, value) in rows { csv += "\(libraryName),\(measure),\(value)\n" }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Winnow/out")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? csv.write(to: dir.appendingPathComponent("rating-calibration.csv"), atomically: true, encoding: .utf8)
    }

    func suggestion(_ asset: PHAsset) -> Suggestion? {
        recommender?.suggestion(forUUID: String(asset.localIdentifier.split(separator: "/").first ?? ""))
    }

    /// A: take the suggested star rating.
    func acceptSuggestedRating() {
        guard let asset = target, let s = suggestion(asset), s.stars > 0 else { return }
        perform(.rate(s.stars))
    }

    // MARK: State

    var current: PHAsset? { list.indices.contains(cursor) ? list.asset(at: cursor) : nil }

    /// The photo the next decision applies to: the focused frame in compare, otherwise the cursor.
    var target: PHAsset? {
        mode == .compare && compareGroup.indices.contains(compareFocus) ? compareGroup[compareFocus] : current
    }

    /// Winnow's record for a photo, with the rating taken from Photos itself (macOS 27 ratings),
    /// so ratings you gave in Photos show here and Photos is the one place they live.
    func decision(_ asset: PHAsset) -> Decision {
        var d = decisions[asset.localIdentifier] ?? .untouched(asset.localIdentifier)
        d.rating = pendingRatings[asset.localIdentifier] ?? asset.rating.rawValue
        d.favorite = pendingFavorites[asset.localIdentifier] ?? asset.isFavorite
        return d
    }

    /// Favorite as it will be once pending writes land, so the heart updates the moment you press F.
    func isFavorite(_ asset: PHAsset) -> Bool {
        decision(asset).favorite ?? asset.isFavorite
    }

    var rejectCount: Int { decisions.values.filter { $0.flag == .reject }.count }

    // MARK: Sources and filters

    func select(_ newSource: Source) {
        guard newSource != source else { return }
        if source == .calibrate { learnFromRatings() }
        saveCursor()
        source = newSource
        if let data = try? JSONEncoder().encode(newSource) {
            try? store.setSetting("source", to: String(decoding: data, as: UTF8.self))
        }
        zoomed = false
        reload(restoreFrom: (try? store.setting("cursor.\(newSource.key)")) ?? nil)
    }

    /// Fetches the source (lazy, fast) and applies the filter. Decisions don't call this, so the
    /// list stays put while you work; switching source or filter does.
    private func reload(restoreFrom id: String? = nil) {
        let keepID = id ?? current?.localIdentifier
        let started = ContinuousClock.now
        let result = library.fetch(source, newestFirst: newestFirst)
        log.notice("open: fetched \(result.count) photos for \(self.source.title) in \(started.duration(to: .now))")
        apply(result, keepingID: keepID)
    }

    private func apply(_ result: PHFetchResult<PHAsset>, keepingID: String?) {
        filterTask?.cancel()
        let keepAsset = keepingID.flatMap { library.assets(withIDs: [$0]).first }

        // The common case needs no scan: every photo in the source, straight from PhotoKit.
        if filter == .all && source != .unreviewed && !source.isSuggestion {
            loading = false
            setList(AssetList(result: result, positions: nil), keeping: keepAsset)
            return
        }

        // Suggestion sources wait for Apple's scores; loadSuggestions() reloads when they arrive.
        loading = true
        if source.isSuggestion && recommender == nil {
            if case .unavailable = suggestionsStatus { loading = false }
            list = .empty
            return
        }

        // Anything else means checking each photo; do that in the background.
        let snapshot = decisions
        let filter = filter
        let source = source
        let recommender = recommender
        let sampleOrder = Dictionary(calibrationSample.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        filterTask = Task { [weak self] in
            let started = ContinuousClock.now
            let (positions, ordered) = await Task.detached(priority: .userInitiated) { () -> ([Int], Bool) in
                var out: [(position: Int, keep: Double)] = []
                result.enumerateObjects { asset, i, _ in
                    let d = snapshot[asset.localIdentifier]
                    if source == .unreviewed, d?.seenAt != nil { return }
                    let flag = d?.flag ?? .none
                    switch filter {
                    case .all: break
                    case .unflagged: if flag != .none { return }
                    case .favorites: if !asset.isFavorite { return }
                    case .rejects: if flag != .reject { return }
                    }
                    guard source.isSuggestion else { out.append((i, 0)); return }
                    let uuid = String(asset.localIdentifier.split(separator: "/").first ?? "")
                    if source == .calibrate {
                        if let order = sampleOrder[uuid] { out.append((i, Double(order))) }
                        return
                    }
                    guard let s = recommender?.suggestion(forUUID: uuid) else { return }
                    switch source {
                    case .suggestedRejects where s.suggestsReject: out.append((i, s.keep))
                    case .bestShots where s.stars == 5 && !s.suggestsReject: out.append((i, s.keep))
                    default: break
                    }
                }
                // Suggested rejects worst first; best shots best first.
                switch source {
                case .suggestedRejects: out.sort { $0.keep < $1.keep }
                case .bestShots: out.sort { $0.keep > $1.keep }
                case .calibrate: out.sort { $0.keep < $1.keep }
                default: return (out.map(\.position), true)
                }
                return (out.map(\.position), false)
            }.value
            guard let self, !Task.isCancelled else { return }
            log.notice("open: filtered \(result.count) photos to \(positions.count) in \(started.duration(to: .now))")
            self.loading = false
            var newList = AssetList(result: result, positions: positions)
            newList.ascending = ordered
            self.setList(newList, keeping: keepAsset)
        }
    }

    private func setList(_ newList: AssetList, keeping asset: PHAsset?) {
        list = newList
        if let asset, let i = newList.index(of: asset) {
            cursor = i
        } else {
            cursor = min(cursor, max(newList.count - 1, 0))
        }
        if mode == .compare { rebuildCompareGroup() }
    }

    /// Sidebar counts, worked out in the background. Unreviewed is "all photos minus the ones
    /// you've looked at", from Winnow's own records, so it never scans the library.
    func refreshCounts() {
        countsTask?.cancel()
        let library = library
        let seen = decisions.values.filter { $0.seenAt != nil }.count
        let albums = library.albums.map { Source.album(id: $0.localIdentifier, title: $0.localizedTitle ?? "Untitled") }
        let recommender = recommender
        let sampleCount = calibrationSample.count
        countsTask = Task { [weak self] in
            let started = ContinuousClock.now
            let out = await Task.detached(priority: .utility) { () -> [Source: Int] in
                var out: [Source: Int] = [:]
                let all = library.fetch(.allPhotos, newestFirst: false).count
                out[.allPhotos] = all
                out[.unreviewed] = max(all - seen, 0)
                if let recommender, recommender.hasScores {
                    let c = recommender.counts()
                    out[.suggestedRejects] = c.rejects
                    out[.bestShots] = c.best
                }
                out[.calibrate] = sampleCount
                for s in [Source.favorites, .screenshots, .bursts] + albums {
                    if Task.isCancelled { break }
                    out[s] = library.fetch(s, newestFirst: false).count
                }
                return out
            }.value
            guard let self, !Task.isCancelled else { return }
            log.notice("open: counted \(out.count) sources in \(started.duration(to: .now))")
            self.counts = out
        }
    }

    // MARK: Library changes

    private func libraryChanged(_ change: PHChange) {
        guard let details = change.changeDetails(for: list.result) else { return }
        let after = details.fetchResultAfterChanges

        // Photos now reports these photos' latest state, so pending ratings can go,
        // unless another rating write for the same photo is still queued.
        for asset in details.changedObjects where (photosWritesInFlight[asset.localIdentifier] ?? 0) <= 0 {
            pendingRatings[asset.localIdentifier] = nil
            pendingFavorites[asset.localIdentifier] = nil
        }

        // The common case — our own writes — changes objects in place: positions still hold.
        if details.hasIncrementalChanges,
           (details.insertedIndexes?.count ?? 0) == 0, (details.removedIndexes?.count ?? 0) == 0 {
            var updated = AssetList(result: after, positions: list.positions)
            updated.ascending = list.ascending
            list = updated
            return
        }

        // Photos added or removed (hidden, deleted, imported): stay on the same photo if it's still
        // there, otherwise on the same position, which is now the next photo.
        let keep = current
        if list.positions == nil {
            setList(AssetList(result: after, positions: nil), keeping: keep)
        } else {
            apply(after, keepingID: keep?.localIdentifier)
        }
        refreshCounts()
    }

    // MARK: Moving

    func select(index: Int) {
        guard list.indices.contains(index) else { return }
        cursor = index
        if mode != .grid { markSeen(current) }
        if mode == .compare { rebuildCompareGroup() }
        saveCursor()
    }

    func move(by delta: Int) {
        guard !list.isEmpty else { return }
        if mode == .compare {
            let next = compareFocus + delta
            if compareGroup.indices.contains(next) {
                compareFocus = next
                markSeen(compareGroup[next])
                return
            }
            // Past the edge of the group: go to the photo after (or before) it.
            let positions = compareGroup.compactMap { list.index(of: $0) }
            let edge = delta > 0 ? (positions.max() ?? cursor) + 1 : (positions.min() ?? cursor) - 1
            select(index: min(max(edge, 0), list.count - 1))
            return
        }
        zoomed = false
        select(index: min(max(cursor + delta, 0), list.count - 1))
    }

    private func modeChanged(from old: Mode) {
        zoomed = false
        if mode == .compare { rebuildCompareGroup() }
        if mode != .grid { markSeen(current) }
    }

    private func saveCursor() {
        try? store.setSetting("cursor.\(source.key)", to: current?.localIdentifier)
    }

    private func markSeen(_ asset: PHAsset?) {
        guard let asset, decision(asset).seenAt == nil else { return }
        var d = decision(asset)
        d.seenAt = Date()
        d.updatedAt = Date()
        decisions[asset.localIdentifier] = d
        try? store.save([d])
    }

    // MARK: Compare

    func focusCompare(_ index: Int) {
        guard compareGroup.indices.contains(index) else { return }
        compareFocus = index
        markSeen(compareGroup[index])
    }

    /// The frames of the current photo's burst, or photos taken within 10 seconds of it (2–4 in all).
    private func rebuildCompareGroup() {
        guard let cur = current else { compareGroup = []; return }
        var group: [PHAsset]
        if let burst = cur.burstIdentifier {
            let frames = library.burstFrames(burst)
            let center = frames.firstIndex { $0.localIdentifier == cur.localIdentifier } ?? 0
            let start = min(max(center - 1, 0), max(frames.count - 4, 0))
            group = Array(frames[start..<min(start + 4, frames.count)])
        } else {
            let t = cur.creationDate ?? .distantPast
            let near = { (i: Int) in abs((self.list.asset(at: i).creationDate ?? .distantPast).timeIntervalSince(t)) <= 10 }
            var lo = cursor, hi = cursor
            while hi - lo < 3, hi + 1 < list.count, near(hi + 1) { hi += 1 }
            while hi - lo < 3, lo > 0, near(lo - 1) { lo -= 1 }
            if lo == hi, hi + 1 < list.count { hi += 1 } // nothing close in time: compare with the next photo
            group = (lo...hi).map { list.asset(at: $0) }
        }
        compareGroup = group
        compareFocus = group.firstIndex { $0.localIdentifier == cur.localIdentifier } ?? 0
    }

    // MARK: Decisions

    func perform(_ action: Action) {
        guard let asset = target else { return }
        let label = switch action {
        case .rate(let n): n == 0 ? "Clear Rating" : "Rate \(n) Stars"
        case .reject: "Reject"
        case .clearFlag: "Clear Flag"
        case .toggleHidden: decision(asset).hidden ? "Unhide" : "Hide"
        case .toggleFavorite: isFavorite(asset) ? "Unfavorite" : "Favorite"
        }
        var after = decision(asset).applying(action, currentFavorite: asset.isFavorite)
        after.seenAt = after.seenAt ?? Date()
        commit(Change(label: label, before: [decision(asset)], after: [after]))

        // Auto-advance, except in compare (you keep working the group), after hiding (the photo
        // leaves the list, so the next one is already under the cursor), and after favoriting
        // (often followed by a rating for the same photo).
        if mode != .compare, action != .toggleHidden, action != .toggleFavorite { move(by: 1) }
    }

    /// Compare view: keep the focused frame (clearing a reject on it), reject the rest of the group.
    func keepFocusedRejectRest() {
        guard mode == .compare, compareGroup.indices.contains(compareFocus) else { return }
        let before = compareGroup.map(decision)
        let after = compareGroup.enumerated().map { i, a in
            var d = decision(a).applying(i == compareFocus ? .clearFlag : .reject, currentFavorite: a.isFavorite)
            d.seenAt = d.seenAt ?? Date()
            return d
        }
        commit(Change(label: "Keep One, Reject \(compareGroup.count - 1)", before: before, after: after))
    }

    func undo() {
        guard let change = history.undo() else { return }
        commit(change, record: false)
        show("Undo \(change.label)")
        revealFirst(of: change)
    }

    func redo() {
        guard let change = history.redo() else { return }
        commit(change, record: false)
        show("Redo \(change.label)")
        revealFirst(of: change)
    }

    private func revealFirst(of change: Change) {
        guard mode != .compare, let id = change.after.first?.assetID,
              let asset = library.assets(withIDs: [id]).first, let i = list.index(of: asset) else { return }
        select(index: i)
    }

    private func commit(_ change: Change, record: Bool = true) {
        var after = change.after
        let missingCloud = after.filter { $0.cloudID == nil }.map(\.assetID)
        if !missingCloud.isEmpty {
            let ids = library.cloudIDs(for: missingCloud)
            for i in after.indices where after[i].cloudID == nil { after[i].cloudID = ids[after[i].assetID] }
        }
        for d in after { decisions[d.assetID] = d }
        do {
            try store.save(after)
        } catch {
            show("Couldn't save: \(error.localizedDescription)")
        }
        if record { history.record(Change(label: change.label, before: change.before, after: after)) }

        let pairs = Array(zip(change.before, after))
        // Ratings and Favorites live in Photos; hold the new values until Photos reports them.
        var photosIDs: [String] = []
        for (before, d) in pairs where before.rating != d.rating || before.favorite != d.favorite {
            if before.rating != d.rating { pendingRatings[d.assetID] = d.rating }
            if before.favorite != d.favorite, let f = d.favorite { pendingFavorites[d.assetID] = f }
            photosWritesInFlight[d.assetID, default: 0] += 1
            photosIDs.append(d.assetID)
        }
        let previous = writes
        writes = Task { [weak self] in
            defer {
                for id in photosIDs { self?.photosWritesInFlight[id, default: 1] -= 1 }
            }
            await previous?.value
            guard let self else { return }
            let assets = Dictionary(self.library.assets(withIDs: pairs.map(\.0.assetID)).map { ($0.localIdentifier, $0) },
                                    uniquingKeysWith: { a, _ in a })
            let items = pairs.compactMap { before, after -> (asset: PHAsset, change: PhotosChange)? in
                guard let asset = assets[after.assetID] else { return nil }
                return (asset, PhotosChange(from: before, to: after))
            }
            do {
                try await self.library.apply(items)
            } catch {
                // Roll back so Winnow never shows a state Photos doesn't have.
                for id in photosIDs {
                    self.pendingRatings[id] = nil
                    self.pendingFavorites[id] = nil
                }
                for d in change.before { self.decisions[d.assetID] = d }
                try? self.store.save(change.before)
                if record { self.history.discardLast() }
                self.show("Couldn't update Photos: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Delete queue

    func rejectedAssets() -> [PHAsset] {
        library.assets(withIDs: decisions.values.filter { $0.flag == .reject }.map(\.assetID))
    }

    /// Returns true if the photos were deleted.
    func deleteRejected() async -> Bool {
        await writes?.value
        let assets = rejectedAssets()
        guard !assets.isEmpty else { return false }
        do {
            try await library.delete(assets)
        } catch {
            if (error as? PHPhotosError)?.code == .userCancelled {
                show("Nothing deleted.")
            } else {
                show("Couldn't delete: \(error.localizedDescription)")
            }
            return false
        }
        let ids = assets.map(\.localIdentifier)
        for id in ids { decisions[id] = nil }
        try? store.remove(ids)
        // Winnow can't bring deleted photos back (Photos' Recently Deleted can), so undo stops here.
        history.clear()
        show("Deleted \(ids.count) photos. They're in Recently Deleted in Photos for 30 days.")
        return true
    }

    // MARK: Zoom

    func toggleZoom(onFace: Bool) {
        guard mode != .grid else { return }
        if zoomed, zoomOnFace == onFace {
            zoomed = false
        } else {
            zoomOnFace = onFace
            zoomed = true
        }
    }

    // MARK: Messages

    func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.message = nil }
        }
    }
}
