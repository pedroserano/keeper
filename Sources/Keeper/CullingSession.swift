// One open library: what's being culled, where the cursor is, and every decision made.
//
// Built for big libraries: the photo list is PhotoKit's own lazy fetch result, so opening never
// loads every photo. Filters that must look at every photo, and the sidebar counts, run in the
// background.
//
// Decisions apply instantly to the screen and Keeper's database, then are written to Photos
// in order on a serial queue. If a Photos write fails, that decision is rolled back.

import AppKit
import Combine
import os
import Photos
import SwiftUI
import KeeperCore
import KeeperKit
import DateGuesser

let log = Logger(subsystem: "local.keeper", category: "session")

/// Logs how long each stage of a background job took ("similarity: read prints 0.84 s"), to see
/// where launch time goes. Counts and times only: no names or paths.
struct StageClock {
    let job: String
    private var last = ContinuousClock.now

    init(_ job: String) { self.job = job }

    mutating func lap(_ stage: String) {
        let now = ContinuousClock.now
        let c = (now - last).components
        let text = "timing: \(job) \(stage) \(String(format: "%.2f", Double(c.seconds) + Double(c.attoseconds) / 1e18)) s"
        log.notice("\(text, privacy: .public)")
        last = now
    }
}

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
        case all = "All", notRejected = "Not Rejected", unrated = "Unrated", favorites = "Favorites", rejects = "Rejects"
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
    /// The Dates row on screen, if any (the culling list stays where it was underneath).
    @Published var dates: DatesItem?
    /// Loaded in the background the first time a Dates row is opened.
    @Published private(set) var datesModel: DatesModel?
    private var datesLoading = false

    func openDates(_ item: DatesItem) {
        dates = item
        loadDates()
    }

    /// Starts loading the Dates screens' data, if it isn't already (opening a Dates row, or the
    /// Dates tab in Settings).
    func loadDates() {
        guard datesModel == nil, !datesLoading else { return }
        datesLoading = true
        let name = DecisionStore.url(forLibrary: libraryURL).deletingPathExtension().lastPathComponent
        let folder = DecisionStore.directory.appendingPathComponent("\(name) Dates", isDirectory: true)
        let started = ContinuousClock.now
        Task { [weak self, libraryURL] in
            let model = await DatesModel.load(libraryURL: libraryURL, dataDirectory: folder)
            DatesModel.isRaw = { [weak self] id in self?.fileInfo(forID: id)?.isRaw == true }
            log.notice("dates: loaded in \(started.duration(to: .now), privacy: .public)")
            self?.datesModel = model
        }
    }

    @Published private(set) var source: Source = .allPhotos
    @Published private(set) var recommender: Recommender?
    @Published private(set) var suggestionsStatus = SuggestionsStatus.loading

    /// Something Keeper can't see, explained in a banner with a way to fix it.
    enum AccessGap: Equatable {
        /// Photos access limited to chosen photos (iOS-style limited access, should macOS offer it).
        case limitedPhotos
        /// macOS won't let Keeper read the library's database: no Apple scores, file sizes or faces.
        case noDatabase
    }
    @Published private(set) var accessGap: AccessGap?

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

    enum SimilarityStatus: Equatable {
        case waiting
        case indexing(done: Int, total: Int)
        case ready(groups: Int)
    }

    @Published private(set) var similarity = SimilarityStatus.waiting
    /// When this run's fingerprinting began and how far along it was then, for the time-left estimate.
    private var similarityStart: (at: ContinuousClock.Instant, done: Int)?

    /// Rough time left in the first scan, from this run's pace so far.
    var similarityTimeLeft: Duration? {
        guard case .indexing(let done, let total) = similarity, let start = similarityStart,
              done > start.done else { return nil }
        let elapsed = start.at.duration(to: .now)
        return elapsed * Double(total - done) / Double(done - start.done)
    }

    fileprivate func updateSimilarityProgress(done: Int, total: Int) {
        if similarityStart == nil { similarityStart = (.now, done) }
        similarity = .indexing(done: done, total: total)
    }
    // Sideways Photos
    enum OrientationStatus: Equatable {
        case waiting
        case scanning(done: Int, total: Int)
        case ready(checked: Int)
    }
    @Published private(set) var orientationScan = OrientationStatus.waiting
    /// False when the orientation network couldn't load (faces, people and text still work).
    @Published private(set) var orientationNetwork = true
    /// Proposals not yet rotated or dismissed, by local identifier.
    private(set) var sideways: [String: OrientationRecord] = [:]
    /// Sideways Photos lists only proposals at least this sure. Saved app-wide.
    @Published var sidewaysMinConfidence = UserDefaults.standard.object(forKey: "sidewaysMinConfidence") as? Double ?? 0.5 {
        didSet {
            UserDefaults.standard.set(sidewaysMinConfidence, forKey: "sidewaysMinConfidence")
            sidewaysThresholdChanged()
        }
    }
    private var sidewaysThresholdTask: Task<Void, Never>?

    /// Duplicate and similar-shot groups, and where to find their photos.
    private(set) var groups: [SimilarGroup] = []
    private var groupLocalIDs: [String: String] = [:]
    /// The Apple-scores panel in single view (I).
    @Published var showingScores = false
    @Published var filter: Filter = .all { didSet { if filter != oldValue { reload() } } }
    /// The order of photos in lists kept in date order (not suggestions or Sideways Photos).
    @Published var sort: PhotoSort = PhotoSort(rawValue: UserDefaults.standard.string(forKey: PhotoSort.storageKey) ?? "") ?? .oldest {
        didSet {
            guard sort != oldValue else { return }
            UserDefaults.standard.set(sort.rawValue, forKey: PhotoSort.storageKey)
            reload()
        }
    }
    /// Get Info (⌘I) is showing this photo.
    @Published var infoAsset: PHAsset?

    /// Sideways Photos' own order, surest first unless you choose a date order.
    @Published var sidewaysSort: PhotoSort = PhotoSort(rawValue: UserDefaults.standard.string(forKey: PhotoSort.sidewaysStorageKey) ?? "") ?? .certainty {
        didSet {
            guard sidewaysSort != oldValue else { return }
            UserDefaults.standard.set(sidewaysSort.rawValue, forKey: PhotoSort.sidewaysStorageKey)
            if source == .sideways { reload() }
        }
    }

    /// The View menu's Newest First.
    var newestFirst: Bool {
        get { sort == .newest }
        set { sort = newValue ? .newest : .oldest }
    }
    /// The photos in view, for the window's subtitle: the dates of the grid's visible photos, as in Photos.
    let titleDates = TitleDates()
    @Published var mode: Mode = .grid { didSet { modeChanged(from: oldValue) } }
    @Published private(set) var list = AssetList.empty
    /// For Duplicates and Similar Shots: where each group starts and ends in `list`, and which group it is.
    @Published private(set) var sections: [Range<Int>]? = nil
    @Published private(set) var sectionGroups: [LookAlikeGroup] = []
    /// Original file size and dimensions, from Photos' database.
    private(set) var files: [String: FileInfo] = [:]
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
    /// Ratings and Favorites Keeper has written that Photos hasn't reported back yet, so the
    /// stars and heart don't flicker back to the old value while the write is under way.
    private var pendingRatings: [String: Int] = [:]
    private var pendingFavorites: [String: Bool] = [:]
    private var photosWritesInFlight: [String: Int] = [:]

    init(library: PhotoLibrary, store: DecisionStore, libraryURL: URL) {
        keeperRules = KeeperSettings.shared.rules
        self.library = library
        self.store = store
        self.libraryURL = libraryURL
        self.libraryName = libraryURL.deletingPathExtension().lastPathComponent
        let started = ContinuousClock.now
        decisions = (try? store.all()) ?? [:]
        if let json = try? store.setting("calibrationSample"), let data = json.data(using: .utf8) {
            calibrationSample = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        // Always opens on All Photos, the first row, rather than wherever you were last time.
        if let saved = try? store.setting("dateRange") {
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                dateRange = Date(timeIntervalSince1970: parts[0])...Date(timeIntervalSince1970: parts[1])
            }
        }
        if let json = try? store.setting("keeperChoices"), let data = json.data(using: .utf8) {
            keeperChoices = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        if let json = try? store.setting("selectedGroups"), let data = json.data(using: .utf8) {
            selectedGroups = Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
        }
        if let saved = try? store.setting("aggressiveness"), let value = Double(saved) { aggressiveness = value }
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited { accessGap = .limitedPhotos }
        log.notice("open: loaded \(self.decisions.count) decisions in \(started.duration(to: .now), privacy: .public)")
        library.onChange = { [weak self] change in self?.libraryChanged(change) }
        reload(restoreFrom: (try? store.setting("cursor.\(source.key)")) ?? nil)
        refreshCounts()
        loadSuggestions()
        findSimilarPhotos()
        // Sliders send every step; re-pick once you stop.
        keeperWatch = KeeperSettings.shared.$rules
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.keeperRulesChanged($0) }
    }

    // MARK: Duplicates and similar shots

    /// Fingerprints photos taken close together and groups the ones that look alike. The first run
    /// on a big library takes a while (it shows progress and survives quitting); later ones only
    /// look at new photos.
    func findSimilarPhotos() {
        let library = library, store = store, libraryName = libraryName
        let session = WeakSession(self) // stops the indexing if this library is closed
        Task { [weak self] in
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .utility) {
                await SimilarityIndexer.run(library: library, store: store,
                    progress: { done, total in
                        await MainActor.run { session.value?.updateSimilarityProgress(done: done, total: total) }
                    },
                    keepGoing: { session.value != nil })
            }.value
            guard let self, let result else { return }
            var clock = StageClock("similarity")
            SimilarityIndexer.saveReport(result, libraryName: libraryName)
            log.notice("similarity: \(result.groups.count) groups in \(started.duration(to: .now), privacy: .public)")
            self.groups = result.groups
            self.groupLocalIDs = result.localIDs
            self.carryOverDuplicateChoices(previous: result.previousDuplicates)
            self.similarity = .ready(groups: result.groups.count)
            self.inputsVersion += 1
            clock.lap("carry over")
            await self.rebuildRecommender()
            clock.lap("rebuild suggestions")
            if self.source.isSuggestion { self.reload() }
            self.refreshCounts()
            clock.lap("reload and count")
            self.findSideways(photos: result.library)
        }
    }

    // MARK: Sideways photos

    /// Checks every photo's orientation in the background, after the look-alikes scan so the two
    /// don't compete for Vision. The first run on a big library takes hours (it survives quitting);
    /// later ones only check new and changed photos.
    /// `photos`: every photo, newest first, from the look-alikes scan.
    func findSideways(photos: [OrientationScanner.Photo]? = nil) {
        let library = library, store = store, libraryURL = libraryURL
        let session = WeakSession(self)
        loadSideways()
        Task { [weak self] in
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .utility) {
                await OrientationScanner.run(library: library, libraryURL: libraryURL, store: store, photos: photos,
                    progress: { done, total in
                        await MainActor.run { session.value?.updateOrientationProgress(done: done, total: total) }
                    },
                    keepGoing: { session.value != nil })
            }.value
            guard let self, let result else { return }
            log.notice("orientation: done in \(started.duration(to: .now), privacy: .public)")
            self.orientationNetwork = result.networkLoaded
            self.orientationScan = .ready(checked: result.checked)
            self.loadSideways()
            if self.source == .sideways { self.reload() }
            self.refreshCounts()
        }
    }

    fileprivate func updateOrientationProgress(done: Int, total: Int) {
        orientationScan = .scanning(done: done, total: total)
        // New finds show in the count and, if you're looking at Sideways Photos, in the list too.
        let before = listedSideways
        loadSideways()
        if source == .sideways && listedSideways != before { scheduleSidewaysReload() }
        scheduleCountsRefresh()
    }

    /// The proposals Sideways Photos lists at the current minimum confidence.
    private var listedSideways: Set<String> {
        Set(sideways.filter { $0.value.confidence >= sidewaysMinConfidence }.keys)
    }

    /// Refreshes the list at most every few seconds while a scan adds to it, keeping your place.
    private func scheduleSidewaysReload() {
        guard sidewaysReloadTask == nil else { return }
        sidewaysReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.sidewaysReloadTask = nil
            if !Task.isCancelled, self.source == .sideways { self.reload(quietly: true) }
        }
    }
    private var sidewaysReloadTask: Task<Void, Never>?

    private func loadSideways() {
        let records = (try? store.orientationProposals()) ?? []
        sideways = Dictionary(records.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func sidewaysThresholdChanged() {
        sidewaysThresholdTask?.cancel()
        sidewaysThresholdTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            if self.source == .sideways { self.reload() }
            self.refreshCounts()
        }
    }

    /// The turn Keeper proposes for a photo in Sideways Photos (nil once it's out of date).
    func proposedRotation(_ asset: PHAsset) -> OrientationRecord? {
        guard let r = sideways[asset.localIdentifier] else { return nil }
        // A new modification date doesn't hide the proposal: Photos changes it just from opening the
        // photo there. The photo is checked again in the background, which drops the proposal if
        // it really was turned since.
        if abs(r.modDate - OrientationScanner.modDate(asset)) >= 1 { recheckSideways(asset) }
        return r
    }

    /// Photos being checked again, with the modification date each was checked for.
    private var rechecking: [String: Double] = [:]

    /// A proposal's photo has a new modification date: check it again now (a moment, in the
    /// background) rather than leave it without its label and buttons until the next scan.
    private func recheckSideways(_ asset: PHAsset) {
        let id = asset.localIdentifier, date = OrientationScanner.modDate(asset)
        guard rechecking[id] != date else { return }
        rechecking[id] = date
        Task { [weak self] in
            let fresh = await OrientationScanner.recheck(id)
            log.notice("orientation: rechecked a changed photo: \(fresh.map { "\($0.status) \($0.rotation.degrees)° \($0.evidence)" } ?? "gone", privacy: .public)")
            guard let self, var record = fresh, let old = self.sideways[id] else { return }
            // A turn you picked stays yours.
            if old.isChosenByYou {
                record = old
                record.modDate = fresh!.modDate
            }
            try? self.store.saveOrientation([record])
            self.objectWillChange.send()
            self.sideways[id] = record.status == .needsRotation ? record : nil
            self.scheduleCountsRefresh()
        }
    }

    /// The blue label's menu: the photo needs a different turn from the one proposed. Not a change to
    /// the photo, so there's nothing to undo; Rotate then uses the new turn.
    func changeSidewaysTurn(_ asset: PHAsset, to rotation: Rotation) {
        let id = asset.localIdentifier
        guard var r = sideways[id], rotation != .none else { return }
        do { try store.setOrientationRotation(rotation, for: id) } catch {
            show("Couldn't save the new turn: \(error.localizedDescription)")
            return
        }
        objectWillChange.send()
        r.rotation = rotation
        r.evidence = OrientationRecord.chosenByYou
        sideways[id] = r
    }

    /// The selected photos, or the one at the cursor when none is selected.
    private var sidewaysTargets: [PHAsset] {
        if !selectedPhotos.isEmpty { return library.assets(withIDs: Array(selectedPhotos)) }
        return target.map { [$0] } ?? []
    }

    /// Rotate (or A, or a photo's own Rotate button): each photo gets its own proposed turn,
    /// in one step (⌘Z undoes).
    func rotateSideways(_ assets: [PHAsset]? = nil) {
        let proposals = (assets ?? sidewaysTargets).compactMap { a in proposedRotation(a).map { (a.localIdentifier, $0.rotation) } }
        guard !proposals.isEmpty else { return }
        let n = proposals.count
        commit(Change(label: n == 1 ? "Rotate" : "Rotate \(n.formatted())", before: [], after: [],
                      rotations: Dictionary(proposals.map { ($0.0, $0.1.degrees) }, uniquingKeysWith: { a, _ in a }),
                      sidewaysHidden: Dictionary(proposals.map { ($0.0, true) }, uniquingKeysWith: { a, _ in a })))
        if assets == nil { deselectAllPhotos() } else { selectedPhotos.subtract(proposals.map(\.0)) }
        reload(quietly: true)
    }

    /// Not Sideways (N): these photos are fine as they are; they stop showing until they change.
    func dismissSideways(_ assets: [PHAsset]? = nil) {
        let ids = (assets ?? sidewaysTargets).filter { proposedRotation($0) != nil }.map(\.localIdentifier)
        guard !ids.isEmpty else { return }
        commit(Change(label: "Not Sideways", before: [], after: [],
                      sidewaysHidden: Dictionary(ids.map { ($0, true) }, uniquingKeysWith: { a, _ in a })))
        if assets == nil { deselectAllPhotos() } else { selectedPhotos.subtract(ids) }
        show("\(ids.count == 1 ? "Left it" : "Left \(ids.count.formatted()) photos") as \(ids.count == 1 ? "it is" : "they are"). ⌘Z undoes.")
        reload(quietly: true)
    }

    /// Hides or shows proposals for a change, or for its undo.
    private func applySidewaysHidden(_ hidden: [String: Bool]) {
        guard !hidden.isEmpty else { return }
        try? store.setOrientationHidden(hidden)
        loadSideways()
        scheduleCountsRefresh()
    }

    /// After an undone rotation lands in Photos: the photos look as they did when checked again.
    private func sidewaysRotatedBack(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var dates: [String: Double] = [:]
        for asset in library.assets(withIDs: ids) { dates[asset.localIdentifier] = OrientationScanner.modDate(asset) }
        try? store.setOrientationHidden([:], modDates: dates)
        loadSideways()
        if source == .sideways { reload(quietly: true) }
        scheduleCountsRefresh()
    }

    /// Once, after duplicates came to need a shared capture moment: ticks and keeper picks on
    /// duplicate groups that changed move to the groups now holding their photos (often in Similar
    /// Shots), so they're there to review.
    nonisolated static let duplicatesRule = "sameMoment"

    private func carryOverDuplicateChoices(previous: [SimilarGroup]) {
        let rule = Self.duplicatesRule
        guard !groups.isEmpty, ((try? store.setting("duplicatesRule")) ?? nil) != rule else { return }
        let r = GroupCarryOver.map(selected: selectedGroups, choices: keeperChoices, groups: groups, previous: previous)
        if r.selected != selectedGroups { selectedGroups = r.selected }
        if r.choices != keeperChoices { keeperChoices = r.choices }
        try? store.setSetting("duplicatesRule", to: rule)
        log.notice("similarity: carried over \(r.moved) ticks and picks to new groups, left \(r.leftAlone) as they were")
    }

    /// The photos in this photo's group, the one to keep first: the group this list shows, or
    /// elsewhere its similar shots (which take in its copies), else its duplicates.
    func groupMembers(of asset: PHAsset) -> [PHAsset]? {
        guard let group = lookAlike(of: asset) else { return nil }
        return assets(forUUIDs: chosen(group).members)
    }

    private func lookAlike(of asset: PHAsset) -> LookAlikeGroup? {
        let uuid = uuidOf(asset)
        if let kind = source.groupKind { return recommender?.lookAlike(forUUID: uuid, kind: kind) }
        return recommender?.lookAlike(forUUID: uuid, kind: .similar) ?? recommender?.lookAlike(forUUID: uuid, kind: .duplicate)
    }

    /// PHAssets for UUIDs, in the same order.
    func assets(forUUIDs uuids: [String]) -> [PHAsset] {
        let byID = Dictionary(library.assets(withIDs: uuids.compactMap { groupLocalIDs[$0] })
            .map { (uuidOf($0), $0) }, uniquingKeysWith: { a, _ in a })
        return uuids.compactMap { byID[$0] }
    }

    func fileInfo(_ asset: PHAsset) -> FileInfo? { files[uuidOf(asset)] }
    /// The same, by Photos' local identifier ("UUID/L0/001").
    func fileInfo(forID id: String) -> FileInfo? { files[String(id.prefix { $0 != "/" })] }

    /// Whether this is the photo kept in its group: your pick, or else Keeper's suggestion.
    func isKeeper(_ asset: PHAsset) -> Bool {
        lookAlike(of: asset).map(chosen)?.keeper == uuidOf(asset)
    }

    /// The photo you picked to keep in each group, by group id, where it differs from the suggestion.
    /// Saved with the library, so picks survive quitting; kept after a merge, so undo brings them back.
    @Published private(set) var keeperChoices: [String: String] = [:] {
        didSet {
            guard let data = try? JSONEncoder().encode(keeperChoices) else { return }
            try? store.setSetting("keeperChoices", to: String(decoding: data, as: UTF8.self))
        }
    }

    /// The group as it will be merged: keeping your pick, if you made one.
    /// The group as it will merge: your pick if you made one, otherwise the rules' keeper, which can
    /// change once some of its photos are rejected.
    func chosen(_ group: LookAlikeGroup) -> LookAlikeGroup {
        if let pick = keeperChoices[group.id] { return group.keeping(pick) }
        let rejected = rejectedMembers(group)
        guard !rejected.isEmpty, let recommender else { return group }
        return group.keeping(recommender.keeper(of: group, rejected: rejected))
    }

    private func rejectedMembers(_ group: LookAlikeGroup) -> Set<String> {
        Set(group.members.filter { id in groupLocalIDs[id].flatMap { decisions[$0] }?.flag == .reject })
    }

    /// Why the suggested photo is the one kept, for the group's header.
    func keeperNote(_ group: LookAlikeGroup) -> String {
        if isChosenByYou(group) { return "Keeping your pick" }
        guard let recommender else { return "" }
        guard let rule = recommender.keeperReason(of: group, rejected: rejectedMembers(group)) else {
            return "Suggested: looks best"
        }
        return "Suggested by the \(rule.title) rule"
    }

    func isChosenByYou(_ group: LookAlikeGroup) -> Bool { keeperChoices[group.id] != nil }

    /// Keep this photo instead of the suggested one when its group is merged (K, or Keep under a photo).
    func keepInGroup(_ asset: PHAsset) {
        guard source.isGroups, let group = lookAlike(of: asset) else { return }
        let uuid = uuidOf(asset)
        let rejected = rejectedMembers(group)
        let suggested = rejected.isEmpty ? group.keeper : recommender?.keeper(of: group, rejected: rejected) ?? group.keeper
        keeperChoices[group.id] = uuid == suggested ? nil : uuid
    }

    /// A group is done once at most one of its photos isn't rejected (merged, or culled by hand).
    nonisolated static func isResolved(_ group: LookAlikeGroup, _ decisions: [String: Decision],
                                       localIDs: [String: String]) -> Bool {
        group.members.filter { id in
            localIDs[id].flatMap { decisions[$0] }?.flag != .reject
        }.count <= 1
    }

    // MARK: Merging look-alikes

    /// Groups ticked in Duplicates or Similar Shots, by group id.
    /// Saved with the library, so ticks survive switching lists and quitting. Group ids name their
    /// kind, so Duplicates and Similar Shots keep separate ticks.
    @Published var selectedGroups: Set<String> = [] {
        didSet {
            guard let data = try? JSONEncoder().encode(selectedGroups.sorted()) else { return }
            try? store.setSetting("selectedGroups", to: String(decoding: data, as: UTF8.self))
        }
    }
    @Published private(set) var merging = false

    func toggleSelection(_ group: LookAlikeGroup) {
        if selectedGroups.contains(group.id) { selectedGroups.remove(group.id) } else { selectedGroups.insert(group.id) }
    }

    /// Every group in this list (the other list's ticks stay as they are).
    func selectAllGroups() { selectedGroups.formUnion(sectionGroups.map(\.id)) }
    func deselectAllGroups() { selectedGroups.subtract(sectionGroups.map(\.id)) }

    /// Which group the cursor is in, in a Duplicates or Similar Shots list.
    private var cursorSection: Int? {
        sections?.firstIndex { $0.contains(cursor) }
    }

    /// Where a Shift-selection of groups started (a group's index); nil when just one is selected.
    @Published private(set) var groupAnchor: Int?

    /// The groups Shift-selected, from the anchor to the group the cursor is in.
    var highlightedSections: ClosedRange<Int>? {
        guard let n = cursorSection else { return nil }
        guard let a = groupAnchor else { return n...n }
        return min(a, n)...max(a, n)
    }

    /// G in a group list: tick or untick the group the cursor is in, and every other Shift-selected
    /// group the same way (so after Select All, Shift-select some and G unticks them all).
    func toggleSelectionAtCursor() {
        if selectsPhotos { togglePhoto(at: cursor); return }
        guard let n = cursorSection, sectionGroups.indices.contains(n), let range = highlightedSections else { return }
        let tick = !selectedGroups.contains(sectionGroups[n].id)
        let ids = range.filter(sectionGroups.indices.contains).map { sectionGroups[$0].id }
        if tick { selectedGroups.formUnion(ids) } else { selectedGroups.subtract(ids) }
    }

    /// ↑ ↓ in a group list: to the first photo (the one kept) of the previous or next group.
    /// With Shift, the groups passed over stay selected.
    func moveGroup(by delta: Int, extending: Bool = false) {
        guard let sections, let n = cursorSection else { return }
        let target = min(max(n + delta, 0), sections.count - 1)
        zoomed = false
        select(index: sections[target].lowerBound, extending: extending, from: n)
    }

    /// Merges each group into its keeper (see KeeperKit.Merge), as one undoable step, then takes
    /// the merged groups out of their list.
    func merge(_ groups: [LookAlikeGroup]) async {
        let groups = groups.map(chosen)
        guard !groups.isEmpty, !merging else { return }
        merging = true
        defer { merging = false }
        await writes?.value

        // Which albums each keeper is missing: a lookup per photo, so do it off the main thread.
        let library = library, localIDs = groupLocalIDs
        let missingAlbums = await Task.detached(priority: .userInitiated) { () -> [String: Set<String>] in
            var out: [String: Set<String>] = [:]
            for group in groups {
                let assets = library.assets(withIDs: group.members.compactMap { localIDs[$0] })
                var albums: [String: Set<String>] = [:]
                for a in assets { albums[String(a.localIdentifier.split(separator: "/").first ?? "")] = library.albumIDs(containing: a) }
                let keeperHas = albums[group.keeper] ?? []
                out[group.keeper] = group.others.reduce(into: Set<String>()) { $0.formUnion(albums[$1] ?? []) }
                    .subtracting(keeperHas)
            }
            return out
        }.value

        var before: [Decision] = [], after: [Decision] = []
        for group in groups {
            let members = assets(forUUIDs: group.members)
            guard let keeper = members.first, uuidOf(keeper) == group.keeper else { continue }
            let others = Array(members.dropFirst())
            let old = [decision(keeper)] + others.map(decision)
            before += old
            after += Merge.merged(keeper: old[0], others: Array(old.dropFirst()),
                                  albumsToAdd: missingAlbums[group.keeper] ?? [])
        }
        guard !after.isEmpty else { return }
        let photos = after.count - groups.count
        commit(Change(label: groups.count == 1 ? "Merge" : "Merge \(groups.count) Groups", before: before, after: after))
        selectedGroups.subtract(groups.map(\.id))
        show("Merged \(groups.count.formatted()) \(groups.count == 1 ? "group" : "groups"). "
             + "\(photos.formatted()) photos moved to Rejected; delete them from Delete Rejected. ⌘Z undoes.")
        reload()
        refreshCounts()
    }

    private func uuidOf(_ asset: PHAsset) -> String {
        String(asset.localIdentifier.split(separator: "/").first ?? "")
    }

    func dismissAccessGap() { accessGap = nil }

    // MARK: Date range

    /// The days Date Range shows, first to last inclusive. Starts as the last 30 days.
    @Published private(set) var dateRange: ClosedRange<Date> = {
        let today = Date()
        return Calendar.current.date(byAdding: .day, value: -29, to: today)!...today
    }()

    func setDateRange(from: Date, to: Date) {
        let range = min(from, to)...max(from, to)
        guard range != dateRange else { return }
        dateRange = range
        try? store.setSetting("dateRange", to: "\(range.lowerBound.timeIntervalSince1970),\(range.upperBound.timeIntervalSince1970)")
        if source == .dateRange { reload() }
        refreshCounts()
    }

    // MARK: Aggressiveness

    /// How readily photos are suggested as rejects: 0 conservative, 0.5 default, 1 aggressive.
    @Published private(set) var aggressiveness = 0.5
    /// While the slider moves: how many photos would be in Suggested Rejects and Best Shots.
    @Published private(set) var aggressivenessPreview: (rejects: Int, best: Int)?
    private var previewTask: Task<Void, Never>?

    /// Works out the counts for a slider position, a moment after it stops moving.
    func previewAggressiveness(_ value: Double) {
        previewTask?.cancel()
        guard let base = recommender, base.hasScores else { return }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let counts = await Task.detached(priority: .userInitiated) { base.with(aggressiveness: value).counts() }.value
            guard let self, !Task.isCancelled else { return }
            self.aggressivenessPreview = counts
        }
    }

    /// Applies a slider position: suggestions, counts and the open list all follow.
    func setAggressiveness(_ value: Double) {
        previewTask?.cancel()
        aggressiveness = value
        inputsVersion += 1
        try? store.setSetting("aggressiveness", to: String(value))
        Task { [weak self] in
            guard let self else { return }
            await self.rebuildRecommender()
            guard self.aggressiveness == value else { return }
            self.aggressivenessPreview = nil
            if self.source.isSuggestion { self.reload() }
            self.refreshCounts()
        }
    }

    // MARK: Suggestions

    /// The model fitted to your ratings, if it beats curation.
    private var fittedModel: RatingModel?
    /// How Duplicates and Similar Shots pick keepers (Keeper › Settings › Keeper Rules).
    private var keeperRules: KeeperRules
    private var keeperWatch: AnyCancellable?

    /// Settings changed: re-pick keepers and show them in the open list.
    private func keeperRulesChanged(_ rules: KeeperRules) {
        guard rules != keeperRules else { return }
        keeperRules = rules
        inputsVersion += 1
        Task { [weak self] in
            guard let self else { return }
            await self.rebuildRecommender()
            guard self.keeperRules == rules else { return }
            if self.source.isGroups { self.reload() }
        }
    }
    /// Bumped whenever the groups, the model or the aggressiveness change.
    private var inputsVersion = 0

    /// Rebuilds the suggestions from the latest groups, model and aggressiveness. Background jobs
    /// (finding look-alikes, learning from ratings, the slider) finish in any order, so each one
    /// rebuilds from everything current instead of from what it saw when it started; if something
    /// changes mid-build, it builds again.
    private func rebuildRecommender() async {
        while let base = recommender {
            let version = inputsVersion
            let groups = groups, model = fittedModel, aggressiveness = aggressiveness
            let keeping = keeperRules
            let updated = await Task.detached(priority: .userInitiated) {
                base.with(model: .some(model), groups: groups, aggressiveness: aggressiveness, keeperRules: keeping)
            }.value
            if version == inputsVersion {
                recommender = updated
                return
            }
        }
    }

    /// Reads Apple's scores for every photo (one read-only query, well under a second for
    /// 200,000 photos) and builds the suggestions from them, in the background.
    func loadSuggestions() {
        suggestionsStatus = .loading
        let url = libraryURL, library = library, groups = groups, aggressiveness = aggressiveness
        let keeping = keeperRules
        let version = inputsVersion
        Task { [weak self] in
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .utility) { () -> Result<Recommender, Error> in
                do {
                    // Three independent read-only queries, each on its own connection: run together.
                    async let filesRead = Task.detached(priority: .utility) {
                        var clock = StageClock("suggestions")
                        defer { clock.lap("read file info") }
                        return (try? PhotosDatabase.readFileInfo(inLibrary: url)) ?? [:]
                    }.value
                    async let facesRead = Task.detached(priority: .utility) {
                        var clock = StageClock("suggestions")
                        defer { clock.lap("read faces") }
                        return (try? PhotosDatabase.readFaceInfo(inLibrary: url)) ?? [:]
                    }.value
                    var clock = StageClock("suggestions")
                    let scores = try PhotosDatabase.readAppleScores(inLibrary: url)
                    clock.lap("read Apple scores")
                    let screenshots = library.uuids(in: .screenshots)
                    clock.lap("list screenshots")
                    let files = await filesRead
                    let faces = await facesRead
                    clock.lap("wait for the other reads")
                    let r = Recommender(scores: scores, screenshots: screenshots,
                                        groups: groups, files: files, faces: faces,
                                        aggressiveness: aggressiveness, keeperRules: keeping)
                    clock.lap("build")
                    return .success(r)
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(let r):
                log.notice("open: read \(r.scores.count) photos' Apple scores and \(r.faces.count) photos' faces in \(started.duration(to: .now), privacy: .public)")
                self.recommender = r
                // Groups or the slider changed while the scores were loading: build with those.
                if self.inputsVersion != version { await self.rebuildRecommender() }
                self.files = r.files
                self.suggestionsStatus = r.hasScores ? .ready : .notAnalysed
                if self.source.isSuggestion { self.reload() }
                self.refreshCounts()
                if r.hasScores {
                    self.saveCalibration(self.recommender ?? r)
                    self.learnFromRatings(usingLaunchRead: true)
                }
            case .failure(let error):
                self.suggestionsStatus = .unavailable(error.localizedDescription)
                let database = self.libraryURL.appendingPathComponent("database/Photos.sqlite").path
                if (error as? PhotosDatabaseError)?.kind == .noAccess || !FileManager.default.isReadableFile(atPath: database) {
                    self.accessGap = self.accessGap ?? .noDatabase
                }
                if self.source.isSuggestion { self.loading = false }
            }
        }
    }

    /// Measures how well each of Apple's scores ranks your Favorites above the rest, and saves the
    /// summary to ~/Library/Application Support/Keeper/Reports/score-calibration.csv. Summary numbers only, no per-photo data.
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
            let dir = DecisionStore.directory.appendingPathComponent("Reports")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? csv.write(to: dir.appendingPathComponent("score-calibration.csv"), atomically: true, encoding: .utf8)
            log.notice("calibration: \(rows.count) signals against \(favorites.count) favorites")
        }
    }

    /// Reads the ratings you've given in Photos, checks how well a model of them predicts ratings it
    /// wasn't fitted to, and switches the stars to that model if it beats curation. Background work;
    /// a few seconds for a big library.
    /// `usingLaunchRead`: at launch, take the stars from Photos' database, read moments ago with the
    /// suggestions (the same ratings PhotoKit gives for every analysed photo, without visiting all
    /// 200,000 again). After you've rated photos, they're read fresh from PhotoKit.
    func learnFromRatings(usingLaunchRead: Bool = false) {
        guard let base = recommender, base.hasScores, learning != .learning else { return }
        learning = .learning
        let library = library, libraryName = libraryName, existingSample = calibrationSample
        Task { [weak self] in
            let started = ContinuousClock.now
            let (evaluation, model, sample) = await Task.detached(priority: .utility) {
                var clock = StageClock("learning")
                let ratings = usingLaunchRead ? base.files.compactMapValues { $0.rating > 0 ? $0.rating : nil }
                                              : library.photoRatings()
                clock.lap("read ratings")
                let rated = ratings.compactMap { uuid, rating -> RatedPhoto? in
                    guard let s = base.scores[uuid], s.isAnalysed else { return nil }
                    return RatedPhoto(uuid: uuid, scores: s, rating: rating)
                }
                let evaluation = RatingEvaluation.evaluate(rated)
                clock.lap("evaluate")
                let model = evaluation.modelWins ? RatingModel.fit(rated) : nil
                clock.lap("fit")
                // The sample only needs the stars, not the look-alike groups.
                let sample = existingSample.isEmpty
                    ? base.with(model: .some(model), groups: []).calibrationSample(excluding: Set(ratings.keys))
                    : existingSample
                clock.lap("sample")
                Self.saveLearningReport(evaluation, model: model, libraryName: libraryName)
                return (evaluation, model, sample)
            }.value
            guard let self else { return }
            log.notice("learning: \(evaluation.rated) ratings, model \(evaluation.model), curation \(evaluation.curation) in \(started.duration(to: .now), privacy: .public)")
            self.fittedModel = model
            self.inputsVersion += 1
            var clock = StageClock("learning")
            await self.rebuildRecommender()
            clock.lap("rebuild suggestions")
            self.learning = model != nil ? .fitted(evaluation) : .usingCuration(evaluation)
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

    /// Summary of what was learned, in ~/Library/Application Support/Keeper/Reports/rating-calibration.csv: how well each
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
        let dir = DecisionStore.directory.appendingPathComponent("Reports")
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

    // MARK: Selecting photos (Unreviewed)

    /// Photos picked to accept suggested ratings for, by local identifier. Apart from the cursor:
    /// ⌘-click or G picks one, Shift-click a run, ⌘A the lot, Esc none.
    @Published private(set) var selectedPhotos: Set<String> = []
    @Published private(set) var selectingAll = false
    private var photoAnchor: Int?

    /// Every list but Duplicates and Similar Shots, where G and the checkboxes pick whole groups.
    var selectsPhotos: Bool { !source.isGroups && sections == nil }

    func togglePhoto(at i: Int) {
        guard selectsPhotos, list.indices.contains(i) else { return }
        let id = list.asset(at: i).localIdentifier
        if selectedPhotos.contains(id) { selectedPhotos.remove(id) } else { selectedPhotos.insert(id) }
        photoAnchor = i
        select(index: i)
    }

    /// Shift-click: every photo from the last one picked (or the cursor) to this one. They're picked,
    /// or unpicked when this one was picked, so a run can be taken out again.
    func selectPhotos(through i: Int) {
        guard selectsPhotos, list.indices.contains(i) else { return }
        let from = photoAnchor ?? cursor
        let list = list
        let ids = (min(from, i)...max(from, i)).filter(list.indices.contains).map { list.asset(at: $0).localIdentifier }
        if selectedPhotos.contains(list.asset(at: i).localIdentifier) { selectedPhotos.subtract(ids) }
        else { selectedPhotos.formUnion(ids) }
        photoAnchor = i
        select(index: i)
    }

    func selectAllPhotos() async {
        let list = list
        selectingAll = true
        let ids = await Task.detached(priority: .userInitiated) { list.indices.map { list.asset(at: $0).localIdentifier } }.value
        selectedPhotos = Set(ids)
        selectingAll = false
    }

    /// Click-and-drag: exactly these photos (plus `base`, when ⌘ or Shift was held), as the
    /// rectangle grows and shrinks.
    func selectPhotos(indices: [Int], adding base: Set<String>) {
        guard selectsPhotos else { return }
        let list = list
        var ids = base
        for i in indices where list.indices.contains(i) { ids.insert(list.asset(at: i).localIdentifier) }
        if ids != selectedPhotos { selectedPhotos = ids }
        if let last = indices.last { photoAnchor = last }
    }

    func deselectAllPhotos() {
        selectedPhotos = []
        photoAnchor = nil
    }

    /// The selected photos with no rating yet that have a suggested one, as decisions before and
    /// after taking it (marked seen, so they leave Unreviewed). Worked out in the background: a
    /// selection can hold most of the library.
    func suggestedRatingsToAccept() async -> Change? {
        guard let recommender, recommender.hasScores, !selectedPhotos.isEmpty else { return nil }
        let list = list, snapshot = decisions, chosen = selectedPhotos
        let (before, after) = await Task.detached(priority: .userInitiated) { () -> ([Decision], [Decision]) in
            var before: [Decision] = [], after: [Decision] = []
            let now = Date()
            for i in list.indices {
                let asset = list.asset(at: i)
                guard chosen.contains(asset.localIdentifier) else { continue }
                var d = snapshot[asset.localIdentifier] ?? .untouched(asset.localIdentifier)
                guard d.flag == .none, asset.rating.rawValue == 0 else { continue }
                let uuid = String(asset.localIdentifier.split(separator: "/").first ?? "")
                guard let stars = recommender.suggestion(forUUID: uuid)?.stars, stars > 0 else { continue }
                d.rating = 0
                d.favorite = asset.isFavorite
                var a = d.applying(.rate(stars), currentFavorite: asset.isFavorite, at: now)
                a.seenAt = now
                before.append(d)
                after.append(a)
            }
            // Looked up here, not on the main thread, where commit would otherwise do it.
            let missing = after.filter { $0.cloudID == nil }.map(\.assetID)
            var cloud: [String: String] = [:]
            for start in stride(from: 0, to: missing.count, by: 1000) {
                let chunk = Array(missing[start..<min(start + 1000, missing.count)])
                for (id, result) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: chunk) {
                    if case .success(let c) = result { cloud[id] = c.archivalStringValue }
                }
            }
            for i in after.indices where after[i].cloudID == nil { after[i].cloudID = cloud[after[i].assetID] }
            return (before, after)
        }.value
        guard !after.isEmpty else { return nil }
        return Change(label: "Accept \(after.count.formatted()) Suggested Ratings", before: before, after: after)
    }

    /// Rates them all in one step (⌘Z undoes it), then lists what's left to review.
    func acceptSuggestedRatings(_ change: Change) {
        commit(change)
        deselectAllPhotos()
        show("Rated \(change.after.count.formatted()) photos with their suggested stars. ⌘Z undoes.")
        reload()
    }

    /// Rejected: take the reject off the selected photos, in one step (⌘Z undoes it).
    func unrejectSelected() {
        let assets = library.assets(withIDs: Array(selectedPhotos)).filter { decision($0).flag == .reject }
        guard !assets.isEmpty else { return }
        let before = assets.map(decision)
        let after = assets.map { decision($0).applying(.clearFlag, currentFavorite: $0.isFavorite) }
        commit(Change(label: "Unreject \(assets.count.formatted())", before: before, after: after))
        deselectAllPhotos()
        show("Took the reject off \(assets.count.formatted()) photos. ⌘Z undoes.")
        reload()
    }

    // MARK: State

    var current: PHAsset? { list.indices.contains(cursor) ? list.asset(at: cursor) : nil }

    /// The photo the next decision applies to: the focused frame in compare, otherwise the cursor.
    var target: PHAsset? {
        mode == .compare && compareGroup.indices.contains(compareFocus) ? compareGroup[compareFocus] : current
    }

    /// Keeper's record for a photo, with the rating taken from Photos itself (macOS 27 ratings),
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

    /// Rejected photos still in the library. Ones already in Photos' Recently Deleted keep their
    /// reject in Keeper's records (in case they're recovered) but aren't counted.
    var rejectCount: Int { counts[.rejected] ?? 0 }

    // MARK: Sources and filters

    func select(_ newSource: Source) {
        guard newSource != source else { return }
        if source == .calibrate { learnFromRatings() }
        saveCursor()
        selectedPhotos = []
        photoAnchor = nil
        source = newSource
        if let data = try? JSONEncoder().encode(newSource) {
            try? store.setSetting("source", to: String(decoding: data, as: UTF8.self))
        }
        zoomed = false
        reload(restoreFrom: (try? store.setting("cursor.\(newSource.key)")) ?? nil)
    }

    /// Fetches the source (lazy, fast) and applies the filter. Decisions don't call this, so the
    /// list stays put while you work; switching source or filter does.
    /// `quietly`: an update to the list you're looking at (Sideways Photos while its scan finds more,
    /// or after rotating some): the current photos stay on screen and in their places until the new
    /// list is ready, with new ones added at the end, instead of a progress view and a re-sort.
    private func reload(restoreFrom id: String? = nil, quietly: Bool = false) {
        let keepID = id ?? current?.localIdentifier
        let started = ContinuousClock.now
        let result = source == .sideways
            ? library.assets(fetching: Array(sideways.keys))
            : library.fetch(source, newestFirst: sort == .newest, range: dateRange)
        log.notice("open: fetched \(result.count) photos for \(self.source.title) in \(started.duration(to: .now), privacy: .public)")
        var keepOrder: [String: Int] = [:]
        if quietly, source == .sideways {
            for i in list.indices { keepOrder[list.asset(at: i).localIdentifier] = i }
        }
        apply(result, keepingID: keepID, quietly: quietly, keepOrder: keepOrder)
    }

    private func apply(_ result: PHFetchResult<PHAsset>, keepingID: String?, quietly: Bool = false,
                       keepOrder: [String: Int] = [:]) {
        filterTask?.cancel()
        let keepAsset = keepingID.flatMap { library.assets(withIDs: [$0]).first }

        // The common case needs no scan: every photo in the source, straight from PhotoKit.
        let byAdded = sort == .recentlyAdded && source.sorts && source != .sideways
        if filter == .all && source != .unreviewed && source != .rejected && source != .sideways && !source.isSuggestion && !byAdded {
            loading = false
            sections = nil
            sectionGroups = []
            setList(AssetList(result: result, positions: nil), keeping: keepAsset)
            return
        }

        // Suggestion sources wait for Apple's scores; loadSuggestions() reloads when they arrive.
        loading = !quietly || list.isEmpty
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
        let sideways = sideways, minConfidence = sidewaysMinConfidence, sidewaysSort = sidewaysSort
        let sampleOrder = Dictionary(calibrationSample.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // Duplicates or Similar Shots: each unresolved group together, in date order, the one to keep first.
        var groupOrder: [String: Double] = [:]
        var listedGroups: [LookAlikeGroup] = []
        if let kind = source.groupKind, let recommender {
            for group in recommender.lookAlikes(kind) where !Self.isResolved(group, decisions, localIDs: groupLocalIDs) {
                for (rank, uuid) in group.members.enumerated() {
                    groupOrder[uuid] = Double(listedGroups.count) * 10_000 + Double(rank)
                }
                listedGroups.append(group)
            }
        }
        let libraryURL = libraryURL
        filterTask = Task { [weak self] in
            let started = ContinuousClock.now
            let (positions, ordered, sections, groupIndices) = await Task.detached(priority: .userInitiated) { () -> ([Int], Bool, [Range<Int>]?, [Int]) in
                // Recently Added: when each photo was added, from Photos' database. A photo it doesn't
                // know yet was only just added.
                let added = byAdded ? ((try? PhotosDatabase.readAddedDates(inLibrary: libraryURL)) ?? [:]) : [:]
                var out: [(position: Int, keep: Double)] = []
                result.enumerateObjects { asset, i, _ in
                    let d = snapshot[asset.localIdentifier]
                    if source == .unreviewed, d?.seenAt != nil { return }
                    if source == .rejected, d?.flag != .reject { return }
                    let flag = d?.flag ?? .none
                    switch filter {
                    case .all: break
                    case .notRejected: if flag != .none { return }
                    case .unrated: if flag != .none || asset.rating.rawValue != 0 { return } // still to rate
                    case .favorites: if !asset.isFavorite { return }
                    case .rejects: if flag != .reject { return }
                    }
                    if source == .sideways {
                        // Surest first; out of date once the photo has changed since it was checked.
                        // A moved modification date is checked again (proposedRotation), not dropped.
                        guard let r = sideways[asset.localIdentifier], r.confidence >= minConfidence else { return }
                        // Photos already listed keep their places; new finds follow, surest first.
                        if let place = keepOrder[asset.localIdentifier] { out.append((i, Double(place) - 1_000_000_000)) }
                        else {
                            // The list comes newest first.
                            switch sidewaysSort {
                            case .newest: out.append((i, Double(i)))
                            case .oldest: out.append((i, -Double(i)))
                            default: out.append((i, -r.confidence))
                            }
                        }
                        return
                    }
                    guard source.isSuggestion else {
                        if byAdded {
                            let uuid = String(asset.localIdentifier.split(separator: "/").first ?? "")
                            out.append((i, -(added[uuid] ?? .infinity)))
                        } else {
                            out.append((i, 0))
                        }
                        return
                    }
                    let uuid = String(asset.localIdentifier.split(separator: "/").first ?? "")
                    if source == .calibrate {
                        if let order = sampleOrder[uuid] { out.append((i, Double(order))) }
                        return
                    }
                    if source.isGroups {
                        if let order = groupOrder[uuid] { out.append((i, order)) }
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
                case .calibrate, .duplicates, .similarShots, .sideways: out.sort { $0.keep < $1.keep }
                default:
                    guard byAdded else { return (out.map(\.position), true, nil, []) }
                    // Newest additions first; photos added together, newest taken first.
                    out.sort { $0.keep != $1.keep ? $0.keep < $1.keep : $0.position > $1.position }
                    return (out.map(\.position), false, nil, [])
                }
                // A group's photos share an order key's ten-thousands: split the list there.
                var sections: [Range<Int>]?
                if source.isGroups {
                    sections = []
                    var start = 0
                    for i in out.indices.dropFirst() where Int(out[i].keep / 10_000) != Int(out[i - 1].keep / 10_000) {
                        sections!.append(start..<i)
                        start = i
                    }
                    if !out.isEmpty { sections!.append(start..<out.count) }
                }
                // The ten-thousands of a section's order key is its group's index in listedGroups.
                let groupIndices = (sections ?? []).map { Int(out[$0.lowerBound].keep / 10_000) }
                return (out.map(\.position), false, sections, groupIndices)
            }.value
            guard let self, !Task.isCancelled else { return }
            log.notice("open: filtered \(result.count) photos to \(positions.count) in \(started.duration(to: .now), privacy: .public)")
            self.loading = false
            var newList = AssetList(result: result, positions: positions)
            newList.ascending = ordered
            self.sections = sections
            self.sectionGroups = groupIndices.map { listedGroups[$0] }
            self.setList(newList, keeping: keepAsset)
        }
    }

    private func setList(_ newList: AssetList, keeping asset: PHAsset?) {
        list = newList
        titleDates.refresh(newList)
        groupAnchor = nil
        if let asset, let i = newList.index(of: asset) {
            cursor = i
        } else {
            cursor = min(cursor, max(newList.count - 1, 0))
        }
        if mode == .compare { rebuildCompareGroup() }
    }

    /// Sidebar counts, worked out in the background. Unreviewed is "all photos minus the ones
    /// you've looked at", from Keeper's own records, so it never scans the library.
    /// After decisions and photos you've seen: counts again once you pause, so the sidebar keeps up
    /// (Duplicates going to 0 as you resolve its groups) without recounting on every key press.
    private func scheduleCountsRefresh() {
        countsDebounce?.cancel()
        countsDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            if !Task.isCancelled { self?.refreshCounts() }
        }
    }
    private var countsDebounce: Task<Void, Never>?

    func refreshCounts() {
        countsDebounce?.cancel()
        countsTask?.cancel()
        let library = library
        let seenIDs = decisions.values.filter { $0.seenAt != nil }.map(\.assetID)
        let rejectedIDs = decisions.values.filter { $0.flag == .reject }.map(\.assetID)
        let range = dateRange
        let albums = library.albums.map { Source.album(id: $0.localIdentifier, title: $0.localizedTitle ?? "Untitled") }
        let recommender = recommender
        let sampleCount = calibrationSample.count
        var unresolvedPhotos: [SimilarGroup.Kind: Int] = [:]
        for g in recommender?.lookAlikes ?? [] where !Self.isResolved(g, decisions, localIDs: groupLocalIDs) {
            unresolvedPhotos[g.kind, default: 0] += g.members.count
        }
        let sidewaysDates = sideways.filter { $0.value.confidence >= sidewaysMinConfidence }.mapValues(\.modDate)
        let haveGroups = !groups.isEmpty || { if case .ready = similarity { return true } else { return false } }()
        countsTask = Task { [weak self] in
            let started = ContinuousClock.now
            let out = await Task.detached(priority: .utility) { () -> [Source: Int] in
                var out: [Source: Int] = [:]
                let all = library.fetch(.allPhotos, newestFirst: false).count
                out[.allPhotos] = all
                // Only seen photos still in the library count, so deleted ones can't hold it above 0.
                out[.unreviewed] = max(all - library.assets(withIDs: seenIDs).count, 0)
                out[.rejected] = library.assets(withIDs: rejectedIDs).count
                if let recommender, recommender.hasScores {
                    let c = recommender.counts()
                    out[.suggestedRejects] = c.rejects
                    out[.bestShots] = c.best
                }
                out[.calibrate] = sampleCount
                if haveGroups {
                    out[.duplicates] = unresolvedPhotos[.duplicate] ?? 0
                    out[.similarShots] = unresolvedPhotos[.similar] ?? 0
                }
                // Sideways Photos: proposals still matching the photo as it is now.
                // Still in the library (a moved modification date is checked again, not dropped).
                out[.sideways] = library.assets(withIDs: Array(sidewaysDates.keys)).count
                for s in [Source.favorites, .dateRange, .screenshots, .bursts] + albums {
                    if Task.isCancelled { break }
                    out[s] = library.fetch(s, newestFirst: false, range: range).count
                }
                return out
            }.value
            guard let self, !Task.isCancelled else { return }
            log.notice("open: counted \(out.count) sources in \(started.duration(to: .now), privacy: .public)")
            self.counts = out
        }
    }

    // MARK: Library changes

    /// While a bulk write is going to Photos, its many change reports are left for one reload at the end.
    private var bulkWrites = 0
    private var saves: Task<Void, Never>?

    private func bulkWritesFinished(ids: Set<String>) {
        for id in ids where (photosWritesInFlight[id] ?? 0) <= 0 {
            pendingRatings[id] = nil
            pendingFavorites[id] = nil
        }
        reload()
        refreshCounts()
    }

    private func libraryChanged(_ change: PHChange) {
        guard bulkWrites == 0 else { return }
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
            // Compare holds its own photos: swap in the changed ones, so a rotation shows there too.
            let changed = Dictionary(details.changedObjects.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
            if mode == .compare, compareGroup.contains(where: { changed[$0.localIdentifier] != nil }) {
                compareGroup = compareGroup.map { changed[$0.localIdentifier] ?? $0 }
            }
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

    /// `extending` (Shift) selects every group from the one the cursor was in to this photo's.
    func select(index: Int, extending: Bool = false, from section: Int? = nil) {
        guard list.indices.contains(index) else { return }
        if sections != nil {
            groupAnchor = extending ? (groupAnchor ?? section ?? cursorSection) : nil
        }
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
        openedWithSpace = false // spacePressed sets it again after opening
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
        scheduleCountsRefresh()
    }

    // MARK: Compare

    func focusCompare(_ index: Int) {
        guard compareGroup.indices.contains(index) else { return }
        compareFocus = index
        markSeen(compareGroup[index])
    }

    /// The current photo's group of duplicates or similar shots (best first), its burst frames, or
    /// photos taken within 10 seconds of it: 2–4 in all.
    private func rebuildCompareGroup() {
        guard let cur = current else { compareGroup = []; return }
        var group: [PHAsset]
        if let members = groupMembers(of: cur), members.count > 1 {
            let at = members.firstIndex { $0.localIdentifier == cur.localIdentifier } ?? 0
            let start = min(max(at - 1, 0), max(members.count - 4, 0))
            group = Array(members[start..<min(start + 4, members.count)])
        } else if let burst = cur.burstIdentifier {
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
        if mode != .compare, source.isGroups, let asset = current { keepInGroup(asset); return }
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
        afterUndoOrRedo(change)
    }

    func redo() {
        guard let change = history.redo() else { return }
        commit(change, record: false)
        show("Redo \(change.label)")
        afterUndoOrRedo(change)
    }

    /// Duplicates and Similar Shots list only unmerged groups, so an undone merge brings its group back.
    private func afterUndoOrRedo(_ change: Change) {
        if source.isGroups || (source == .sideways && !change.sidewaysHidden.isEmpty) {
            reload(quietly: source == .sideways)
            refreshCounts()
        } else {
            revealFirst(of: change)
        }
    }

    private func revealFirst(of change: Change) {
        guard mode != .compare, let id = change.after.first?.assetID ?? change.rotations.keys.first,
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
        // One update, not one per photo: each change to a published dictionary redraws the window
        // (and copies it), which froze Keeper when accepting ratings for most of a library.
        var updated = decisions
        for d in after { updated[d.assetID] = d }
        decisions = updated
        // Saved in order, off the main thread when it's a big batch.
        let store = store, previousSave = saves
        let toSave = after
        saves = Task.detached(priority: .userInitiated) { [weak self] in
            await previousSave?.value
            do {
                try store.save(toSave)
            } catch {
                await self?.show("Couldn't save: \(error.localizedDescription)")
            }
        }
        if record {
            history.record(Change(label: change.label, before: change.before, after: after, rotations: change.rotations,
                                  sidewaysHidden: change.sidewaysHidden))
        }
        if !after.isEmpty { scheduleCountsRefresh() }
        applySidewaysHidden(change.sidewaysHidden)
        let rotatedBack = change.rotations.keys.filter { change.sidewaysHidden[$0] == false }

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
            let library = self.library
            let ids = pairs.filter { !PhotosChange(from: $0.0, to: $0.1).isEmpty }.map(\.0.assetID)
            let items: [(asset: PHAsset, change: PhotosChange)] = await Task.detached(priority: .userInitiated) {
                let assets = Dictionary(library.assets(withIDs: ids).map { ($0.localIdentifier, $0) },
                                        uniquingKeysWith: { a, _ in a })
                return pairs.compactMap { before, after in
                    guard let asset = assets[after.assetID] else { return nil }
                    return (asset, PhotosChange(from: before, to: after))
                }
            }.value
            // Thousands of photos: Photos reports each batch, and checking every report against the
            // list would freeze the window, so reports wait until the last batch and the list reloads once.
            let bulk = items.count > PhotoLibrary.batchSize
            if bulk { self.bulkWrites += 1 }
            defer {
                if bulk {
                    self.bulkWrites -= 1
                    if self.bulkWrites == 0 { self.bulkWritesFinished(ids: Set(photosIDs)) }
                }
            }
            do {
                if !items.isEmpty {
                    try await library.apply(items) { done, total in
                        if bulk { self.show("Saving to Photos: \(done.formatted()) of \(total.formatted())…", sticky: true) }
                    }
                    if bulk { self.show("Saved \(items.count.formatted()) photos to Photos.") }
                }
                try await self.rotate(change.rotations)
                self.sidewaysRotatedBack(rotatedBack)
            } catch let error as PhotoRotator.RotateError {
                if record { self.history.discardLast() }
                self.show("Couldn't rotate: \(error.localizedDescription)")
            } catch {
                // Roll back so Keeper never shows a state Photos doesn't have.
                for id in photosIDs {
                    self.pendingRatings[id] = nil
                    self.pendingFavorites[id] = nil
                }
                var restored = self.decisions
                for d in change.before { restored[d.assetID] = d }
                self.decisions = restored
                await self.saves?.value
                try? self.store.save(change.before)
                if record { self.history.discardLast() }
                self.show("Couldn't update Photos: \(error.localizedDescription)")
            }
        }
    }

    /// R: turn the photo 90° clockwise, as an edit in Photos (the original is kept). ⌘Z turns it back.
    func rotateTarget() {
        guard let asset = target else { return }
        commit(Change(label: "Rotate", before: [], after: [], rotations: [asset.localIdentifier: 90]))
    }

    private func rotate(_ rotations: [String: Int]) async throws {
        guard !rotations.isEmpty else { return }
        show("Rotating…")
        for asset in library.assets(withIDs: Array(rotations.keys)) {
            let rotation = Rotation(degrees: rotations[asset.localIdentifier] ?? 0)
            do {
                try await PhotoRotator.rotate(asset, by: rotation)
            } catch let error as PhotoRotator.RotateError {
                throw error
            } catch {
                throw PhotoRotator.RotateError.renderFailed(error.localizedDescription)
            }
        }
        message = nil
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
        var remaining = decisions
        for id in ids { remaining[id] = nil }
        decisions = remaining
        try? store.remove(ids)
        // Keeper can't bring deleted photos back (Photos' Recently Deleted can), so undo stops here.
        history.clear()
        show("Deleted \(ids.count) photos. They're in Recently Deleted in Photos for 30 days.")
        return true
    }

    // MARK: Zoom

    /// Space opened this photo from the grid, so Space again goes back to the grid.
    private var openedWithSpace = false

    /// Space, like Quick Look: from the grid it shows the photo filling the window, and the next
    /// press goes back to the grid. In a photo opened with Return, it switches 100% zoom on and off.
    func spacePressed() {
        if mode == .grid {
            mode = .single
            openedWithSpace = true
        } else if zoomed {
            zoomed = false
        } else if openedWithSpace && mode == .single {
            openedWithSpace = false
            mode = .grid
        } else {
            toggleZoom(onFace: false)
        }
    }

    /// Return: between the grid and the photo; a photo opened this way zooms with Space.
    func openWithReturn() {
        openedWithSpace = false
        mode = mode == .grid ? .single : .grid
    }

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

    func show(_ text: String, sticky: Bool = false) {
        message = text
        // The bubble (KeeperToast) closes itself after 10 seconds.
    }
}

/// A weak reference background work can hold without keeping a closed library's session alive.
final class WeakSession: @unchecked Sendable {
    weak var value: CullingSession?
    init(_ value: CullingSession) { self.value = value }
}

/// How a date-ordered list is sorted.
enum PhotoSort: String, CaseIterable, Identifiable {
    case oldest = "Oldest First"
    case newest = "Newest First"
    case recentlyAdded = "Recently Added"
    /// Sideways Photos only: the photos Keeper is surest about first.
    case certainty = "Most Certain First"

    static let storageKey = "photoSort"
    static let sidewaysStorageKey = "sidewaysSort"

    /// The choices a list offers.
    static func options(sideways: Bool) -> [PhotoSort] {
        sideways ? [.certainty, .oldest, .newest] : [.oldest, .newest, .recentlyAdded]
    }
    var id: String { rawValue }
}

/// The dates of the photos in view, for the window's subtitle. Kept apart from the session, so
/// scrolling changes only the subtitle and doesn't redraw the grid.
@MainActor
final class TitleDates: ObservableObject {
    @Published private(set) var text: String?
    /// The grid's visible indexes, nil in single photo and compare.
    private var visible: [Int]?

    private static let formatter: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// "Jun 3 – Aug 12, 2019": the earliest and latest date among the photos at these indexes.
    func show(_ indexes: [Int], in list: AssetList) {
        visible = indexes
        refresh(list)
    }

    /// The list changed under the same scroll position (another sort, a photo removed).
    func refresh(_ list: AssetList) {
        guard let visible else { return }
        let dates = visible.filter { list.indices.contains($0) }.compactMap { list.asset(at: $0).creationDate }
        guard let first = dates.min(), let last = dates.max() else { return clear() }
        let new = Self.formatter.string(from: first, to: last)
        if new != text { text = new }
    }

    /// One photo's date, in single photo and compare.
    func show(_ date: Date?) {
        visible = nil
        let new = date.map { Self.formatter.string(from: $0, to: $0) }
        if new != text { text = new }
    }

    func clear() {
        visible = nil
        if text != nil { text = nil }
    }
}
