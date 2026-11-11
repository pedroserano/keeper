import XCTest
import DateGuessCore
import KeeperCore
@testable import DateGuesser

/// Dates whole events with their own dates hidden, the way the app pools their photos' clues.
///
/// Measured on one library (118 events you dated yourself, 2,220 photos): within 1 year 74%,
/// 2 years 87%, 5 years 95%. Counting each kind of clue once per event (as for independent
/// witnesses), leaving out scene or album clues, or taking the middle single-photo guess did no
/// better, so the app keeps its pooling.
/// Skipped unless PDG_BACKTEST_DIR points at a Dates data folder (read only). Prints totals only.
@MainActor
final class EventBacktest: XCTestCase {
    func testEventBacktestOnRealData() throws {
        guard let dir = ProcessInfo.processInfo.environment["PDG_BACKTEST_DIR"] else { throw XCTSkip("no PDG_BACKTEST_DIR") }
        let store = JSONStore(directory: URL(fileURLWithPath: dir, isDirectory: true))
        let analyses = try XCTUnwrap(store.load([String: PhotoAnalysis].self, from: "analyses"))
        let journal = store.load([ApplyBatch].self, from: "journal") ?? []
        let decisions = store.load([String: ReviewDecision].self, from: "decisions") ?? [:]
        let groups = store.load([PhotoGroup].self, from: "groups") ?? []
        let scan = store.load(ScanSnapshot.self, from: "scan") ?? ScanSnapshot()
        let prints = store.loadBinary([String: Data].self, from: "featurePrints") ?? [:]
        let references = store.load([String: ReferenceCandidate].self, from: "referenceCandidates") ?? [:]
        let people = store.load([PersonInfo].self, from: "people") ?? []
        let faces = store.load([String: [DetectedFace]].self, from: "detectedFaces") ?? [:]
        let tagged = store.load([TaggedPerson].self, from: "taggedPeople") ?? []
        let faceAges = store.load([String: [String: Double]].self, from: "faceAges") ?? [:]
        let earliest = store.load(AppSettings.self, from: "settings")?.earliestYear

        // Who's in each photo, as the app works it out.
        var clusterPerson: [String: UUID] = [:]
        for p in people { if let c = p.photosPersonID { clusterPerson[c] = p.id } }
        var hints: [String: [GroupPersonHint]] = [:]
        for (asset, list) in faces {
            for f in list { if let c = f.clusterID, let id = clusterPerson[c] { hints[asset, default: []].append(GroupPersonHint(personID: id, fromPhotos: true, faceAgeType: f.ageType)) } }
        }
        for t in tagged {
            guard let id = clusterPerson[t.id] else { continue }
            for a in t.assetIDs where faces[a] == nil { hints[a, default: []].append(GroupPersonHint(personID: id, fromPhotos: true)) }
        }
        let born = Set(people.filter { $0.birthYear != nil }.map(\.id))
        var readings: [String: [FaceAgeClues.Reading]] = [:]
        for (asset, ages) in faceAges {
            for (cluster, age) in ages where age >= 0 {
                if let id = clusterPerson[cluster], born.contains(id) { readings[asset, default: []].append(.init(personID: id, age: age)) }
            }
        }

        // Known event dates you gave yourself (never Keeper's accepted guesses).
        var events: [(ids: [String], year: Int)] = []
        var used = Set<String>()
        for g in groups where g.kind == .sameEvent {
            guard let y = g.yearFrom, g.yearTo == y else { continue }
            let ids = g.assetIDs.filter { analyses[$0] != nil }
            if ids.count >= 2 { events.append((ids, y)); used.formUnion(ids) }
        }
        let fromGroups = events.count
        for (b, batch) in journal.enumerated() {
            var sets: [String: [String]] = [:]
            for e in batch.liveEntries where analyses[e.assetID] != nil && !used.contains(e.assetID) {
                guard let d = decisions[e.assetID], let y = d.overrideYear else { continue }
                sets["\(b)|\(y)|\(d.overrideMonth ?? 0)|\(d.overrideSeason?.rawValue ?? "")", default: []].append(e.assetID)
            }
            for (key, ids) in sets where ids.count >= 2 {
                events.append((ids, Int(key.split(separator: "|")[1])!)); used.formUnion(ids)
            }
        }
        // How often album-name years are right, on photos whose year you typed yourself.
        var albumTruth: [String: Int] = [:]
        for (ids, year) in events { for id in ids { albumTruth[id] = year } }
        var albumStats: [String: (n: Int, inside: Int, near: Int)] = [:]
        var albumPhotos = 0
        for (id, year) in albumTruth {
            let clues = analyses[id]!.evidence.filter { $0.source == .album && $0.hasYearInfo && !$0.isHardConstraint }
            if !clues.isEmpty { albumPhotos += 1 }
            for e in clues {
                let lo = e.yearLow ?? 0, hi = e.yearHigh ?? 9999
                // The album's name, from the clue's text (only its shape is reported).
                let name = e.summary.components(separatedBy: "“").last?.components(separatedBy: "”").first ?? ""
                let bare = name.trimmingCharacters(in: .whitespaces).range(of: #"^(18|19|20)[0-9]{2}$"#, options: .regularExpression) != nil
                let several = clues.count > 1 ? ", photo in several year albums" : ", photo in one year album"
                let kind = (lo == hi ? (bare ? "named only a year" : "year in a longer name") : "a range") + several
                var s = albumStats[kind] ?? (0, 0, 0)
                s.n += 1
                if year >= lo && year <= hi { s.inside += 1 }
                if year >= lo - 1 && year <= hi + 1 { s.near += 1 }
                albumStats[kind] = s
            }
        }
        print("ALBUM YEARS on \(albumPhotos) of \(albumTruth.count) photos with a year you typed:")
        for (k, s) in albumStats.sorted(by: { $0.key < $1.key }) {
            print("  \(k): \(s.n) clues; right \(100 * s.inside / max(1, s.n))%, within a year \(100 * s.near / max(1, s.n))%")
        }
        print("EVENT BACKTEST: \(events.count) events (\(fromGroups) confirmed with your year, \(events.count - fromGroups) set together and applied), \(events.reduce(0) { $0 + $1.ids.count }) photos")
        guard !events.isEmpty else { return }

        // Photos with a known date, to learn the clue calibration and the year probe from.
        var known: [String: (year: Int, month: Int)] = [:]
        for batch in journal {
            for e in batch.liveEntries where known[e.assetID] == nil && analyses[e.assetID] != nil {
                let c = Calendar.current.dateComponents([.year, .month], from: e.newDate)
                known[e.assetID] = (c.year!, c.month!)
            }
        }
        // Year albums judged by their own dated photos, as the app does (needs KEEPER_LIBRARY).
        let yearAlbums: [String: YearAlbum] = ProcessInfo.processInfo.environment["KEEPER_LIBRARY"].flatMap {
            try? PhotosDatabase.readYearAlbums(inLibrary: URL(fileURLWithPath: $0), yearInTitle: AlbumYears.year(inTitle:))
        }?.mapValues { YearAlbum(year: $0.year, dated: $0.dated, sameYear: $0.sameYear, withinYear: $0.withinYear) } ?? [:]
        let options = EvidenceFusion.Options(allowExactMonth: true)
        let limits = earliest.map { [ProvenanceClues.earliestYear($0)] } ?? []
        func clues(_ id: String) -> [DateEvidence] {
            var e = analyses[id]!.evidence + limits
            if let f = scan.undated[id]?.format { e = DigitalPhotoClues.apply(to: e, format: f) }
            return e
        }
        func peopleClues(_ id: String) -> [DateEvidence] { GroupClues.peopleEvidence(hints[id] ?? [], people: people) }
        let referenceExamples = references.compactMap { id, c in prints[id].map { YearProbe.Example(id: id, year: c.year, print: EventLinks.unpack($0)) } }

        let arms = ["without look-alikes", "as the app does it", "single photos (middle guess)", "with year albums judged"]
        var errors: [String: [Int]] = [:]
        var pulls: [String: [EvidenceSource: Int]] = [:]
        for fold in 0..<5 {
            let test = events.enumerated().filter { $0.offset % 5 == fold }.map(\.element)
            guard !test.isEmpty else { continue }
            let held = Set(test.flatMap(\.ids))
            let train = known.filter { !held.contains($0.key) }
            let calibration = ClueCalibration.build(train.map { id, t in
                var e = clues(id) + peopleClues(id)
                if let r = readings[id], let f = FaceAgeClues.evidence(r, people: people) { e.append(f) }
                return .init(evidence: e, year: t.year, month: t.month)
            })
            let probe = YearProbe(referenceExamples.filter { !held.contains($0.id) }
                                  + train.compactMap { id, t in prints[id].map { .init(id: id, year: t.year, print: EventLinks.unpack($0)) } })
            var queries: [String: [Float]] = [:]
            for id in held { if let p = prints[id] { queries[id] = EventLinks.unpack(p) } }
            let probeClues = probe.evidence(for: queries, maxWeight: AppState.lookalikeWeight)

            for event in test {
                func own(_ id: String, probe withProbe: Bool) -> [DateEvidence] {
                    var e = (clues(id) + peopleClues(id)).map(calibration.adjusted)
                    if withProbe, let p = probeClues[id] { e.append(p) }
                    return e
                }
                func face(_ id: String) -> [DateEvidence] {
                    readings[id].flatMap { FaceAgeClues.evidence($0, people: people) }.map { [calibration.adjusted($0)] } ?? []
                }
                var estimates: [DateEstimate] = []
                for withProbe in [false, true] {
                    let members = event.ids.map { GroupFusion.Member(assetID: $0, evidence: own($0, probe: withProbe) + face($0)) }
                    estimates.append(GroupFusion.estimates(members: members, groupEvidence: [], kind: .sameEvent, options: options)[event.ids[0]]!)
                }
                let singles = event.ids.map { EvidenceFusion.estimate(from: own($0, probe: true) + face($0), options: options).year }.sorted()
                var middle = estimates[0]; middle.year = singles[singles.count / 2]
                estimates.append(middle)
                let judged = event.ids.map { id in
                    GroupFusion.Member(assetID: id, evidence: (own(id, probe: true) + face(id)).map { AlbumYears.adjust($0, albums: yearAlbums) })
                }
                estimates.append(GroupFusion.estimates(members: judged, groupEvidence: [], kind: .sameEvent, options: options)[event.ids[0]]!)
                for (arm, est) in zip(arms, estimates) {
                    let off = est.year - event.year
                    errors[arm, default: []].append(off)
                    // On a miss, which kinds of clue pointed far from the real year.
                    if abs(off) > 5 {
                        for id in event.ids {
                            for e in own(id, probe: true) + face(id) where !e.isHardConstraint && e.hasYearInfo {
                                if let p = e.peakYear ?? e.yearLow, abs(p - event.year) > 5 { pulls[arm, default: [:]][e.source, default: 0] += 1 }
                            }
                        }
                    }
                }
            }
        }
        // The suggested events waiting now: how many of their photos have a dated look-alike to go on.
        let clusters = store.load([[String]].self, from: "eventClusters") ?? []
        let confirmedIDs = Set(groups.filter { $0.kind == .sameEvent }.flatMap(\.assetIDs))
        let open = clusters.map { $0.filter { scan.undated[$0] != nil && !confirmedIDs.contains($0) } }.filter { $0.count >= 2 }
        let allProbe = YearProbe(referenceExamples + known.compactMap { id, t in prints[id].map { .init(id: id, year: t.year, print: EventLinks.unpack($0)) } })
        var q: [String: [Float]] = [:]
        for ids in open { for id in ids { if let p = prints[id] { q[id] = EventLinks.unpack(p) } } }
        let found = allProbe.evidence(for: q, maxWeight: AppState.lookalikeWeight)
        let withPrint = open.flatMap { $0 }.filter { prints[$0] != nil }.count
        let eventsWith = open.filter { $0.contains { found[$0] != nil } }.count
        print("  suggested events now: \(open.count) with \(open.reduce(0) { $0 + $1.count }) photos; fingerprinted \(withPrint); photos with a look-alike clue \(found.count); events with at least one \(eventsWith) (\(100 * eventsWith / max(1, open.count))%)")
        print("  dated look-alike pool: \(referenceExamples.count) reference photos + \(known.filter { prints[$0.key] != nil }.count) photos you dated")
        for arm in arms {
            let e = errors[arm] ?? []
            let abs = e.map { Swift.abs($0) }.sorted()
            func pct(_ x: Int) -> String { "\(100 * x / max(1, e.count))%" }
            let median = abs.isEmpty ? 0 : abs[abs.count / 2]
            let wrong = (pulls[arm] ?? [:]).sorted { $0.value > $1.value }.prefix(4).map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
            print("  \(arm): median \(median) yr off; within 1 yr \(pct(abs.filter { $0 <= 1 }.count)), 2 yr \(pct(abs.filter { $0 <= 2 }.count)), 5 yr \(pct(abs.filter { $0 <= 5 }.count)); too early \(e.filter { $0 < 0 }.count), too late \(e.filter { $0 > 0 }.count); clues far off in misses: \(wrong)")
        }
    }
}
