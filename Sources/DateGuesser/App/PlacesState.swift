import DateGuessCore
import Foundation
import Observation

/// The Places tab: photos with no location, where each was probably taken, and what the user chose.
@MainActor
@Observable
final class PlacesState {
    @ObservationIgnored weak var app: AppState?
    @ObservationIgnored private let store = JSONStore.shared

    var scan: PlacesScan
    var decisions: [String: PlaceDecision] { didSet { scheduleDecisionSave() } }
    /// ⌘Z for the decisions above.
    @ObservationIgnored var decisionHistory = DecisionHistory<PlaceDecision>()
    var journal: [PlaceBatch] { didSet { store.save(journal, to: "placesJournal") } }
    /// Guesses for photos still without a location.
    var guesses: [String: PlaceGuessResult] = [:] {
        didSet { confidentCount = guesses.values.reduce(0) { $0 + ($1.level == .high ? 1 : 0) } }
    }
    /// How many guesses are confident: the sidebar count, kept here so redrawing it is free.
    private(set) var confidentCount = 0
    /// Photos still without a location, oldest first (the order Photos shows them).
    var order: [String] = []
    /// Photos with a real date grouped by camera and time, biggest first.
    var outings: [[String]] = []
    /// What was learned about each camera.
    var calibration = PlaceCalibration()
    /// Each photo's camera, read from the Photos library.
    @ObservationIgnored var cameras: [String: String] = [:]
    /// How often look-alike guesses matched the place the user applied.
    var lookalikeStat: ClueCalibration.Stat { didSet { store.save(lookalikeStat, to: "placeCalibration") } }

    var isScanning = false
    var scanProgress: (done: Int, total: Int)?
    var isGuessing = false
    var isApplying = false
    var applyProgress: (done: Int, total: Int)?

    @ObservationIgnored private var guessTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var decisionsSaveTask: Task<Void, Never>?

    /// Geotagged photos fingerprinted to learn what each place looks like.
    static let referencePrintLimit = 4000
    /// Photos without a location that get a fingerprint when nothing else places them (fingerprints
    /// take a while on a big library, and every one is kept).
    static let queryPrintLimit = 15000
    nonisolated static let lookalikeWeight = 0.6

    init() {
        scan = store.load(PlacesScan.self, from: "placesScan") ?? PlacesScan()
        decisions = store.load([String: PlaceDecision].self, from: "placeDecisions") ?? [:]
        journal = store.load([PlaceBatch].self, from: "placesJournal") ?? []
        lookalikeStat = store.load(ClueCalibration.Stat.self, from: "placeCalibration") ?? ClueCalibration.Stat()
        refreshOrder()
    }

    // MARK: Derived

    /// Photos placed in this app (and not undone), with where.
    var placed: [String: PlaceJournalEntry] {
        var out: [String: PlaceJournalEntry] = [:]
        for batch in journal.reversed() where !batch.undone {
            for entry in batch.entries { out[entry.assetID] = entry }
        }
        return out
    }

    func decision(_ id: String) -> PlaceDecision { decisions[id] ?? PlaceDecision() }

    /// What would be written: the user's place, or else the guess.
    func effectivePoint(_ id: String) -> GeoPoint? { decision(id).override?.point ?? guesses[id]?.estimate.point }

    func date(_ id: String) -> Date? { scan.missing[id] ?? nil }

    var checkedForApply: [String] {
        order.filter { decisions[$0]?.selected == true && decisions[$0]?.ignored != true && effectivePoint($0) != nil }
    }

    func refreshOrder() {
        let placed = Set(self.placed.keys)
        order = scan.missing.keys.filter { !placed.contains($0) }.sorted { a, b in
            let da = scan.missing[a] ?? nil, db = scan.missing[b] ?? nil
            switch (da, db) {
            case let (x?, y?): return x != y ? x < y : a < b
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return a < b
            }
        }
    }

    // MARK: Scan

    func startScan() {
        guard !isScanning, app?.isAuthorized == true else { return }
        isScanning = true
        scanProgress = (0, 0)
        scanTask = Task {
            let result = await LocationScanner.run { done, total in
                await MainActor.run { self.scanProgress = (done, total) }
            }
            self.isScanning = false
            self.scanProgress = nil
            guard !Task.isCancelled, result.located.count + result.missing.count > 0 else { return }
            self.scan = result
            self.store.save(result, to: "placesScan")
            self.refreshOrder()
            // Then learns what places look like, for photos nothing else places.
            self.recompute { self.app?.startFingerprinting() }
        }
    }

    // MARK: Guessing

    /// Photos whose date is good to the minute: not undated, and not dated by this app.
    private func untrustedDates() -> Set<String> {
        guard let app else { return [] }
        return Set(app.scan.undated.keys).union(app.appliedIDs)
    }

    /// How many times the guesses have been started (one more each `recompute`).
    @ObservationIgnored private(set) var runs = 0

    func recompute(then done: (@MainActor () -> Void)? = nil) {
        guard let app else { return }
        guessTask?.cancel()
        runs += 1
        let run = runs
        isGuessing = true
        let scan = self.scan
        let placed = self.placed
        let ids = order
        let untrusted = untrustedDates()
        let prints = app.featurePrints
        let links = app.eventLinks
        let cameras = self.cameras
        let lookalike = lookalikeStat
        guessTask = Task.detached(priority: .utility) {
            let started = ContinuousClock.now
            let calibration = Self.calibrate(scan: scan, cameras: cameras)
            Timing.note("places #\(run) calibrate", since: started)
            let guesses = Self.guesses(ids: ids, scan: scan, placed: placed, untrusted: untrusted, prints: prints,
                                       links: links, cameras: cameras, calibration: calibration, lookalike: lookalike)
            let outings = Self.outings(ids: ids, scan: scan, untrusted: untrusted, cameras: cameras)
            Timing.note("places #\(run) for \(ids.count) photos\(Task.isCancelled ? " (cancelled, thrown away)" : "")", since: started)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.calibration = calibration
                self.guesses = guesses
                self.outings = outings
                self.isGuessing = false
                done?()
            }
        }
    }

    /// How reliable each camera's time clues are, from its own photos that have a location.
    nonisolated static func calibrate(scan: PlacesScan, cameras: [String: String]) -> PlaceCalibration {
        guard !cameras.isEmpty else { return PlaceCalibration() }
        let photos = (0..<scan.located.count).map { i in
            PlaceCalibration.Photo(camera: cameras[scan.located.ids[i]], time: scan.located.times[i], point: scan.located.point(i))
        }
        return PlaceCalibration.learn(photos)
    }

    /// Outings of photos with a real date, in the order the list shows them.
    nonisolated static func outings(ids: [String], scan: PlacesScan, untrusted: Set<String>, cameras: [String: String]) -> [[String]] {
        let photos: [PlaceOutings.Photo] = ids.compactMap { id in
            guard !untrusted.contains(id), let date = scan.missing[id] ?? nil else { return nil }
            return PlaceOutings.Photo(id: id, time: date, camera: cameras[id])
        }
        return PlaceOutings.group(photos)
    }

    nonisolated static func guesses(ids: [String], scan: PlacesScan, placed: [String: PlaceJournalEntry],
                                    untrusted: Set<String>, prints: [String: Data],
                                    links: [String: [EventLinks.Link]], cameras: [String: String] = [:],
                                    calibration: PlaceCalibration = PlaceCalibration(),
                                    lookalike: ClueCalibration.Stat = .init()) -> [String: PlaceGuessResult] {
        var references: [PlaceTimeline.Reference] = []
        references.reserveCapacity(scan.located.count + placed.count)
        for i in 0..<scan.located.count {
            references.append(.init(id: scan.located.ids[i], time: scan.located.times[i], point: scan.located.point(i)))
        }
        for (id, entry) in placed where !untrusted.contains(id) {
            if let date = scan.missing[id] ?? nil {
                references.append(.init(id: id, time: date, point: entry.new, placedHere: true))
            }
        }
        let timeline = PlaceTimeline(references)

        var examples: [PlaceProbe.Example] = []
        for i in 0..<scan.located.count {
            if let p = prints[scan.located.ids[i]] {
                examples.append(.init(id: scan.located.ids[i], point: scan.located.point(i), print: EventLinks.unpack(p)))
            }
        }
        for (id, entry) in placed { if let p = prints[id] { examples.append(.init(id: id, point: entry.new, print: EventLinks.unpack(p))) } }
        if Task.isCancelled { return [:] } // a newer run replaced this one
        let probe = PlaceProbe(examples)
        var queries: [String: [Float]] = [:]
        for id in ids { if let p = prints[id] { queries[id] = EventLinks.unpack(p) } }
        // Look-alikes count less if the places the user set keep disagreeing with them.
        let lookalikes = probe.evidence(for: queries, maxWeight: lookalikeWeight * lookalike.factor)

        var out: [String: PlaceGuessResult] = [:]
        for (n, id) in ids.enumerated() {
            if n % 512 == 0, Task.isCancelled { return [:] }
            var evidence: [PlaceEvidence] = []
            if !untrusted.contains(id), let date = scan.missing[id] ?? nil {
                evidence += timeline.evidence(at: date, excluding: id, reliability: calibration.reliability(camera: cameras[id]))
            }
            if let e = lookalikes[id] { evidence.append(e) }
            for link in links[id] ?? [] {
                guard let entry = placed[link.assetID] else { continue }
                evidence.append(PlaceEvidence(source: .sameEvent, summary: "Looks like it’s from the same event as a photo you placed",
                                              point: entry.new, weight: min(0.8, link.weight), referenceID: link.assetID))
            }
            if let estimate = PlaceFusion.estimate(evidence) {
                let result = PlaceGuessResult(estimate: estimate, evidence: evidence.sorted { $0.weight > $1.weight })
                // Too weak to be worth showing as a place.
                if result.level != .low { out[id] = result }
            }
        }
        return out
    }

    /// Photos to fingerprint for place guesses: a spread of geotagged photos to learn from, then
    /// photos nothing else places yet, newest first.
    func fingerprintQueue(have prints: [String: Data]) -> [String] {
        var out: [String] = []
        // Geotagged photos, round-robin over places (about 10 km squares) and years.
        let located = scan.located
        var cells: [String: [Int]] = [:]
        var printed = 0
        let calendar = Calendar(identifier: .gregorian)
        for i in 0..<located.count {
            if prints[located.ids[i]] != nil { printed += 1; continue }
            let year = calendar.component(.year, from: located.times[i])
            let key = "\(Int((located.lats[i] * 10).rounded())),\(Int((located.lons[i] * 10).rounded())),\(year)"
            cells[key, default: []].append(i)
        }
        let budget = max(0, Self.referencePrintLimit - printed)
        if budget > 0 {
            var columns = cells.values.map { $0.reversed() as [Int] }.sorted { $0.count > $1.count }
            while out.count < budget, !columns.isEmpty {
                var next: [[Int]] = []
                for var column in columns {
                    guard out.count < budget, let i = column.popLast() else { continue }
                    out.append(located.ids[i])
                    if !column.isEmpty { next.append(column) }
                }
                columns = next
            }
        }
        // Photos without a good clue yet.
        let unplaced = order.reversed().filter { id in
            prints[id] == nil && (guesses[id]?.estimate.confidence ?? 0) < 0.5
        }
        out += unplaced.prefix(Self.queryPrintLimit)
        return out
    }

    func setCameras(_ cameras: [String: String]) {
        guard cameras != self.cameras else { return }
        self.cameras = cameras
        if scan.lastScan != nil { recompute() }
    }

    // MARK: Decisions

    /// Every selected photo still without a location, whatever the filter shows (Esc clears them all).
    var allSelected: [String] { order.filter { decisions[$0]?.selected == true } }

    func setSelected(_ id: String, _ selected: Bool) {
        decisionHistory.record([id], from: decisions)
        decisions[id, default: PlaceDecision()].selected = selected
    }

    func select(_ ids: [String], _ selected: Bool) {
        decisionHistory.record(ids, from: decisions)
        var copy = decisions
        for id in ids where copy[id]?.ignored != true { copy[id, default: PlaceDecision()].selected = selected }
        decisions = copy
    }

    func setIgnored(_ id: String, _ ignored: Bool) {
        decisionHistory.record([id], from: decisions)
        decisions[id, default: PlaceDecision()].ignored = ignored
        if ignored { decisions[id]?.selected = false }
    }

    /// The user's place for one photo (nil goes back to the guess). Checks it, ready to apply.
    func setOverride(_ id: String, _ choice: PlaceChoice?) {
        decisionHistory.record([id], from: decisions)
        decisions[id, default: PlaceDecision()].override = choice
        if choice != nil { decisions[id]?.selected = true }
    }

    /// One place for many photos at once.
    func setPlace(_ ids: [String], _ choice: PlaceChoice) {
        decisionHistory.record(ids, from: decisions)
        var copy = decisions
        for id in ids where copy[id]?.ignored != true {
            copy[id, default: PlaceDecision()].override = choice
            copy[id]?.selected = true
        }
        decisions = copy
    }

    // MARK: Apply & undo

    func applyChecked() {
        guard !isApplying else { return }
        let changes: [PlaceWriter.Change] = checkedForApply.compactMap { id in
            guard let point = effectivePoint(id) else { return nil }
            let name = decision(id).override?.name ?? PlaceNames.shared.name(for: point)
            return PlaceWriter.Change(assetID: id, point: point, name: name)
        }
        guard !changes.isEmpty else { return }
        // Were the look-alike clues right about the places being applied?
        var stat = lookalikeStat
        for change in changes {
            guard let point = change.point, let clue = guesses[change.assetID]?.evidence.first(where: { $0.source == .lookalike }) else { continue }
            stat.count += 1
            if clue.point.distanceKm(to: point) < PlaceFusion.areaKm { stat.hits += 1 }
        }
        lookalikeStat = stat
        isApplying = true
        applyProgress = (0, changes.count)
        Task {
            let batch = await PlaceWriter.apply(changes) { done, total in
                await MainActor.run { self.applyProgress = (done, total) }
            }
            if !batch.entries.isEmpty { self.journal.insert(batch, at: 0) }
            var copy = self.decisions
            for entry in batch.entries { copy[entry.assetID]?.selected = false }
            self.decisions = copy
            // Photos that turned out to have a location aren't missing one: take them off the list.
            let located = batch.failures.filter { $0.value == PlaceWriter.changedElsewhere }.keys
            if !located.isEmpty {
                var scan = self.scan
                for id in located { scan.missing.removeValue(forKey: id) }
                self.scan = scan
                self.store.save(scan, to: "placesScan")
            }
            self.isApplying = false
            self.applyProgress = nil
            self.refreshOrder()
            self.recompute()
            let skipped = batch.failures.values.filter { $0 == PlaceWriter.changedElsewhere }.count
            let failed = batch.failures.count - skipped
            self.app?.banner = "Set the location of \(batch.entries.count.formatted()) photos in Photos."
                + (skipped == 0 ? "" : " Skipped \(skipped) that got a location in Photos since the last scan.")
                + (failed == 0 ? "" : " \(failed) couldn’t be changed.")
        }
    }

    func undo(_ batch: PlaceBatch) {
        guard !isApplying, !batch.undone else { return }
        isApplying = true
        applyProgress = (0, batch.entries.count)
        Task {
            let result = await PlaceWriter.undo(batch) { done, total in
                await MainActor.run { self.applyProgress = (done, total) }
            }
            if let i = self.journal.firstIndex(where: { $0.id == batch.id }) { self.journal[i].undone = true }
            self.isApplying = false
            self.applyProgress = nil
            self.refreshOrder()
            self.recompute()
            let restored = batch.entries.count - result.failures.count
            self.app?.banner = "Removed the locations set here from \(restored.formatted()) photos"
                + (result.failures.isEmpty ? "." : " (\(result.failures.count) couldn’t be changed).")
        }
    }

    // MARK: Saving

    private func scheduleDecisionSave() {
        decisionsSaveTask?.cancel()
        decisionsSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            store.save(decisions, to: "placeDecisions")
        }
    }

    func saveNow() {
        decisionsSaveTask?.cancel()
        store.save(decisions, to: "placeDecisions")
    }
}
