import XCTest
import DateGuessCore
@testable import DateGuesser

/// Guessing and choosing places for photos without a location.
@MainActor
final class PlacesTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        setenv("PDG_DATA_DIR", NSTemporaryDirectory() + "PhotoDateGuesserTests-\(UUID().uuidString)", 1)
    }

    let t0 = Date(timeIntervalSince1970: 1_300_000_000)
    let dc = GeoPoint(lat: 38.8977, lon: -77.0365)
    let paris = GeoPoint(lat: 48.8566, lon: 2.3522)

    private func sampleScan() -> PlacesScan {
        var scan = PlacesScan(lastScan: Date())
        scan.located.append("phone", t0, dc)
        scan.missing["camera"] = .some(t0.addingTimeInterval(300))
        scan.missing["scan"] = .some(t0.addingTimeInterval(60))
        scan.missing["later"] = .some(t0.addingTimeInterval(30 * 86400 + 120))
        scan.missing["nodate"] = .some(nil)
        return scan
    }

    func testSameTimeGuessAndPlacedReferences() {
        let placed = ["placedOne": PlaceJournalEntry(assetID: "placedOne", previous: nil, new: paris, name: "Paris")]
        var scan = sampleScan()
        scan.missing["placedOne"] = .some(t0.addingTimeInterval(30 * 86400))
        let guesses = PlacesState.guesses(ids: ["camera", "scan", "later", "nodate"], scan: scan, placed: placed,
                                          untrusted: ["scan"], prints: [:], links: [:])
        let camera = guesses["camera"]!
        XCTAssertLessThan(camera.estimate.point.distanceKm(to: dc), 0.1)
        XCTAssertEqual(camera.level, .high)
        XCTAssertEqual(camera.evidence.first?.summary, "5 minutes after a photo with a location")
        XCTAssertNil(guesses["scan"], "a scan's date isn't its real time")
        XCTAssertNil(guesses["nodate"])
        XCTAssertLessThan(guesses["later"]!.estimate.point.distanceKm(to: paris), 0.1, "photos placed here teach too")
        XCTAssertEqual(guesses["later"]!.evidence.first?.source, .placedHere)
    }

    func testChoosingPlaces() {
        let places = PlacesState()
        places.scan = sampleScan()
        places.refreshOrder()
        XCTAssertEqual(places.order.first, "scan", "oldest first")
        let choice = PlaceChoice(name: "Paris", point: paris)
        places.setIgnored("later", true)
        places.setPlace(["camera", "scan", "later"], choice)
        XCTAssertEqual(places.decision("camera").override, choice)
        XCTAssertTrue(places.decision("scan").selected)
        XCTAssertNil(places.decision("later").override, "hidden photos are left alone")
        XCTAssertEqual(Set(places.checkedForApply), ["camera", "scan"])
        places.setOverride("scan", nil)
        XCTAssertEqual(places.checkedForApply, ["camera"], "nothing to write without a guess or a place")

        // Once applied, a photo leaves the list; undoing brings it back.
        places.journal = [PlaceBatch(date: Date(), entries: [PlaceJournalEntry(assetID: "camera", previous: nil, new: paris)])]
        places.refreshOrder()
        XCTAssertFalse(places.order.contains("camera"))
        places.journal[0].undone = true
        places.refreshOrder()
        XCTAssertTrue(places.order.contains("camera"))
    }

    func testFingerprintQueueSpreadsOverPlaces() {
        let places = PlacesState()
        var scan = PlacesScan(lastScan: Date())
        for i in 0..<50 { scan.located.append("home\(i)", t0.addingTimeInterval(Double(i)), dc) }
        scan.located.append("away", t0, paris)
        places.scan = scan
        let queue = places.fingerprintQueue(have: [:])
        XCTAssertTrue(queue.prefix(2).contains("away"), "a place with few photos isn't crowded out")
    }
}

/// Hides the location of every other located photo from each non-phone camera, guesses it from the
/// rest (with and without learning each camera's clock), and prints how far off the guesses are.
/// Needs an export: id, unix time, lat, lon, camera (tab-separated).
@MainActor
final class PlacesBacktest: XCTestCase {
    func testBacktestOnRealData() throws {
        guard let path = ProcessInfo.processInfo.environment["PDG_PLACES_TSV"] else { throw XCTSkip("no export") }
        var scan = PlacesScan(lastScan: Date())
        var truth: [String: GeoPoint] = [:]
        var cameras: [String: String] = [:]
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, !f[2].isEmpty, let t = Double(f[1]), let lat = Double(f[2]), let lon = Double(f[3]) else { continue }
            let point = GeoPoint(lat: lat, lon: lon), date = Date(timeIntervalSince1970: t)
            let camera = f[4].trimmingCharacters(in: .whitespaces)
            if !camera.isEmpty { cameras[f[0]] = camera }
            let isPhone = camera.isEmpty || camera.contains("iPhone")
            // Whole days held out, so a held-out photo has no sister photo from the same outing.
            let day = Int(t / 86400)
            if isPhone || day % 2 == 0 {
                scan.located.append(f[0], date, point)
            } else {
                scan.missing[f[0]] = .some(date)
                truth[f[0]] = point
            }
        }
        let ids = Array(truth.keys)
        let calibration = PlacesState.calibrate(scan: scan, cameras: cameras)
        for (camera, c) in calibration.clocks.sorted(by: { $0.key < $1.key }) where c.reliability < 0.9 {
            print("  \(camera): reliability \(String(format: "%.2f", c.reliability)), checked \(c.checked)")
        }
        for (name, cal) in [("without camera reliability", PlaceCalibration()), ("with camera reliability", calibration)] {
            let guesses = PlacesState.guesses(ids: ids, scan: scan, placed: [:], untrusted: [], prints: [:], links: [:],
                                              cameras: cameras, calibration: cal)
            print("\(name): held out \(truth.count), shown \(guesses.count)")
            for level in [PlaceGuessResult.Level.high, .medium] {
                let errors = guesses.filter { $0.value.level == level }.map { $0.value.estimate.point.distanceKm(to: truth[$0.key]!) }.sorted()
                guard !errors.isEmpty else { continue }
                let within1 = Double(errors.filter { $0 < 1 }.count) / Double(errors.count)
                let within25 = Double(errors.filter { $0 < 25 }.count) / Double(errors.count)
                print("  \(level): \(errors.count)  median \(String(format: "%.2f", errors[errors.count / 2])) km  <1 km \(Int(within1 * 100))%  <25 km \(Int(within25 * 100))%")
            }
        }
    }
}

/// The place an outing shows: time-backed guesses as they are, look-alikes only when the photos agree.
final class OutingGuessTests: XCTestCase {
    let rome = GeoPoint(lat: 41.9, lon: 12.5)
    let oslo = GeoPoint(lat: 59.9, lon: 10.75)
    let lima = GeoPoint(lat: -12.05, lon: -77.04)

    func guess(_ p: GeoPoint, _ source: PlaceSource, _ confidence: Double) -> PlaceGuessResult {
        PlaceGuessResult(estimate: PlaceEstimate(point: p, confidence: confidence, spreadKm: 5),
                         evidence: [PlaceEvidence(source: source, summary: "", point: p, weight: confidence)])
    }

    func testOneLookAlikeDoesNotPlaceAnOuting() {
        let g = ["a": guess(oslo, .lookalike, 0.6)]
        XCTAssertNil(PlacesState.outingGuess(["a", "b", "c"], guesses: g))
    }

    func testLookAlikesThatDisagreeDoNotPlaceAnOuting() {
        let g = ["a": guess(oslo, .lookalike, 0.6), "b": guess(lima, .lookalike, 0.5), "c": guess(rome, .lookalike, 0.5)]
        XCTAssertNil(PlacesState.outingGuess(["a", "b", "c"], guesses: g))
    }

    func testLookAlikesThatAgreePlaceAnOuting() {
        let g = ["a": guess(oslo, .lookalike, 0.6), "b": guess(oslo, .lookalike, 0.5), "c": guess(lima, .lookalike, 0.7)]
        XCTAssertEqual(PlacesState.outingGuess(["a", "b", "c"], guesses: g)?.estimate.point, oslo)
    }

    func testAPhotoFromAroundThenWins() {
        let g = ["a": guess(oslo, .lookalike, 0.9), "b": guess(oslo, .lookalike, 0.8), "c": guess(rome, .sameTime, 0.5)]
        XCTAssertEqual(PlacesState.outingGuess(["a", "b", "c"], guesses: g)?.estimate.point, rome)
    }
}
