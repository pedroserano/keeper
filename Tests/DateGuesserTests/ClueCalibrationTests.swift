import XCTest
import DateGuessCore
@testable import DateGuesser

final class ClueCalibrationTests: XCTestCase {
    let bw = DateEvidence(source: .colorTone, summary: "Black & white", yearLow: 1890, yearHigh: 1968, peakYear: 1948, weight: 0.4)
    let snow = DateEvidence(source: .scene, summary: "Scene shows snow (winter)", season: .winter, seasonWeight: 0.5)
    let album = DateEvidence(source: .album, summary: "Album contains the year 2003", yearLow: 2003, yearHigh: 2003, weight: 0.9)

    func photos(_ e: DateEvidence, right: Int, wrong: Int, rightYear: Int = 1950, wrongYear: Int = 2003,
                rightMonth: Int = 1, wrongMonth: Int = 7) -> [ClueCalibration.Confirmed] {
        Array(repeating: .init(evidence: [e], year: rightYear, month: rightMonth), count: right)
            + Array(repeating: .init(evidence: [e], year: wrongYear, month: wrongMonth), count: wrong)
    }

    func testAlwaysWrongClueIsLeftOut() {
        let c = ClueCalibration.build(photos(bw, right: 0, wrong: 140))
        let out = c.adjusted(bw)
        XCTAssertEqual(out.weight, 0)
        XCTAssertTrue(out.summary.contains("usually wrong in your library"), out.summary)
    }

    func testReliableClueIsNeverCountedMore() {
        let c = ClueCalibration.build(photos(bw, right: 100, wrong: 0))
        XCTAssertEqual(c.adjusted(bw), bw)
    }

    func testFewPhotosBarelyChangeAClue() {
        let c = ClueCalibration.build(photos(bw, right: 0, wrong: 3))
        let out = c.adjusted(bw)
        XCTAssertGreaterThan(out.weight, 0.2)
        XCTAssertLessThan(out.weight, bw.weight)
    }

    func testSometimesRightSeasonClueCountsLess() {
        let c = ClueCalibration.build(photos(snow, right: 17, wrong: 128))
        let out = c.adjusted(snow)
        XCTAssertLessThan(out.seasonWeight, snow.seasonWeight * 0.4)
        XCTAssertGreaterThan(out.seasonWeight, 0)
        XCTAssertTrue(out.summary.contains("right 17 of 145"), out.summary)
    }

    func testOwnLibraryAndHardCluesAreUntouched() {
        let heic = DateEvidence(source: .fileFormat, summary: "HEIC", yearLow: 2017, weight: 1, isHardConstraint: true)
        let c = ClueCalibration.build(photos(album, right: 0, wrong: 100, wrongYear: 1990)
                                      + photos(heic, right: 0, wrong: 100, wrongYear: 1990))
        XCTAssertEqual(c.adjusted(album), album)
        XCTAssertEqual(c.adjusted(heic), heic)
    }

    func testNoteDoesNotChangeWhichClueItIs() {
        let c = ClueCalibration.build(photos(snow, right: 17, wrong: 128))
        XCTAssertEqual(ClueCalibration.key(c.adjusted(snow)), ClueCalibration.key(snow))
    }

    // MARK: Digital photos

    func testDigitalCameraSizeLosesFilmClues() {
        let format = FormatInfo(originalFilename: "No-album - 16687.jpg", pixelWidth: 1024, pixelHeight: 768)
        XCTAssertTrue(DigitalPhotoClues.looksDigital(format))
        let out = DigitalPhotoClues.apply(to: [bw], format: format)
        XCTAssertEqual(out.first?.weight, 0)
        XCTAssertEqual(out.count, 1)
    }

    func testCameraFilenameLooksDigital() {
        XCTAssertTrue(DigitalPhotoClues.looksDigital(FormatInfo(originalFilename: "DSC_0042.JPG", pixelWidth: 3000, pixelHeight: 2000)))
        XCTAssertFalse(DigitalPhotoClues.looksDigital(FormatInfo(originalFilename: "Scan-210512-0001.jpg", pixelWidth: 3000, pixelHeight: 2250)))
    }

    func testScanWithPrintBorderKeepsFilmClues() {
        let border = DateEvidence(source: .borderPaper, summary: "White print border", yearLow: 1940, yearHigh: 1992, weight: 0.2)
        let format = FormatInfo(pixelWidth: 1024, pixelHeight: 768)
        XCTAssertEqual(DigitalPhotoClues.apply(to: [bw, border], format: format), [bw, border])
    }

    func testScanSizedPhotoKeepsFilmClues() {
        let format = FormatInfo(originalFilename: "Grandpa.jpg", pixelWidth: 2400, pixelHeight: 1630)
        XCTAssertEqual(DigitalPhotoClues.apply(to: [bw], format: format), [bw])
    }

    // MARK: Look-alikes

    func testLookalikesTakeTheYearOfTheClosestDatedPhotos() {
        var rng = SystemRandomNumberGenerator()
        func around(_ center: [Float]) -> [Float] { center.map { $0 + Float.random(in: -0.05...0.05, using: &rng) } }
        let a: [Float] = [1, 0, 0, 0], b: [Float] = [0, 0, 1, 0]
        let examples = (0..<40).map { YearProbe.Example(id: "a\($0)", year: 1988, print: around(a)) }
            + (0..<40).map { YearProbe.Example(id: "b\($0)", year: 2004, print: around(b)) }
        let probe = YearProbe(examples)
        let out = probe.evidence(for: ["x": around(b), "a3": examples[3].print])
        XCTAssertEqual(out["x"]?.peakYear, 2004)
        XCTAssertEqual(out["x"]?.yearRangeText, "2004")
        // A dated photo isn't its own look-alike.
        XCTAssertEqual(out["a3"]?.peakYear, 1988)
        XCTAssertTrue(probe.evidence(for: ["x": around(b)], maxWeight: 0.4)["x"]!.weight <= 0.4)
    }

    func testLookalikesNeedEnoughDatedPhotosAndAgreement() {
        let few = YearProbe((0..<10).map { YearProbe.Example(id: "\($0)", year: 2000, print: [1, 0]) })
        XCTAssertTrue(few.evidence(for: ["x": [1, 0]]).isEmpty)
        // Identical-looking photos from all over the place: no agreement, no clue.
        let mixed = YearProbe((0..<60).map { YearProbe.Example(id: "\($0)", year: 1960 + $0, print: [1, 0]) })
        XCTAssertNil(mixed.evidence(for: ["x": [1, 0]])["x"])
    }

    // MARK: Backtest on a copy of real data (skipped unless PDG_BACKTEST_DIR is set)

    /// Hides each dated photo's own date (5 folds), calibrates on the rest, and compares guesses.
    func testBacktestOnRealData() throws {
        guard let dir = ProcessInfo.processInfo.environment["PDG_BACKTEST_DIR"] else { throw XCTSkip("no PDG_BACKTEST_DIR") }
        let previous = ProcessInfo.processInfo.environment["PDG_DATA_DIR"]
        setenv("PDG_DATA_DIR", dir, 1)
        let store = JSONStore()
        if let previous { setenv("PDG_DATA_DIR", previous, 1) }
        let analyses = try XCTUnwrap(store.load([String: PhotoAnalysis].self, from: "analyses"))
        let journal = try XCTUnwrap(store.load([ApplyBatch].self, from: "journal"))
        let decisions = store.load([String: ReviewDecision].self, from: "decisions") ?? [:]
        var formats: [String: FormatInfo] = [:]
        let tsv = try String(contentsOfFile: dir + "/sizes.tsv", encoding: .utf8)
        for line in tsv.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, let w = Int(f[1]), let h = Int(f[2]) else { continue }
            formats[f[0]] = FormatInfo(originalFilename: f[3], pixelWidth: w, pixelHeight: h)
        }

        let prints = store.loadBinary([String: Data].self, from: "featurePrints") ?? [:]
        let references = store.load([String: ReferenceCandidate].self, from: "referenceCandidates") ?? [:]
        // Who's in each photo, the way the app works it out: Photos' face groups linked to people.
        let people = store.load([PersonInfo].self, from: "people") ?? []
        let faces = store.load([String: [DetectedFace]].self, from: "detectedFaces") ?? [:]
        let tagged = store.load([TaggedPerson].self, from: "taggedPeople") ?? []
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
        func peopleClues(_ id: String) -> [DateEvidence] { GroupClues.peopleEvidence(hints[id] ?? [], people: people) }
        // The face-age model's readings, and its correction learned from faces in trusted-date photos.
        let faceAges = store.load([String: [String: Double]].self, from: "faceAges") ?? [:]
        let bornPeople = Dictionary(people.filter { $0.birthYear != nil }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var readings: [String: [FaceAgeClues.Reading]] = [:]
        var pairs: [(read: Double, real: Double)] = []
        for (asset, ages) in faceAges {
            for (cluster, age) in ages where age >= 0 {
                guard let id = clusterPerson[cluster], let person = bornPeople[id] else { continue }
                readings[asset, default: []].append(.init(personID: id, age: age))
                if let c = references[asset] {
                    let real = Double(c.year) + (Double(c.month) - 0.5) / 12 - (Double(person.birthYear!) + (Double(person.birthMonth ?? 7) - 0.5) / 12)
                    if real >= 0 { pairs.append((age, real)) }
                }
            }
        }
        let correction = FaceAgeClues.Correction.learn(pairs)
        print("FACE CORRECTION from \(pairs.count) faces:", correction.brackets.map { "<\($0.below): bias \(String(format: "%.1f", $0.bias)) spread \(String(format: "%.1f", $0.spread)) n=\($0.checked)" })
        var withFaceModel = 0
        func faceModelClues(_ id: String) -> [DateEvidence] {
            var clues = peopleClues(id)
            if let r = readings[id], let e = FaceAgeClues.evidence(r, people: people, correction: correction) {
                clues.removeAll { $0.calibrationKey?.hasPrefix("person:faceAge:") == true }
                clues.append(e)
            }
            return clues
        }

        // Folds by Apply click, so photos dated together (often one event) never train each other.
        var seen = Set<String>()
        var truth: [(id: String, year: Int, month: Int, fold: Int)] = []
        for (index, batch) in journal.enumerated() {
            for e in batch.liveEntries where seen.insert(e.assetID).inserted && analyses[e.assetID] != nil {
                let c = Calendar.current.dateComponents([.year, .month], from: e.newDate)
                truth.append((e.assetID, c.year!, c.month!, index % 5))
            }
        }
        let options = EvidenceFusion.Options(allowExactMonth: true)
        // The same limits the app adds (the earliest year the user set in Settings).
        let limits = (store.load(AppSettings.self, from: "settings")?.earliestYear).map { [ProvenanceClues.earliestYear($0)] } ?? []
        func raw(_ id: String) -> [DateEvidence] { analyses[id]!.evidence + limits }
        func clues(_ id: String) -> [DateEvidence] {
            let e = raw(id)
            return formats[id].map { DigitalPhotoClues.apply(to: e, format: $0) } ?? e
        }
        struct Score { var n = 0, year = 0, near = 0, season = 0, off = 0, far = 0 }
        func add(_ s: inout Score, _ est: DateEstimate, _ t: (id: String, year: Int, month: Int, fold: Int)) {
            s.n += 1
            if est.year == t.year { s.year += 1 }
            if abs(est.year - t.year) <= 1 { s.near += 1 }
            if est.season == Season.from(month: t.month) { s.season += 1 }
            s.off += abs(est.year - t.year)
            if abs(est.year - t.year) > 10 { s.far += 1 }
        }
        let probeWeights: [Double] = [AppState.lookalikeWeight]
        var withLookalike = 0, onlyLimits = 0
        let arms = ["before", "now"] + probeWeights.map { "look-alikes \($0)" } + ["people", "people calibrated", "face model"]
        var withPeople = 0
        var all: [String: Score] = [:], own: [String: Score] = [:]
        let referenceExamples = references.compactMap { id, c in
            prints[id].map { YearProbe.Example(id: id, year: c.year, print: EventLinks.unpack($0)) }
        }
        for fold in 0..<5 {
            let train = truth.filter { $0.fold != fold }, test = truth.filter { $0.fold == fold }
            guard !test.isEmpty else { continue }
            let calibration = ClueCalibration.build(train.map { .init(evidence: clues($0.id) + faceModelClues($0.id), year: $0.year, month: $0.month) })
            let testIDs = Set(test.map(\.id))
            let probe = YearProbe(referenceExamples.filter { !testIDs.contains($0.id) }
                                  + train.compactMap { t in prints[t.id].map { .init(id: t.id, year: t.year, print: EventLinks.unpack($0)) } })
            var queries: [String: [Float]] = [:]
            for t in test { if let p = prints[t.id] { queries[t.id] = EventLinks.unpack(p) } }
            let probeClues = probeWeights.map { probe.evidence(for: queries, maxWeight: $0) }
            for t in test {
                let now = clues(t.id).map(calibration.adjusted)
                var estimates = [EvidenceFusion.estimate(from: raw(t.id), options: options),
                                 EvidenceFusion.estimate(from: now, options: options)]
                if probeClues[0][t.id] != nil { withLookalike += 1 }
                for c in probeClues { estimates.append(EvidenceFusion.estimate(from: now + (c[t.id].map { [$0] } ?? []), options: options)) }
                let base = now + (probeClues[0][t.id].map { [$0] } ?? [])
                let who = peopleClues(t.id)
                if !who.isEmpty { withPeople += 1 }
                estimates.append(EvidenceFusion.estimate(from: base + who, options: options))
                estimates.append(EvidenceFusion.estimate(from: base + who.map(calibration.adjusted), options: options))
                if readings[t.id] != nil { withFaceModel += 1 }
                estimates.append(EvidenceFusion.estimate(from: base + faceModelClues(t.id).map(calibration.adjusted), options: options))
                if estimates.last!.onlyLimits || !estimates.last!.hasAnyEvidence { onlyLimits += 1 }
                for (arm, est) in zip(arms, estimates) {
                    add(&all[arm, default: Score()], est, t)
                    if decisions[t.id]?.overrideYear != nil { add(&own[arm, default: Score()], est, t) }
                }
            }
        }
        func line(_ name: String, _ s: Score) -> String {
            func pct(_ x: Int) -> String { s.n == 0 ? "-" : "\(100 * x / s.n)%" }
            return "\(name): n=\(s.n) right year \(pct(s.year)), within ±1 \(pct(s.near)), right season \(pct(s.season)), off by \(s.n == 0 ? 0 : Double(s.off) / Double(s.n)) yr on average, >10 yr off \(pct(s.far))"
        }
        let report = (arms.map { line($0, all[$0] ?? Score()) } + arms.map { line($0 + " (year you typed)", own[$0] ?? Score()) })
            .joined(separator: "\n")
            + "\nlook-alike clue on \(withLookalike) of \(truth.count); people clues on \(withPeople); face model on \(withFaceModel); still no real clue: \(onlyLimits)"
        print("BACKTEST\n" + report)
        try report.write(toFile: dir + "/backtest.txt", atomically: true, encoding: .utf8)
    }
}

/// People clues: face age groups are checked per age group, pooled across people; the birth-year limit isn't.
final class PeopleCalibrationTests: XCTestCase {
    func testBabyCluesThatAreUsuallyWrongCountLess() {
        let people = (0..<25).map { PersonInfo(name: "Kid \($0)", birthYear: 1980 + $0 % 10) }
        // Every "baby" clue was wrong: the photos are from 15 years after each birth.
        let confirmed = people.map { p in
            ClueCalibration.Confirmed(evidence: [PeopleClues.faceAgeGroup(of: p, type: 1)!, PeopleClues.presence(of: p)!],
                                      year: p.birthYear! + 15, month: 6)
        }
        let calibration = ClueCalibration.build(confirmed)
        XCTAssertEqual(calibration.year.keys.sorted(), ["person:faceAge:1"], "pooled, and the birth-year limit isn't calibrated")
        let someoneElse = PersonInfo(name: "New", birthYear: 2000)
        let adjusted = calibration.adjusted(PeopleClues.faceAgeGroup(of: someoneElse, type: 1)!)
        XCTAssertLessThan(adjusted.weight, 0.25, "from 0.75")
        let limit = calibration.adjusted(PeopleClues.presence(of: someoneElse)!)
        XCTAssertTrue(limit.isHardConstraint)
        XCTAssertEqual(limit.yearLow, 2000)
    }

    func testVagueAgeGroupsAreLeftOut() {
        let p = PersonInfo(name: "P", birthYear: 1984)
        XCTAssertNil(PeopleClues.faceAgeGroup(of: p, type: 3))
        XCTAssertNil(PeopleClues.faceAgeGroup(of: p, type: 5))
    }

    func testBirthYearsHelpCountsEachPhotoOnce() {
        let a = PersonInfo(name: "A", birthYear: 1980), b = PersonInfo(name: "B", birthYear: nil), c = PersonInfo(name: "C", birthYear: nil)
        let byPerson: [UUID: Set<String>] = [a.id: ["1", "2"], b.id: ["2", "3", "4"], c.id: ["4"]]
        let helped = PeopleView.helped(people: [a, b, c], undatedByPerson: byPerson, top: 1)
        XCTAssertEqual(helped.now, 2)
        XCTAssertEqual(helped.more, 2, "photo 2 is already helped")
        XCTAssertEqual(helped.top, 1)
    }
}
