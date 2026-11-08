import Foundation
import Observation
import Photos
import DateGuessCore

/// The app's single source of truth. Long-running work (scan, estimate, apply) runs in background
/// tasks and reports back here on the main actor.
@MainActor
@Observable
final class AppState {
    let store = JSONStore.shared
    private let library = PhotoLibraryService.shared
    /// The Places tab's guesses and choices.
    @ObservationIgnored let places = PlacesState()
    @ObservationIgnored let albumTools = AlbumsState()

    // MARK: Persistent state

    var settings: AppSettings {
        didSet {
            store.save(settings, to: "settings")
            if oldValue.allowExactMonth != settings.allowExactMonth || oldValue.earliestYear != settings.earliestYear {
                scheduleRecompute()
            }
            if oldValue.useAppleIntelligence != settings.useAppleIntelligence && usesAppleIntelligence { startEstimation() }
        }
    }
    var scan: ScanSnapshot
    var groups: [PhotoGroup] { didSet { store.save(groups, to: "groups"); scheduleRecompute(); refreshEventSuggestions() } }
    var people: [PersonInfo] { didSet { store.save(people, to: "people"); scheduleRecompute() } }
    /// People the user says are in a single photo (asset ID → who and how old).
    var photoPeople: [String: [GroupPersonHint]] { didSet { store.save(photoPeople, to: "photoPeople"); scheduleRecompute() } }
    /// Face tags read from the Photos library's People album.
    var taggedPeople: [TaggedPerson] { didSet { store.save(taggedPeople, to: "taggedPeople"); scheduleRecompute() } }
    /// When the user used each camera.
    var cameraPeriods: [CameraPeriod] { didSet { store.save(cameraPeriods, to: "cameraPeriods"); scheduleRecompute() } }
    /// Faces Photos detected in undated photos (asset ID → faces).
    var detectedFaces: [String: [DetectedFace]] { didSet { store.save(detectedFaces, to: "detectedFaces"); scheduleRecompute() } }
    /// How old each named person looks, from the optional face-age model: photo → face group → years.
    var faceAges: [String: [String: Double]] = [:] { didSet { scheduleFaceAgeSave(); scheduleRecompute() } }
    @ObservationIgnored var faceAgeSaveTask: Task<Void, Never>?
    /// Image fingerprints of undated photos, used to find look-alikes from the same event.
    var featurePrints: [String: Data] = [:]
    /// Look-alike matches between undated photos (recomputed when fingerprints, faces or the scan change).
    var eventLinks: [String: [EventLinks.Link]] = [:]
    /// Dated photos of the same face groups as undated ones, read from the Photos library.
    var referenceCandidates: [String: ReferenceCandidate] {
        didSet { store.save(referenceCandidates, to: "referenceCandidates") }
    }
    /// Clues from matching undated photos to dated ones (see `EventLinks.referenceEvidence`).
    var referenceClues: [String: DateEvidence] = [:]
    /// "Looks most like your dated photos from …" (see `YearProbe`).
    var lookalikeClues: [String: DateEvidence] = [:]
    /// Checked on the user's own dated photos: 0.3–0.7 did about equally well.
    nonisolated static let lookalikeWeight = 0.4
    /// Likely events among undated photos (see `EventClusters`), not yet saved or dismissed.
    var eventSuggestions: [[String]] = []
    /// The date each suggested event would get if saved now (keyed by `eventKey`).
    var eventEstimates: [String: DateEstimate] = [:]
    /// Each undated photo's firm year limits, from the last estimate pass.
    @ObservationIgnored var photoLimits: [String: YearLimits] = [:]
    @ObservationIgnored private var limitsUsedForEvents: [String: YearLimits]? = nil
    /// Suggestions the user said aren't one event (keyed by `eventKey`).
    var dismissedEvents: Set<String> { didSet { store.save(dismissedEvents, to: "dismissedEvents"); refreshEventSuggestions() } }
    @ObservationIgnored private var allEventClusters: [[String]] = []
    /// Comparing every photo for events takes a minute or two on a large library.
    var isFindingEvents = false
    @ObservationIgnored private var printsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var linksTask: Task<Void, Never>?
    var isImportingPeople = false
    var analyses: [String: PhotoAnalysis]
    var decisions: [String: ReviewDecision] { didSet { scheduleDecisionSave() } }
    /// ⌘Z for the decisions above.
    @ObservationIgnored var decisionHistory = DecisionHistory<ReviewDecision>()
    var journal: [ApplyBatch] {
        didSet { appliedIDs = Self.applied(in: journal); store.save(journal, to: "journal"); scheduleRecompute() }
    }

    // MARK: Session state

    var authorization: PHAuthorizationStatus
    var albums: [AlbumInfo] = []
    var undatedSorted: [UndatedPhoto] = []
    var estimates: [String: ComputedEstimate] = [:]

    var scanProgress: ScanProgress?
    var isScanning = false
    var estimationProgress: EstimationProgress?
    var isEstimating = false
    var applyProgress: (done: Int, total: Int)?
    var isApplying = false
    var banner: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored var estimateTask: Task<Void, Never>?
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored private var analysesSaveTask: Task<Void, Never>?
    @ObservationIgnored private var decisionsSaveTask: Task<Void, Never>?

    init() {
        let initStarted = ContinuousClock.now
        defer { Timing.note("startup on main", since: initStarted) }
        settings = store.load(AppSettings.self, from: "settings") ?? AppSettings()
        scan = store.load(ScanSnapshot.self, from: "scan") ?? ScanSnapshot()
        groups = store.load([PhotoGroup].self, from: "groups") ?? []
        people = store.load([PersonInfo].self, from: "people") ?? []
        photoPeople = store.load([String: [GroupPersonHint]].self, from: "photoPeople") ?? [:]
        taggedPeople = store.load([TaggedPerson].self, from: "taggedPeople") ?? []
        detectedFaces = store.load([String: [DetectedFace]].self, from: "detectedFaces") ?? [:]
        faceAges = store.load([String: [String: Double]].self, from: "faceAges") ?? [:]
        cameraPeriods = store.load([CameraPeriod].self, from: "cameraPeriods") ?? []
        featurePrints = store.loadBinary([String: Data].self, from: "featurePrints") ?? [:]
        referenceCandidates = store.load([String: ReferenceCandidate].self, from: "referenceCandidates") ?? [:]
        dismissedEvents = store.load(Set<String>.self, from: "dismissedEvents") ?? []
        analyses = store.load([String: PhotoAnalysis].self, from: "analyses") ?? [:]
        decisions = store.load([String: ReviewDecision].self, from: "decisions") ?? [:]
        let savedJournal = store.load([ApplyBatch].self, from: "journal") ?? []
        journal = savedJournal
        appliedIDs = Self.applied(in: savedJournal)
        keptShifts = store.load(Set<String>.self, from: "keptShifts") ?? []
        // Last launch's events, so they show right away while they're worked out again.
        allEventClusters = store.load([[String]].self, from: "eventClusters") ?? []
        authorization = PhotoLibraryService.shared.authorizationStatus
        refreshUndatedList()
        refreshEventSuggestions()
        recomputeEstimates()
        if isAuthorized {
            loadAlbums()
            // Picks up where a previous session stopped. On-device only, so it's free.
            if scan.lastScan != nil {
                startEstimation()
                if !isEstimating { startFingerprinting() }
            }
        }
        // Unless fingerprinting found nothing to do and already started them.
        if !featurePrints.isEmpty && linksRuns == 0 { recomputeLinks() }
        places.app = self
        if places.scan.lastScan != nil { places.recompute() }
        albumTools.app = self
        if isAuthorized { albumTools.refresh() }
        // Picks up names added in Photos since last time, without asking for the library again.
        hasSavedLibrary = Self.keeperLibrary != nil
            || (store.load(Data.self, from: "photosLibrary").map { !$0.isEmpty } ?? false)
        refreshFromPhotos()
    }

    var isAuthorized: Bool { authorization == .authorized || authorization == .limited }

    /// Decodes everything `init` and `PlacesState.init` load, several files at once, off the main
    /// thread: about 140 MB of JSON in a big library, which froze the window when done in `init`.
    nonisolated static func preload(into store: JSONStore) {
        let jobs: [() -> Void] = [
            { store.preload(AppSettings.self, from: "settings") },
            { store.preload(ScanSnapshot.self, from: "scan") },
            { store.preload([PhotoGroup].self, from: "groups") },
            { store.preload([PersonInfo].self, from: "people") },
            { store.preload([String: [GroupPersonHint]].self, from: "photoPeople") },
            { store.preload([TaggedPerson].self, from: "taggedPeople") },
            { store.preload([String: [DetectedFace]].self, from: "detectedFaces") },
            { store.preload([String: [String: Double]].self, from: "faceAges") },
            { store.preload([CameraPeriod].self, from: "cameraPeriods") },
            { store.preloadBinary([String: Data].self, from: "featurePrints") },
            { store.preload([String: ReferenceCandidate].self, from: "referenceCandidates") },
            { store.preload(Set<String>.self, from: "dismissedEvents") },
            { store.preload([String: PhotoAnalysis].self, from: "analyses") },
            { store.preload([String: ReviewDecision].self, from: "decisions") },
            { store.preload([ApplyBatch].self, from: "journal") },
            { store.preload(Set<String>.self, from: "keptShifts") },
            { store.preload([[String]].self, from: "eventClusters") },
            { store.preload(PlacesScan.self, from: "placesScan") },
            { store.preload([String: PlaceDecision].self, from: "placeDecisions") },
            { store.preload([PlaceBatch].self, from: "placesJournal") },
        ]
        DispatchQueue.concurrentPerform(iterations: jobs.count) { jobs[$0]() }
    }

    // MARK: Authorization

    func requestAccess() async {
        authorization = await library.requestAuthorization()
        if isAuthorized { loadAlbums() }
    }

    func loadAlbums() {
        Task.detached(priority: .utility) {
            let albums = PhotoLibraryService.shared.userAlbums()
            await MainActor.run { self.albums = albums }
        }
    }

    // MARK: Derived

    /// Photos dated here and not undone. Kept up to date with `journal`, since the toolbar and
    /// several screens read it on every redraw.
    private(set) var appliedIDs: Set<String> = []

    nonisolated static func applied(in journal: [ApplyBatch]) -> Set<String> {
        var ids = Set<String>()
        for batch in journal { ids.formUnion(batch.liveEntries.map(\.assetID)) }
        return ids
    }

    var ignoredIDs: Set<String> { Set(decisions.filter { $0.value.ignored }.map(\.key)) }

    func photo(_ id: String) -> UndatedPhoto? { scan.undated[id] }

    func groupFor(_ assetID: String) -> PhotoGroup? { groups.first { $0.assetIDs.contains(assetID) } }

    /// The lowest year a guess or a manual change can use.
    var lowestYear: Int { max(YearBounds.earliestPhotoYear, settings.earliestYear ?? YearBounds.earliestPhotoYear) }

    /// The estimate after the user's overrides.
    func effectiveEstimate(_ id: String) -> DateEstimate? {
        guard let base = estimates[id]?.estimate else { return nil }
        let d = decisions[id] ?? ReviewDecision()
        if !d.isOverridden { return base }
        return base.overridden(year: d.overrideYear, season: d.overrideSeason, month: d.overrideMonth)
    }

    /// Photos never analyzed, or analyzed by older on-device rules.
    var pendingAnalysisIDs: [String] {
        let model = usesAppleIntelligence
        return undatedSorted.map(\.id).filter { id in
            guard let a = analyses[id] else { return true }
            return !a.isCurrent || (model && a.modelChecked != true)
        }
    }

    /// Apple Intelligence is on in Settings and this Mac has it.
    var usesAppleIntelligence: Bool { settings.useAppleIntelligence != false && OnDeviceModel.isAvailable }

    func refreshUndatedList() {
        let applied = appliedIDs
        undatedSorted = scan.undated.values
            .filter { !applied.contains($0.id) }
            .sorted { a, b in
                switch (a.libraryDate, b.libraryDate) {
                case let (x?, y?) where x != y: return x < y
                default: return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
                }
            }
    }

    // MARK: Scan

    /// - Parameter includeApplied: also re-check photos this app already dated. Normally they're
    ///   skipped for good (until undone), since their files still have no capture date.
    func startScan(includeApplied: Bool = false) {
        guard !isScanning else { return }
        isScanning = true
        banner = nil
        scanProgress = ScanProgress(phase: "Starting…")
        let scanner = LibraryScanner(options: settings.scan, previous: scan, excludedIDs: includeApplied ? ignoredIDs : appliedIDs.union(ignoredIDs))
        scanTask = Task {
            do {
                // `run` is @concurrent, so it runs off the main thread; awaiting it directly keeps cancellation working.
                let result = try await scanner.run { p in await MainActor.run { self.scanProgress = p } }
                self.authorization = self.library.authorizationStatus
                // An empty library almost always means macOS isn't showing this copy of the app your
                // photos (e.g. after a rebuild). Keep the previous results rather than wiping them.
                guard result.totalAssets > 0 else {
                    self.store.save(self.library.accessDiagnostics(), to: "scan-diagnostics")
                    self.banner = self.authorization == .limited
                        ? "Keeper can only see the photos you picked for it. To scan your whole library, open System Settings ▸ Privacy & Security ▸ Photos and choose Full Access."
                        : "macOS didn’t let Keeper see any photos. Open System Settings ▸ Privacy & Security ▸ Photos, turn Keeper off and on again (or choose Full Access), then quit and reopen the app."
                    self.isScanning = false
                    self.scanProgress = nil
                    return
                }
                self.scan = result
                self.store.save(result, to: "scan")
                self.refreshUndatedList()
                self.recomputeEstimates()
                self.banner = "Found \(result.undated.count.formatted()) photos that need a date out of \(result.totalAssets.formatted())."
                // Guess dates right away; everything runs on this Mac.
                self.isScanning = false
                self.refreshFromPhotos()
                // A new scan is an explicit request to analyze, so it lifts a Stop.
                self.settings.backgroundPaused = nil
                self.startEstimation()
                self.places.startScan()
            } catch is CancellationError {
                self.banner = "Scan stopped."
            } catch {
                self.banner = "Scan failed: \(error.localizedDescription)"
            }
            self.isScanning = false
            self.scanProgress = nil
        }
    }

    func cancelScan() { scanTask?.cancel() }

    // MARK: Estimate

    /// Analyzes photos on this Mac. - Parameter ids: defaults to those not analyzed yet.
    func startEstimation(ids: [String]? = nil) {
        guard !isEstimating, settings.backgroundPaused != true else { return }
        let targets = (ids ?? pendingAnalysisIDs).compactMap { scan.undated[$0] }
        guard !targets.isEmpty else { startFingerprinting(); return }
        isEstimating = true
        let engine = EstimationEngine(photos: targets, useOnDeviceModel: usesAppleIntelligence)
        estimationProgress = EstimationProgress(phase: "Starting…", total: targets.count)
        estimateTask = Task {
            await engine.run(
                progress: { p in await MainActor.run { self.estimationProgress = p } },
                deliver: { results in await MainActor.run { self.receive(results) } })
            self.isEstimating = false
            self.saveAnalysesNow()
            self.recomputeEstimates()
            self.estimationProgress = nil
            if !Task.isCancelled { self.startFingerprinting() }
        }
    }

    /// Fingerprints photos analyzed before fingerprints existed, then finds look-alikes.
    /// Photos whose fingerprint couldn't be made this session (no local preview, say): not tried
    /// again until next launch, since each try ended in saving every fingerprint and redoing the
    /// links and places for nothing.
    @ObservationIgnored private var fingerprintFailed = Set<String>()

    func startFingerprinting() {
        guard !isEstimating, settings.backgroundPaused != true else { recomputeLinks(); return }
        let failed = fingerprintFailed
        let undatedMissing = undatedSorted.map(\.id).filter { featurePrints[$0] == nil && analyses[$0] != nil && !failed.contains($0) }
        let referencesMissing = trustedReferenceIDs.filter { featurePrints[$0] == nil && !failed.contains($0) }
        let have = Set(undatedMissing + referencesMissing).union(failed)
        let placesMissing = places.fingerprintQueue(have: featurePrints).filter { !have.contains($0) }
        let missing = undatedMissing + referencesMissing + placesMissing
        Timing.note("fingerprints to make: \(undatedMissing.count) undated, \(referencesMissing.count) dated, \(placesMissing.count) for places")
        guard !missing.isEmpty else { recomputeLinks(); places.recompute(); startFaceAges(); return }
        isEstimating = true
        let phase = !undatedMissing.isEmpty ? "Comparing photos to find ones from the same event…"
            : !referencesMissing.isEmpty ? "Comparing with your dated photos…" : "Learning what your places look like…"
        estimationProgress = EstimationProgress(phase: phase, total: missing.count)
        let linksBefore = linksRuns, placesBefore = places.runs
        estimateTask = Task {
            var made = 0
            await EstimationEngine.fingerprints(
                for: missing,
                progress: { done in await MainActor.run { self.estimationProgress?.done = done } },
                deliver: { batch in await MainActor.run {
                    guard !batch.isEmpty else { return }
                    made += batch.count
                    self.featurePrints.merge(batch) { _, new in new }
                    self.scheduleFeaturePrintSave()
                } })
            self.isEstimating = false
            self.estimationProgress = nil
            if !Task.isCancelled { self.fingerprintFailed.formUnion(missing.filter { self.featurePrints[$0] == nil }) }
            Timing.note("fingerprints made: \(made) of \(missing.count)")
            if made > 0 { self.saveFeaturePrintsNow() }
            // No new fingerprints, and a run started since this began (at launch, say): it already
            // has everything this would give it.
            if made > 0 || self.linksRuns == linksBefore { self.recomputeLinks() }
            if made > 0 || self.places.runs == placesBefore { self.places.recompute() }
            if !Task.isCancelled { self.startFaceAges() }
        }
    }

    /// Dated photos whose date can be trusted: a GPS location, or a capture date the scan checked.
    var trustedReferenceIDs: [String] {
        referenceCandidates.compactMap { id, c in
            (c.hasGPS || scan.checkedDatedIDs.contains(id)) && scan.undated[id] == nil ? id : nil
        }
    }

    /// Finds look-alike photos off the main thread, then re-estimates.
    @ObservationIgnored private var linksRuns = 0

    func recomputeLinks() {
        linksTask?.cancel()
        linksRuns += 1
        let run = linksRuns, prepStarted = ContinuousClock.now
        let order = undatedSorted.map(\.id)
        let packed = featurePrints.filter { scan.undated[$0.key] != nil }
        // Who's in each photo: named people plus Photos' unnamed face groups.
        var who: [String: Set<String>] = [:]
        for (asset, faces) in detectedFaces { who[asset] = Set(faces.compactMap(\.clusterID)) }
        for (asset, hints) in allPhotoPeople() { who[asset, default: []].formUnion(hints.map(\.personID.uuidString)) }
        // Dated photos to compare with: verified dates of the same people, and photos dated here.
        var refPacked: [String: (Data, Int, Int?, Set<String>, Bool)] = [:]
        for id in trustedReferenceIDs {
            guard let c = referenceCandidates[id], let p = featurePrints[id] else { continue }
            refPacked[id] = (p, c.year, c.month, Set(c.clusterIDs), false)
        }
        let confirmed = confirmedDates()
        for c in confirmed {
            guard let p = featurePrints[c.id] else { continue }
            refPacked[c.id] = (p, c.year, c.month, [], true)
        }
        // Every dated photo with a fingerprint teaches the look of its year.
        var probePacked: [(String, Int, Data)] = confirmed.compactMap { c in featurePrints[c.id].map { (c.id, c.year, $0) } }
        let confirmedIDs = Set(confirmed.map(\.id))
        for (id, c) in referenceCandidates where scan.undated[id] == nil && !confirmedIDs.contains(id) {
            if let p = featurePrints[id] { probePacked.append((id, c.year, p)) }
        }
        let limits = photoLimits
        limitsUsedForEvents = limits
        isFindingEvents = !packed.isEmpty
        Timing.note("links #\(run) prep on main", since: prepStarted)
        linksTask = Task.detached(priority: .utility) {
            let started = ContinuousClock.now
            var lap = ContinuousClock.now
            func stage(_ name: String) { Timing.note("links #\(run) \(name)", since: lap); lap = .now }
            let prints = packed.mapValues(EventLinks.unpack)
            stage("unpack")
            let links = EventLinks.find(order: order, prints: prints, people: who)
            stage("links")
            guard !Task.isCancelled else { return }
            let references = refPacked.mapValues { r in
                EventLinks.Reference(print: EventLinks.unpack(r.0), year: r.1, month: r.2, people: r.3, datedHere: r.4)
            }
            let clues = EventLinks.referenceEvidence(undated: prints, people: who, references: references)
            stage("references (\(references.count))")
            guard !Task.isCancelled else { return }
            let probe = YearProbe(probePacked.map { .init(id: $0.0, year: $0.1, print: EventLinks.unpack($0.2)) })
            let lookalikes = probe.evidence(for: prints, maxWeight: AppState.lookalikeWeight)
            stage("look-alikes (\(probePacked.count))")
            guard !Task.isCancelled else { return }
            let events = EventClusters.find(order: order, prints: prints, people: who, limits: limits)
            stage("events")
            Timing.note("links #\(run) for \(prints.count) photos\(Task.isCancelled ? " (cancelled, thrown away)" : "")", since: started)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.eventLinks = links
                self.referenceClues = clues
                self.lookalikeClues = lookalikes
                self.allEventClusters = events
                self.store.save(events, to: "eventClusters")
                self.isFindingEvents = false
                self.refreshEventSuggestions()
                self.recomputeEstimates()
            }
        }
    }

    private func scheduleFeaturePrintSave() {
        guard printsSaveTask == nil else { return }
        printsSaveTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            // Cancelled when saved sooner: a cancelled sleep ends at once, and this would save again.
            guard !Task.isCancelled else { return }
            self.saveFeaturePrintsNow()
        }
    }

    func saveFeaturePrintsNow() {
        printsSaveTask?.cancel()
        printsSaveTask = nil
        store.saveBinary(featurePrints, to: "featurePrints")
    }

    /// Stops background analysis and keeps it stopped (across relaunches) until Resume.
    func cancelEstimation() {
        settings.backgroundPaused = true
        estimateTask?.cancel()
        isEstimating = false
        estimationProgress = nil
    }

    func resumeBackgroundWork() {
        settings.backgroundPaused = nil
        startEstimation()
    }

    /// Photos still waiting for on-device analysis or fingerprints.
    var backgroundWorkLeft: Int {
        pendingAnalysisIDs.count
            + undatedSorted.filter { featurePrints[$0.id] == nil && analyses[$0.id] != nil }.count
    }

    private func receive(_ results: [PhotoAnalysis]) {
        var copy = analyses
        for var r in results {
            if let print = r.featurePrint { featurePrints[r.assetID] = print }
            r.featurePrint = nil
            // Keep Apple Intelligence's earlier answer if this run skipped it.
            if r.modelChecked != true, let old = copy[r.assetID], old.modelChecked == true {
                r.modelSeason = old.modelSeason
                r.modelOccasion = old.modelOccasion
                r.modelChecked = true
            }
            copy[r.assetID] = r
        }
        analyses = copy
        scheduleFeaturePrintSave()
        scheduleAnalysesSave()
        scheduleRecompute(delay: 1.5)
    }

    // MARK: Fusion

    func scheduleRecompute(delay: Double = 0.3) {
        recomputeTask?.cancel()
        recomputeTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            recomputeEstimates()
        }
    }

    @ObservationIgnored private var recomputeGeneration = 0

    func recomputeEstimates() {
        recomputeGeneration += 1
        let generation = recomputeGeneration
        let prepStarted = ContinuousClock.now
        let undated = scan.undated, analyses = self.analyses, groups = self.groups, people = self.people
        let photoPeople = self.allPhotoPeople()
        let links = self.eventLinks
        let referenceClues = self.referenceClues
        let lookalikeClues = self.lookalikeClues
        let exact = settings.allowExactMonth
        let earliest = settings.earliestYear
        let cameras = cameraPeriods
        let events = eventSuggestions
        let confirmed = confirmedDates()
        let formats = appliedFormats(confirmed.map(\.id), undated: undated)
        let faceReadings = self.faceReadings()
        let faceCorrection = self.faceAgeCorrection()
        let located = places.scan.located
        let notReferences = Set(undated.keys).union(appliedIDs)
        Timing.note("estimates #\(generation) prep on main", since: prepStarted)
        Task.detached(priority: .userInitiated) {
            let started = ContinuousClock.now
            let placeClues = AppState.placeDateClues(located: located, undated: undated, notReferences: notReferences)
            let result = AppState.computeEstimates(undated: undated, analyses: analyses, groups: groups,
                                                   people: people, photoPeople: photoPeople, links: links,
                                                   referenceClues: referenceClues, lookalikeClues: lookalikeClues,
                                                   earliestYear: earliest, cameras: cameras, events: events,
                                                   confirmed: confirmed, formats: formats,
                                                   faceReadings: faceReadings, faceCorrection: faceCorrection,
                                                   placeClues: placeClues, allowExactMonth: exact)
            Timing.note("estimates #\(generation) for \(undated.count) photos", since: started)
            await MainActor.run {
                guard generation == self.recomputeGeneration else {
                    Timing.note("estimates #\(generation) thrown away")
                    return
                }
                self.estimates = result.estimates
                self.eventEstimates = result.events
                self.photoLimits = result.limits
                // Event suggestions depend on these limits; regroup once if they changed.
                if result.limits != self.limitsUsedForEvents { self.recomputeLinks() }
            }
        }
    }

    struct ConfirmedDate: Sendable {
        var id: String
        var year: Int
        var month: Int
    }

    /// The date each photo dated here has now (the latest change that wasn't undone).
    func confirmedDates() -> [ConfirmedDate] {
        var seen = Set<String>()
        var out: [ConfirmedDate] = []
        let calendar = Calendar.current
        for batch in journal {   // newest first
            for entry in batch.liveEntries where seen.insert(entry.assetID).inserted {
                let c = calendar.dateComponents([.year, .month], from: entry.newDate)
                if let year = c.year, let month = c.month { out.append(ConfirmedDate(id: entry.assetID, year: year, month: month)) }
            }
        }
        return out
    }

    /// Sizes of dated photos that have left the scan, for telling digital photos from scans.
    @ObservationIgnored private var formatCache: [String: FormatInfo] = [:]

    private func appliedFormats(_ ids: [String], undated: [String: UndatedPhoto]) -> [String: FormatInfo] {
        let missing = ids.filter { undated[$0] == nil && formatCache[$0] == nil }
        if !missing.isEmpty && isAuthorized {
            for (id, asset) in PhotoLibraryService.shared.assets(for: missing) {
                formatCache[id] = FormatInfo(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
            }
        }
        return formatCache
    }

    struct EstimateResults {
        var estimates: [String: ComputedEstimate] = [:]
        /// The shared date each suggested event would get if saved now (keyed by `eventKey`).
        var events: [String: DateEstimate] = [:]
        /// Each photo's firm year limits (from hard constraints only).
        var limits: [String: YearLimits] = [:]
    }

    /// Undated photos that have a location, dated by the dated photos taken near them (a trip).
    /// Photos dated here don't count as dated: they'd only echo a guess.
    nonisolated static func placeDateClues(located: LocatedPhotos, undated: [String: UndatedPhoto],
                                           notReferences: Set<String>) -> [String: DateEvidence] {
        var targets: [String: GeoPoint] = [:]
        var references: [PlaceDateClues.Reference] = []
        references.reserveCapacity(located.count)
        for i in 0..<located.count {
            let id = located.ids[i]
            if undated[id] != nil { targets[id] = located.point(i) }
            else if !notReferences.contains(id) { references.append(.init(time: located.times[i], point: located.point(i))) }
        }
        return PlaceDateClues.evidence(for: targets, references: references)
    }

    nonisolated static func computeEstimates(undated: [String: UndatedPhoto], analyses: [String: PhotoAnalysis],
                                             groups: [PhotoGroup], people: [PersonInfo],
                                             photoPeople: [String: [GroupPersonHint]] = [:],
                                             links: [String: [EventLinks.Link]] = [:],
                                             referenceClues: [String: DateEvidence] = [:],
                                             lookalikeClues: [String: DateEvidence] = [:],
                                             earliestYear: Int? = nil,
                                             cameras: [CameraPeriod] = [],
                                             events: [[String]] = [],
                                             confirmed: [ConfirmedDate] = [],
                                             formats: [String: FormatInfo] = [:],
                                             faceReadings: [String: [FaceAgeClues.Reading]] = [:],
                                             faceCorrection: FaceAgeClues.Correction = .standard,
                                             placeClues: [String: DateEvidence] = [:],
                                             allowExactMonth: Bool) -> EstimateResults {
        // Who's in a photo: birth years, and how old they look (the face-age model when it has read
        // them, otherwise Photos' rough age groups).
        func peopleClues(_ id: String) -> [DateEvidence] {
            var clues = GroupClues.peopleEvidence(photoPeople[id] ?? [], people: people)
            if let readings = faceReadings[id], let e = FaceAgeClues.evidence(readings, people: people, correction: faceCorrection) {
                clues.removeAll { $0.calibrationKey?.hasPrefix("person:faceAge:") == true }
                clues.append(e)
            }
            return clues
        }
        let options = EvidenceFusion.Options(allowExactMonth: allowExactMonth)
        // A photo's own clues, minus film-print clues when it's plainly a digital photo.
        func photoClues(_ id: String, _ a: PhotoAnalysis) -> [DateEvidence] {
            guard let format = undated[id]?.format ?? formats[id] else { return a.evidence }
            return DigitalPhotoClues.apply(to: a.evidence, format: format)
        }
        // How the built-in clues have done on photos the user already dated.
        let calibration = ClueCalibration.build(confirmed.compactMap { c in
            analyses[c.id].map {
                ClueCalibration.Confirmed(evidence: photoClues(c.id, $0) + peopleClues(c.id),
                                          year: c.year, month: c.month)
            }
        })
        var result: [String: ComputedEstimate] = [:]
        var grouped = Set<String>()

        // Everything known about one photo on its own: its clues, who's in it, and when it was scanned.
        func evidence(_ id: String, _ a: PhotoAnalysis) -> [DateEvidence] {
            var out = photoClues(id, a).map(calibration.adjusted)
            out += peopleClues(id).map(calibration.adjusted)
            if let photo = undated[id],
               let limit = ProvenanceClues.libraryDateLimit(reason: photo.reason, libraryDate: photo.libraryDate) {
                out.append(limit)
            }
            if let earliestYear { out.append(ProvenanceClues.earliestYear(earliestYear)) }
            if let photo = undated[id], let e = CameraClues.evidence(for: photo.format, periods: cameras) { out.append(e) }
            if let e = referenceClues[id] { out.append(e) }
            if let e = lookalikeClues[id] { out.append(e) }
            if let e = placeClues[id] { out.append(e) }
            return out
        }

        var own: [String: [DateEvidence]] = [:]
        for (id, a) in analyses where undated[id] != nil { own[id] = evidence(id, a) }
        var limits: [String: YearLimits] = [:]
        for (id, e) in own {
            let l = YearLimits(e)
            if l.low != nil || l.high != nil { limits[id] = l }
        }
        // Look-alikes in the same group are already combined by the group itself.
        var groupOf: [String: UUID] = [:]
        for g in groups { for id in g.assetIDs where groupOf[id] == nil { groupOf[id] = g.id } }
        var usable: [String: [EventLinks.Link]] = [:]
        for (id, matches) in links {
            let mine = groupOf[id]
            let kept = matches.filter { own[$0.assetID] != nil && (mine == nil || groupOf[$0.assetID] != mine) }
            if !kept.isEmpty { usable[id] = kept }
        }
        let pulls = EventLinks.pulls(evidence: own, links: usable, options: options)
        func matchNote(_ id: String) -> [DateEvidence] {
            guard let n = usable[id]?.count else { return [] }
            return [DateEvidence(source: .group, summary: "Looks like the same event as \(n) other undated photo\(n == 1 ? "" : "s") (similar scene, clothes or people), so their clues count here too")]
        }

        for g in groups {
            let members = g.assetIDs.filter { undated[$0] != nil && analyses[$0] != nil && !grouped.contains($0) }
            guard !members.isEmpty else { continue }
            let groupEvidence = GroupClues.evidence(for: g, people: people)
            let fusion = members.map { id in
                GroupFusion.Member(assetID: id, evidence: own[id] ?? [])
            }
            let estimates = GroupFusion.estimates(members: fusion, groupEvidence: groupEvidence, kind: g.kind,
                                                  pulls: pulls, options: options)
            let note = DateEvidence(source: .group, summary: members.count > 1
                ? "Combined with \(members.count - 1) other photo\(members.count == 2 ? "" : "s") in “\(g.name)” (\(g.kind == .sameEvent ? "same event" : "same era"))"
                : "In the group “\(g.name)”")
            for m in fusion {
                guard let e = estimates[m.assetID] else { continue }
                result[m.assetID] = ComputedEstimate(estimate: e, evidence: [note] + matchNote(m.assetID) + groupEvidence + m.evidence,
                                                     groupName: g.name, matches: usable[m.assetID]?.map(\.assetID) ?? [])
            }
            grouped.formUnion(members)
        }

        for (id, clues) in own where !grouped.contains(id) {
            let estimate: DateEstimate
            if let p = pulls[id] {
                estimate = EvidenceFusion.estimate(from: clues, extraLogLikelihood: p.logLikelihood, extraSeasonVotes: p.seasonVotes,
                                                   extraExactDateCandidates: p.exactDates, options: options)
            } else {
                estimate = EvidenceFusion.estimate(from: clues, options: options)
            }
            result[id] = ComputedEstimate(estimate: estimate, evidence: matchNote(id) + clues, groupName: nil,
                                          matches: usable[id]?.map(\.assetID) ?? [])
        }

        // What each suggested event would be dated if saved as one event now: every photo's clues pooled.
        var eventDates: [String: DateEstimate] = [:]
        for ids in events {
            let members = ids.compactMap { id in own[id].map { GroupFusion.Member(assetID: id, evidence: $0) } }
            guard members.count >= 2, let shared = GroupFusion.estimates(members: members, groupEvidence: [], kind: .sameEvent,
                                                                         options: options)[members[0].assetID] else { continue }
            eventDates[eventKey(ids)] = shared
        }
        return EstimateResults(estimates: result, events: eventDates, limits: limits)
    }

    // MARK: Review decisions

    func decision(_ id: String) -> ReviewDecision { decisions[id] ?? ReviewDecision() }

    func setSelected(_ id: String, _ selected: Bool) {
        decisionHistory.record([id], from: decisions)
        var d = decision(id)
        d.selected = selected
        decisions[id] = d
    }

    func setOverride(_ id: String, year: Int?, season: Season?) {
        decisionHistory.record([id], from: decisions)
        var d = decision(id)
        // Picking a season replaces an exact month; "use the original guess" clears everything.
        if season != d.overrideSeason || (year == nil && season == nil) { d.overrideMonth = nil }
        d.overrideYear = year
        d.overrideSeason = season
        d.selected = true
        decisions[id] = d
    }

    /// Sets an exact month for one photo (keeping its year), and checks it.
    func setMonth(_ id: String, _ month: Int) {
        decisionHistory.record([id], from: decisions)
        var d = decision(id)
        d.overrideMonth = month
        d.overrideSeason = nil
        d.selected = true
        decisions[id] = d
    }

    func setIgnored(_ id: String, _ ignored: Bool) {
        decisionHistory.record([id], from: decisions)
        var d = decision(id)
        d.ignored = ignored
        if ignored { d.selected = false }
        decisions[id] = d
    }

    /// The same date for many photos at once. A nil season keeps each photo's own guessed season;
    /// a month sets that exact month. The photos stay checked, ready to apply.
    func setDate(_ ids: [String], year: Int, season: Season?, month: Int?) {
        decisionHistory.record(ids, from: decisions)
        var copy = decisions
        for id in ids {
            var d = copy[id] ?? ReviewDecision()
            guard !d.ignored else { continue }
            d.overrideYear = year
            d.overrideSeason = month == nil ? season : nil
            d.overrideMonth = month
            d.selected = true
            copy[id] = d
        }
        decisions = copy
    }

    func select(_ ids: [String], _ selected: Bool) {
        decisionHistory.record(ids, from: decisions)
        var copy = decisions
        for id in ids {
            var d = copy[id] ?? ReviewDecision()
            d.selected = selected && !d.ignored
            copy[id] = d
        }
        decisions = copy
    }

    var selectedForApply: [String] {
        Self.applyTargets(order: undatedSorted.map(\.id), applied: appliedIDs, decisions: decisions,
                          hasEstimate: { estimates[$0] != nil })
    }

    /// The only photos Apply may change: on the undated list from the last scan, not already dated by
    /// this app, checked, and not hidden. Groups, events and dated look-alikes never add to this.
    nonisolated static func applyTargets(order: [String], applied: Set<String>, decisions: [String: ReviewDecision],
                                         hasEstimate: (String) -> Bool) -> [String] {
        order.filter { id in
            guard let d = decisions[id], d.selected, !d.ignored, !applied.contains(id) else { return false }
            return hasEstimate(id)
        }
    }

    // MARK: Apply & undo

    func applySelected() {
        guard !isApplying else { return }
        let changes: [DateWriter.Change] = selectedForApply.compactMap { id in
            guard let date = effectiveEstimate(id)?.date() else { return nil }
            return DateWriter.Change(assetID: id, date: date, requireUnchanged: true,
                                     expectedCurrentDate: scan.undated[id]?.libraryDate)
        }
        guard !changes.isEmpty else { return }
        isApplying = true
        applyProgress = (0, changes.count)
        Task {
            let batch = await DateWriter.apply(changes) { done, total in
                await MainActor.run { self.applyProgress = (done, total) }
            }
            self.finishWrite(batch, verb: "Updated")
        }
    }

    func undo(_ batch: ApplyBatch) {
        guard !isApplying, !batch.undone else { return }
        isApplying = true
        applyProgress = (0, batch.entries.count)
        var live = batch
        live.entries = batch.liveEntries
        Task {
            let result = await DateWriter.undo(live) { done, total in
                await MainActor.run { self.applyProgress = (done, total) }
            }
            if let idx = self.journal.firstIndex(where: { $0.id == batch.id }) {
                self.journal[idx].undone = true
            }
            self.isApplying = false
            self.applyProgress = nil
            self.refreshUndatedList()
            self.banner = "Restored the previous dates of \(result.entries.count.formatted()) photos"
                + (result.failures.isEmpty ? "." : " (\(result.failures.count) couldn't be restored).")
        }
    }

    // MARK: Applied events

    /// This photo's changes by this app still in effect, oldest first.
    func liveEntries(_ id: String) -> [JournalEntry] {
        journal.reversed().flatMap { $0.liveEntries.filter { $0.assetID == id } }
    }

    /// The photos of a saved event that this app has already dated in Photos.
    func appliedMembers(_ group: PhotoGroup) -> [String] {
        let applied = appliedIDs
        return group.assetIDs.filter(applied.contains)
    }

    /// A change to an event's dates in Photos, waiting for the user to confirm (`EventDateConfirmations`).
    struct EventDateRequest: Identifiable {
        let id = UUID()
        var groupID: UUID
        var year = 0
        var month: Int?
        var season: Season?
        var count: Int
        /// Put back the dates from before, instead of setting a new one.
        var undo = false
    }

    var eventDateRequest: EventDateRequest?
    /// Bumped when a request is cancelled, so the year boxes show the event's date again.
    var eventDateResets = 0

    /// An event's photos that are neither waiting for a date here nor dated by this app: dated in Photos
    /// some other way, or left out of a later scan. They can still be redated from the event.
    func otherMembers(_ group: PhotoGroup) -> [String] {
        let open = Set(openMembers(group)), applied = appliedIDs
        let rest = group.assetIDs.filter { !open.contains($0) && !applied.contains($0) }
        // One fetch for all of them, not one per photo.
        let unknown = rest.filter { libraryDates[$0] == nil }
        if !unknown.isEmpty {
            let found = PhotoLibraryService.shared.assets(for: unknown)
            for id in unknown { libraryDates[id] = .some(found[id]?.creationDate) }
        }
        return rest.filter { libraryDate($0) != nil }
    }

    @ObservationIgnored private var libraryDates: [String: Date?] = [:]

    /// A photo's date in Photos right now (cached until this app changes dates; nil if it's gone).
    func libraryDate(_ id: String) -> Date? {
        if let cached = libraryDates[id] { return cached }
        let date = PhotoLibraryService.shared.assets(for: [id])[id]?.creationDate
        libraryDates[id] = .some(date)
        return date
    }

    /// The date each of an event's photos has in Photos: what this app applied, or what Photos has.
    func datesInPhotos(_ group: PhotoGroup) -> [String: Date] {
        var out: [String: Date] = [:]
        for id in appliedMembers(group) { if let d = liveEntries(id).last?.newDate { out[id] = d } }
        for id in otherMembers(group) { if let d = libraryDate(id) { out[id] = d } }
        return out
    }

    /// The month an event shows: the most common among its photos (their guesses, and the dates of
    /// those already in Photos). Every photo gets this month when only a year is picked.
    func eventShownMonth(_ group: PhotoGroup) -> Int? {
        let calendar = Calendar.current
        let months = openMembers(group).compactMap { effectiveEstimate($0)?.month }
            + datesInPhotos(group).values.map { calendar.component(.month, from: $0) }
        return Dictionary(grouping: months.filter { (1...12).contains($0) }, by: { $0 })
            .max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key
    }

    /// Noon on the 1st of the month, like dates applied from guesses.
    nonisolated static func appliedDate(year: Int, month: Int, calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: max(1, min(12, month)), day: 1, hour: 12))
    }

    /// Gives an event's photos that are already dated in Photos (by this app or otherwise) a new date
    /// there, undoable from History. A photo whose date changed in Photos since this app last saw it is
    /// left alone. Every photo gets the same date: without a month or a season, the event's month.
    func changeAppliedDates(_ groupID: UUID, year: Int, month: Int?, season: Season?) {
        guard !isApplying, let group = groups.first(where: { $0.id == groupID }) else { return }
        let sharedMonth = month ?? season?.representativeMonth ?? eventShownMonth(group) ?? 1
        let changes: [DateWriter.Change] = datesInPhotos(group).sorted { $0.key < $1.key }.compactMap { id, current in
            guard let date = Self.appliedDate(year: year, month: sharedMonth) else { return nil }
            return DateWriter.Change(assetID: id, date: date, requireUnchanged: true, expectedCurrentDate: current)
        }
        guard !changes.isEmpty else { return }
        isApplying = true
        applyProgress = (0, changes.count)
        Task {
            let batch = await DateWriter.apply(changes) { done, total in
                await MainActor.run { self.applyProgress = (done, total) }
            }
            self.finishWrite(batch, verb: "Changed")
        }
    }

    /// Puts back the dates an event's photos had before this app changed them, and marks those changes
    /// undone in History. Photos whose date was changed in Photos since are left alone.
    func undoAppliedDates(_ groupID: UUID) {
        guard !isApplying, let group = groups.first(where: { $0.id == groupID }) else { return }
        var changes: [DateWriter.Change] = []
        var noOriginal = 0
        for id in appliedMembers(group) {
            let entries = liveEntries(id)
            guard let current = entries.last?.newDate else { continue }
            guard let original = entries.first?.previousDate else { noOriginal += 1; continue }
            changes.append(DateWriter.Change(assetID: id, date: original, requireUnchanged: true, expectedCurrentDate: current))
        }
        guard !changes.isEmpty else {
            if noOriginal > 0 { banner = "These photos had no date before, so there’s nothing to put back." }
            return
        }
        isApplying = true
        applyProgress = (0, changes.count)
        Task {
            let result = await DateWriter.apply(changes) { done, total in
                await MainActor.run { self.applyProgress = (done, total) }
            }
            let restored = Set(result.entries.map(\.assetID))
            var copy = self.journal
            for i in copy.indices where !copy[i].undone {
                let mine = Set(copy[i].entries.map(\.assetID)).intersection(restored)
                guard !mine.isEmpty else { continue }
                copy[i].undoneIDs = (copy[i].undoneIDs ?? []).union(mine)
                if copy[i].liveEntries.isEmpty { copy[i].undone = true }
            }
            self.journal = copy
            self.libraryDates = [:]
            self.isApplying = false
            self.applyProgress = nil
            self.refreshUndatedList()
            let back = restored.filter { self.scan.undated[$0] == nil }.count
            self.banner = "Put back the earlier dates of \(restored.count.formatted()) photos."
                + (result.failures.isEmpty ? "" : " \(result.failures.count) were left alone.")
                + (back == 0 ? "" : " Scan again to review them.")
        }
    }

    private func finishWrite(_ batch: ApplyBatch, verb: String) {
        libraryDates = [:]
        if !batch.entries.isEmpty { journal.insert(batch, at: 0) }
        var copy = decisions
        for entry in batch.entries { copy[entry.assetID]?.selected = false }
        decisions = copy
        isApplying = false
        applyProgress = nil
        refreshUndatedList()
        let skipped = batch.failures.values.filter { $0 == DateWriter.changedElsewhere }.count
        let failed = batch.failures.count - skipped
        banner = "\(verb) \(batch.entries.count.formatted()) photos in your Photos library."
            + (skipped == 0 ? "" : " Skipped \(skipped) whose date was changed in Photos since the last scan.")
            + (failed == 0 ? "" : " \(failed) couldn't be changed.")
    }

    // MARK: Dates changed outside the app

    /// A photo this app dated whose date in Photos is now different (usually from Image ▸ Adjust Date
    /// and Time in Photos, which moves every selected photo by the same amount).
    struct DateShift: Identifiable, Hashable {
        var assetID: String
        var appDate: Date
        var current: Date
        var id: String { assetID }
        /// Whole days it moved (negative: earlier).
        var days: Int { Int((current.timeIntervalSince(appDate) / 86400).rounded()) }
        var keepKey: String { "\(assetID)|\(Int(appDate.timeIntervalSinceReferenceDate))" }
    }

    var dateShifts: [DateShift] = []
    var isCheckingShifts = false
    /// Shifts the user chose to keep, so they aren't listed again.
    var keptShifts: Set<String> = [] { didSet { store.save(keptShifts, to: "keptShifts") } }

    /// The date this app last set for each photo it dated (and hasn't undone).
    nonisolated static func appliedDates(_ journal: [ApplyBatch]) -> [String: Date] {
        var out: [String: Date] = [:]
        // Newest batches come first.
        for batch in journal {
            for entry in batch.liveEntries where out[entry.assetID] == nil { out[entry.assetID] = entry.newDate }
        }
        return out
    }

    /// Photos whose date no longer matches what this app set; `current` maps id → date in Photos now.
    nonisolated static func shifts(applied: [String: Date], current: [String: Date], kept: Set<String>) -> [DateShift] {
        applied.compactMap { id, mine in
            guard let now = current[id], abs(now.timeIntervalSince(mine)) >= 2 else { return nil }
            let shift = DateShift(assetID: id, appDate: mine, current: now)
            return kept.contains(shift.keepKey) ? nil : shift
        }
        .sorted { $0.appDate < $1.appDate }
    }

    func checkShiftedDates() {
        guard !isCheckingShifts, isAuthorized else { return }
        isCheckingShifts = true
        let applied = Self.appliedDates(journal)
        let kept = keptShifts
        Task.detached(priority: .userInitiated) {
            var current: [String: Date] = [:]
            for chunk in Array(applied.keys).chunked(into: 500) {
                for (id, asset) in PhotoLibraryService.shared.assets(for: chunk) { current[id] = asset.creationDate }
            }
            let found = Self.shifts(applied: applied, current: current, kept: kept)
            await MainActor.run {
                self.dateShifts = found
                self.isCheckingShifts = false
            }
        }
    }

    func keepShiftedDates(_ shifts: [DateShift]) {
        keptShifts.formUnion(shifts.map(\.keepKey))
        let gone = Set(shifts.map(\.assetID))
        dateShifts.removeAll { gone.contains($0.assetID) }
    }

    /// Gives these photos one exact date in Photos: the 1st of `month` at noon. Skips any changed again
    /// since the check; undoable from History.
    func setDateInPhotos(_ shifts: [DateShift], year: Int, month: Int) {
        guard !isApplying, !shifts.isEmpty, let date = Self.appliedDate(year: year, month: month) else { return }
        let changes = shifts.map {
            DateWriter.Change(assetID: $0.assetID, date: date, requireUnchanged: true, expectedCurrentDate: $0.current)
        }
        isApplying = true
        applyProgress = (0, changes.count)
        Task {
            let batch = await DateWriter.apply(changes) { done, total in
                await MainActor.run { self.applyProgress = (done, total) }
            }
            self.finishWrite(batch, verb: "Set the date of")
            self.checkShiftedDates()
        }
    }

    // MARK: Rotation

    var isRotating = false

    /// Turns photos 90° clockwise in Photos, as an edit (Image ▸ Revert to Original brings the
    /// original back). Dates, places, people and albums stay as they are.
    func rotate(_ ids: [String]) {
        guard !ids.isEmpty, !isRotating, isAuthorized else { return }
        isRotating = true
        banner = ids.count == 1 ? "Rotating…" : "Rotating \(ids.count.formatted()) photos…"
        Task {
            var done = 0
            var lastError: String?
            for id in ids {
                PhotoLibraryService.shared.forget(id)
                guard let asset = PhotoLibraryService.shared.asset(for: id) else { lastError = "It’s no longer in Photos."; continue }
                do {
                    try await PhotoRotator.rotate(asset, by: .clockwise90)
                    PhotoLibraryService.shared.forget(id)
                    ImageRevisions.shared.bump(id)
                    done += 1
                } catch {
                    lastError = error.localizedDescription
                }
            }
            isRotating = false
            let failed = ids.count - done
            if failed == 0 {
                banner = done == 1 ? "Rotated in Photos. Press R again to keep turning, or use Image ▸ Revert to Original in Photos."
                    : "Rotated \(done.formatted()) photos in Photos."
            } else {
                banner = (done > 0 ? "Rotated \(done.formatted()), but " : "")
                    + "\(failed.formatted()) couldn’t be rotated" + (lastError.map { ": \($0)" } ?? ".")
            }
        }
    }

    // MARK: People

    func removePerson(_ id: UUID) {
        people.removeAll { $0.id == id }
        // Changed on a copy: each change to `groups` itself saves the file and works out estimates again.
        var copy = groups
        for i in copy.indices { copy[i].people.removeAll { $0.personID == id } }
        if copy != groups { groups = copy }
        photoPeople = photoPeople.compactMapValues { hints in
            let kept = hints.filter { $0.personID != id }
            return kept.isEmpty ? nil : kept
        }
    }

    func setPhotoPeople(_ assetID: String, _ hints: [GroupPersonHint]) {
        let own = hints.filter { !$0.fromPhotos || $0.approximateAge != nil }
            .map { GroupPersonHint(id: $0.id, personID: $0.personID, approximateAge: $0.approximateAge) }
        photoPeople[assetID] = own.isEmpty ? nil : own
    }

    /// Who's in one photo: what the user said here, plus faces Photos recognized.
    func people(in assetID: String) -> [GroupPersonHint] {
        people(in: assetID, clusters: clusterPeople, tagged: nil)
    }

    /// Photos person → person here. Names come only from Photos' own name tags.
    var clusterPeople: [String: UUID] {
        var out: [String: UUID] = [:]
        for p in people { if let c = p.photosPersonID { out[c] = p.id } }
        return out
    }

    private func people(in assetID: String, clusters: [String: UUID], tagged: [UUID: Set<String>]?) -> [GroupPersonHint] {
        var hints = photoPeople[assetID] ?? []
        func add(_ personID: UUID, ageType: Int?) {
            if let i = hints.firstIndex(where: { $0.personID == personID }) {
                if hints[i].faceAgeType == nil { hints[i].faceAgeType = ageType }
            } else {
                hints.append(GroupPersonHint(personID: personID, fromPhotos: true, faceAgeType: ageType))
            }
        }
        if let faces = detectedFaces[assetID] {
            for f in faces { if let c = f.clusterID, let id = clusters[c] { add(id, ageType: f.ageType) } }
        } else {
            // Imported before face positions were read: fall back to the tag list.
            for (id, assets) in tagged ?? taggedAssetsByPerson where assets.contains(assetID) { add(id, ageType: nil) }
        }
        return hints
    }

    /// Linked person → the photos they're tagged in.
    var taggedAssetsByPerson: [UUID: Set<String>] {
        let byTag = Dictionary(taggedPeople.map { ($0.id, $0.assetIDs) }, uniquingKeysWith: { a, _ in a })
        var out: [UUID: Set<String>] = [:]
        for p in people { if let tag = p.photosPersonID, let ids = byTag[tag] { out[p.id] = Set(ids) } }
        return out
    }

    func allPhotoPeople() -> [String: [GroupPersonHint]] {
        let clusters = clusterPeople, tagged = taggedAssetsByPerson
        var assets = Set(photoPeople.keys).union(detectedFaces.keys)
        for ids in tagged.values { assets.formUnion(ids) }
        var out: [String: [GroupPersonHint]] = [:]
        // Photos dated here too: their dates show how reliable the people clues are.
        let applied = appliedIDs
        for asset in assets where scan.undated[asset] != nil || applied.contains(asset) {
            let hints = people(in: asset, clusters: clusters, tagged: tagged)
            if !hints.isEmpty { out[asset] = hints }
        }
        return out
    }

    /// How many undated photos share this face's group.
    func undatedPhotoCount(forCluster clusterID: String) -> Int {
        detectedFaces.reduce(0) { $0 + ($1.value.contains { $0.clusterID == clusterID } ? 1 : 0) }
    }

    /// Reads the People album of a Photos library and adds everyone who has a name.
    /// People already in the app (same name) are linked rather than duplicated.
    /// The Photos library picked once, remembered with a security-scoped bookmark so the sandbox
    /// lets the app read it again without asking.
    var savedLibraryURL: URL? {
        if let keeper = Self.keeperLibrary { return keeper }
        guard let data = store.load(Data.self, from: "photosLibrary") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { rememberLibrary(url) }
        return url
    }

    private func rememberLibrary(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            store.save(data, to: "photosLibrary")
            hasSavedLibrary = true
        }
    }

    /// The library Keeper has open. Keeper already reads its database (with Full Disk Access), so
    /// there's no need to point at the library file again.
    static var keeperLibrary: URL?

    /// Whether a library has been chosen (so setup doesn't ask again).
    var hasSavedLibrary = false
    /// Contacts access hasn't been asked for yet.
    var contactsNotAsked = ContactBirthdays.notAskedYet

    var needsLibrarySetup: Bool { !hasSavedLibrary && settings.skippedLibrarySetup != true }
    var needsContactsSetup: Bool { contactsNotAsked && settings.skippedContactsSetup != true }

    func requestContactsAccess() async {
        let granted = await ContactBirthdays.requestAccess()
        contactsNotAsked = ContactBirthdays.notAskedYet
        if granted { await fillBirthdaysFromContacts(quietly: true) }
    }

    /// Set when the user goes to Photos (e.g. to name a face) so names are re-read on their return.
    @ObservationIgnored var expectingPhotosChanges = false
    @ObservationIgnored private var lastQuietRefresh = Date.distantPast

    /// Called whenever the app comes to the front.
    func appBecameActive() {
        libraryDates = [:]   // dates may have been changed in Photos meanwhile
        guard expectingPhotosChanges || Date().timeIntervalSince(lastQuietRefresh) > 15 * 60 else { return }
        let retry = expectingPhotosChanges
        expectingPhotosChanges = false
        refreshFromPhotos()
        // Photos can take a few seconds to save a new name; look once more shortly after.
        if retry {
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self.refreshFromPhotos()
            }
        }
    }

    /// Re-reads names and faces from the remembered library, quietly.
    func refreshFromPhotos() {
        guard isAuthorized, scan.lastScan != nil, let library = savedLibraryURL else { return }
        lastQuietRefresh = Date()
        importTaggedPeople(from: library, quietly: true)
    }

    /// Opens a photo in Photos and re-reads names when the user comes back. Returns a problem, if any.
    @discardableResult
    func showInPhotos(_ assetID: String) async -> String? {
        expectingPhotosChanges = true
        let problem = await ShowInPhotos.open(assetID)
        if let problem {
            expectingPhotosChanges = false
            banner = problem
        }
        return problem
    }

    /// - Parameter quietly: a background refresh: only speaks up if something changed.
    func importTaggedPeople(from libraryURL: URL, quietly: Bool = false) {
        guard !isImportingPeople else { return }
        isImportingPeople = true
        if !quietly { rememberLibrary(libraryURL) }
        let undated = Set(scan.undated.keys)
        // Faces in photos dated here too, so the age-group clues can be checked against those dates.
        // Photos dated by guessing (here or not at all) are never used as dated references.
        let notReferences = undated.union(appliedIDs)
        var faceIDs = notReferences
        // And dated photos of people with a birth year, to check the face-age model against.
        faceIDs.formUnion(faceAgeReferenceIDs())
        Task.detached(priority: .userInitiated) {
            let started = ContinuousClock.now
            let scoped = libraryURL.startAccessingSecurityScopedResource()
            defer { if scoped { libraryURL.stopAccessingSecurityScopedResource() } }
            let result = Result { try PhotosPeopleReader.read(libraryURL: libraryURL, facesFor: faceIDs, undated: notReferences) }
            let cameras = (try? PhotosPeopleReader.readCameras(libraryURL: libraryURL)) ?? [:]
            Timing.note("read people and faces from Photos", since: started)
            await MainActor.run {
                let applyStarted = ContinuousClock.now
                defer { Timing.note("applied people and faces on main", since: applyStarted) }
                self.isImportingPeople = false
                switch result {
                case .failure(let error):
                    if !quietly { self.banner = error.localizedDescription }
                case .success(let read):
                    let before = Set(self.taggedPeople.map { "\($0.id)|\($0.name)|\($0.assetIDs.count)" })
                    if !cameras.isEmpty { self.places.setCameras(cameras) }
                    // Only what changed is replaced: each replacement rewrites its file and works
                    // the estimates out again. A quiet refresh usually finds nothing new.
                    let changed = self.detectedFaces != read.faces || self.referenceCandidates != read.references
                        || self.taggedPeople != read.people
                    if self.detectedFaces != read.faces { self.detectedFaces = read.faces }
                    if self.referenceCandidates != read.references { self.referenceCandidates = read.references }
                    self.mergeTagged(read.people, undated: undated, quietly: quietly)
                    let after = Set(self.taggedPeople.map { "\($0.id)|\($0.name)|\($0.assetIDs.count)" })
                    if quietly && before != after {
                        self.banner = "Updated names from Photos."
                    }
                    Timing.note(changed ? "people or faces changed in Photos" : "nothing new in Photos")
                    // Nothing new: the links, places and face ages already reflect it.
                    if changed || !quietly { self.startFingerprinting() }
                }
            }
        }
    }

    private func mergeTagged(_ tagged: [TaggedPerson], undated: Set<String>, quietly: Bool = false) {
        var list = people
        var added = 0
        for t in tagged {
            // Dated photos with the biggest faces make the best pictures to show for each person.
            let refs = Array(t.assetIDs.filter { !undated.contains($0) }.prefix(2))
            if let i = list.firstIndex(where: { $0.photosPersonID == t.id })
                ?? list.firstIndex(where: { $0.photosPersonID == nil && PersonMatcher.normalize($0.name) == PersonMatcher.normalize(t.name) }) {
                list[i].photosPersonID = t.id
                if list[i].referenceAssetIDs.isEmpty { list[i].referenceAssetIDs = refs }
            } else {
                list.append(PersonInfo(name: t.name, birthYear: nil, referenceAssetIDs: refs, photosPersonID: t.id))
                added += 1
            }
        }
        if taggedPeople != tagged { taggedPeople = tagged }
        if people != list { people = list }
        let photos = Set(tagged.flatMap(\.assetIDs)).intersection(undated).count
        if !quietly {
            banner = "Found \(tagged.count) named people in Photos (\(added) new). They’re in \(photos.formatted()) of your undated photos."
        }
        Task { await fillBirthdaysFromContacts(quietly: quietly) }
    }

    /// The one way the UI changes a birthday: marks it as typed by hand and, if that setting is on,
    /// saves it to the linked Contacts card once typing pauses.
    func updateBirthday(_ personID: UUID, _ change: (inout PersonInfo) -> Void) {
        guard let i = people.firstIndex(where: { $0.id == personID }) else { return }
        var p = people[i]
        change(&p)
        guard p != people[i] else { return }
        p.birthdayFromContacts = nil
        people[i] = p
        guard settings.writeBirthdaysToContacts == true, contactLink(for: p) != nil, p.birthYear != nil else { return }
        contactWrites[personID]?.cancel()
        contactWrites[personID] = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await self.writeBirthdayToContact(personID)
        }
    }

    @ObservationIgnored private var contactWrites: [UUID: Task<Void, Never>] = [:]

    /// How to find this person's Contacts card, if Photos linked one.
    func contactLink(for person: PersonInfo) -> ContactBirthdays.Link? {
        guard let tag = person.photosPersonID, let tagged = taggedPeople.first(where: { $0.id == tag }) else { return nil }
        let link = ContactBirthdays.Link(tagged)
        return link.isEmpty ? nil : link
    }

    private func writeBirthdayToContact(_ personID: UUID) async {
        contactWrites[personID] = nil
        guard let p = people.first(where: { $0.id == personID }), let year = p.birthYear, let contact = contactLink(for: p) else { return }
        let result = await ContactBirthdays.save(.init(year: year, month: p.birthMonth, day: p.birthDay), to: contact)
        switch result {
        case .saved(let previous):
            banner = previous.map { $0 != year ? "Changed \(p.name)’s birth year in Contacts from \($0) to \(year)." : "Updated \(p.name)’s birthday in Contacts." }
                ?? "Saved \(p.name)’s birthday to Contacts."
        case .unchanged: break
        case .needsMonthAndDay:
            banner = "Contacts needs a month and day for a birthday. Add them for \(p.name) to save it there."
        case .notFound:
            banner = "Couldn’t find \(p.name)’s linked card in Contacts."
        case .denied:
            banner = "To save birthdays to Contacts, allow access in System Settings ▸ Privacy & Security ▸ Contacts."
        case .failed(let message):
            banner = "Couldn’t save \(p.name)’s birthday to Contacts (\(message))."
        }
    }

    /// Fills in missing birth years from the Contacts cards Photos linked people to. Never overwrites
    /// a year the user typed.
    func fillBirthdaysFromContacts(quietly: Bool = false) async {
        // A background refresh never pops up the Contacts permission prompt.
        if quietly && !ContactBirthdays.isAuthorized { return }
        let wanted = people.filter { $0.birthYear == nil || $0.birthdayFromContacts == true }.compactMap(contactLink(for:))
        guard !wanted.isEmpty else {
            if quietly { return }
            banner = taggedPeople.contains { $0.contactMatch != nil || $0.contactID != nil }
                ? "Everyone linked to a contact already has a birth year."
                : "Nobody here is linked to a contact in Photos yet. Click Update from Photos in the People tab first."
            return
        }
        let (granted, located, found) = await ContactBirthdays.birthdays(for: wanted)
        guard granted else {
            if quietly { return }
            banner = "To fill in birthdays automatically, allow Contacts access in System Settings ▸ Privacy & Security ▸ Contacts."
            return
        }
        var list = people, filled = 0
        for i in list.indices {
            guard list[i].birthYear == nil || list[i].birthdayFromContacts == true,
                  let tag = list[i].photosPersonID, let b = found[tag] else { continue }
            if list[i].birthYear != b.year || list[i].birthMonth != b.month || list[i].birthDay != b.day { filled += 1 }
            list[i].birthYear = b.year
            list[i].birthMonth = b.month
            list[i].birthDay = b.day
            list[i].birthdayFromContacts = true
        }
        if list != people { people = list }
        if quietly && filled == 0 { return }
        banner = "Found \(located) of \(wanted.count) linked cards in Contacts; \(found.count) have a birthday with a year. Filled in \(filled)."
    }

    // MARK: Events

    nonisolated static func eventKey(_ ids: [String]) -> String { ids.sorted().joined(separator: ",") }

    /// Suggestions minus photos already in an event group, and minus dismissed ones.
    func refreshEventSuggestions() {
        let inEvents = Set(groups.filter { $0.kind == .sameEvent }.flatMap(\.assetIDs))
        eventSuggestions = allEventClusters.compactMap { cluster in
            let open = cluster.filter { !inEvents.contains($0) && scan.undated[$0] != nil }
            guard open.count >= 2, !dismissedEvents.contains(Self.eventKey(cluster)) else { return nil }
            return open
        }
    }

    /// The suggested event this photo is in, if any.
    func eventSuggestion(containing id: String) -> [String]? { eventSuggestions.first { $0.contains(id) } }

    /// Photos that might also be from the event made of `ids`, for the user to confirm.
    func eventCandidates(for ids: [String]) -> [String] {
        let prints = featurePrints.filter { scan.undated[$0.key] != nil }.mapValues(EventLinks.unpack)
        var who: [String: Set<String>] = [:]
        for (asset, faces) in detectedFaces { who[asset] = Set(faces.compactMap(\.clusterID)) }
        return EventClusters.candidates(for: ids, prints: prints, people: who, limits: photoLimits)
    }

    func dismissEvent(_ ids: [String]) {
        let cluster = allEventClusters.first { !Set($0).isDisjoint(with: ids) } ?? ids
        dismissedEvents.insert(Self.eventKey(cluster))
    }

    /// Saves photos as one event with the date the user knows: they all get that one date.
    @discardableResult
    func saveEvent(_ ids: [String], name: String, year: Int?, month: Int?, season: Season?) -> PhotoGroup {
        // A year alone still gives every photo the same date: the month most of their guesses have.
        let month = year != nil && month == nil && season == nil
            ? (Dictionary(grouping: ids.compactMap { effectiveEstimate($0)?.month }, by: { $0 })
                .max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key ?? 1)
            : month
        var group = createGroup(name: name, assetIDs: ids, kind: .sameEvent)
        group.yearFrom = year
        group.yearTo = year
        if let month, let year {
            // Written as a hint so the exact month is used ("July 1987").
            group.hint = "\(DateEstimate.monthNames[month - 1]) \(year)"
        } else {
            group.season = season
        }
        if let i = groups.firstIndex(where: { $0.id == group.id }) { groups[i] = group }
        // Confirming an event checks its photos for Apply. A date the user gave is the date for every
        // photo; without one they keep the event's shared date from all their clues together.
        var copy = decisions
        for id in ids {
            var d = copy[id] ?? ReviewDecision()
            guard !d.ignored else { continue }
            if let year {
                d.overrideYear = year
                d.overrideMonth = month
                d.overrideSeason = month == nil ? season : nil
            }
            d.selected = true
            copy[id] = d
        }
        decisions = copy
        refreshEventSuggestions()
        return group
    }

    /// Undated photos in a saved event that this app hasn't dated yet (the ones a new date can change).
    func openMembers(_ group: PhotoGroup) -> [String] {
        let applied = appliedIDs
        return group.assetIDs.filter { scan.undated[$0] != nil && !applied.contains($0) }
    }

    /// Gives every photo in a confirmed event one new date and checks them for Apply. A nil year
    /// clears the date you gave, so they go back to the event's shared guess from all their clues.
    func setEventDate(_ groupID: UUID, year: Int?, month: Int?, season: Season?) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var group = groups[i]
        // A year alone still gives every photo the same date: the event's month.
        let month = year != nil && month == nil && season == nil ? (eventShownMonth(group) ?? 1) : month
        // The hint holds the month ("July 1987") only when the app wrote it; keep the user's own notes.
        let autoHint = group.hint.isEmpty || DateEstimate.monthNames.contains { group.hint.hasPrefix($0 + " ") }
        group.yearFrom = year
        group.yearTo = year
        group.season = month == nil ? season : nil
        if autoHint { group.hint = month.flatMap { m in year.map { "\(DateEstimate.monthNames[m - 1]) \($0)" } } ?? "" }
        groups[i] = group
        var copy = decisions
        for id in openMembers(group) {
            var d = copy[id] ?? ReviewDecision()
            guard !d.ignored else { continue }
            d.overrideYear = year
            d.overrideMonth = year == nil ? nil : month
            d.overrideSeason = year == nil || month != nil ? nil : season
            d.selected = true
            copy[id] = d
        }
        decisions = copy
    }

    // MARK: Cameras

    /// Cameras that took undated photos (scanners left out), most photos first.
    var undatedCameras: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for p in scan.undated.values { if let c = CameraClues.camera(of: p.format) { counts[c, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    func setCameraYears(_ camera: String, from: Int?, to: Int?) {
        var list = cameraPeriods.filter { $0.id != camera }
        if from != nil || to != nil { list.append(CameraPeriod(id: camera, fromYear: from, toYear: to)) }
        cameraPeriods = list
    }

    // MARK: Groups

    @discardableResult
    func createGroup(name: String, assetIDs: [String], kind: GroupKind = .sameEra) -> PhotoGroup {
        let ids = Set(assetIDs)
        // A photo belongs to one group at a time.
        // Changed on a copy, then saved once.
        var copy = groups
        for i in copy.indices { copy[i].assetIDs.removeAll { ids.contains($0) } }
        let group = PhotoGroup(name: name, kind: kind, assetIDs: assetIDs)
        copy.append(group)
        groups = copy
        return group
    }

    func add(_ assetIDs: [String], to groupID: UUID) {
        let ids = Set(assetIDs)
        var copy = groups
        for i in copy.indices where copy[i].id != groupID { copy[i].assetIDs.removeAll { ids.contains($0) } }
        guard let idx = copy.firstIndex(where: { $0.id == groupID }) else { return }
        let existing = Set(copy[idx].assetIDs)
        copy[idx].assetIDs += assetIDs.filter { !existing.contains($0) }
        groups = copy
    }

    func remove(_ assetIDs: [String], from groupID: UUID) {
        let ids = Set(assetIDs)
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].assetIDs.removeAll { ids.contains($0) }
    }

    func groupSuggestions() -> [GroupSuggestion] {
        let alreadyGrouped = Set(groups.flatMap(\.assetIDs))
        let candidates = undatedSorted.filter { !alreadyGrouped.contains($0.id) }.map {
            GroupCandidate(assetID: $0.id, filename: $0.format.originalFilename, libraryDate: $0.libraryDate, albums: $0.albums)
        }
        return GroupSuggester.suggest(candidates)
    }

    // MARK: Saving

    private func scheduleAnalysesSave() {
        guard analysesSaveTask == nil else { return }
        analysesSaveTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            // Cancelled when saved sooner: a cancelled sleep ends at once, and this would save again.
            guard !Task.isCancelled else { return }
            self.saveAnalysesNow()
        }
    }

    func saveAnalysesNow() {
        analysesSaveTask?.cancel()
        analysesSaveTask = nil
        store.save(analyses, to: "analyses")
    }

    private func scheduleDecisionSave() {
        decisionsSaveTask?.cancel()
        decisionsSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.store.save(self.decisions, to: "decisions")
        }
    }

    func saveEverything() {
        store.save(analyses, to: "analyses")
        store.save(decisions, to: "decisions")
        places.saveNow()
        store.save(faceAges, to: "faceAges")
        store.flush()
    }
}
