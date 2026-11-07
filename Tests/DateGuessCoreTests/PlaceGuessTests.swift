import XCTest
@testable import DateGuessCore

final class PlaceGuessTests: XCTestCase {
    let dc = GeoPoint(lat: 38.8977, lon: -77.0365)
    let baltimore = GeoPoint(lat: 39.2904, lon: -76.6122)
    let paris = GeoPoint(lat: 48.8566, lon: 2.3522)

    func testDistance() {
        XCTAssertEqual(dc.distanceKm(to: baltimore), 57, accuracy: 3)
        XCTAssertEqual(dc.distanceKm(to: paris), 6_160, accuracy: 60)
        XCTAssertEqual(dc.distanceKm(to: dc), 0, accuracy: 0.001)
    }

    func testFusionPicksTheAreaWithMoreSupport() {
        let near = GeoPoint(lat: 48.86, lon: 2.36)
        let e = [
            PlaceEvidence(source: .lookalike, summary: "", point: dc, weight: 0.5),
            PlaceEvidence(source: .sameTime, summary: "", point: paris, weight: 0.4),
            PlaceEvidence(source: .sameTime, summary: "", point: near, weight: 0.3),
        ]
        let guess = PlaceFusion.estimate(e)!
        XCTAssertLessThan(guess.point.distanceKm(to: paris), 2)
        XCTAssertLessThan(guess.confidence, 0.6, "a strong clue elsewhere lowers confidence")
        XCTAssertNil(PlaceFusion.estimate([]))
    }

    func testAgreeingClosePhotosAreConfident() {
        let e = [
            PlaceEvidence(source: .sameTime, summary: "", point: dc, weight: 0.93),
            PlaceEvidence(source: .sameTime, summary: "", point: GeoPoint(lat: 38.898, lon: -77.037), weight: 0.9),
        ]
        let guess = PlaceFusion.estimate(e)!
        XCTAssertGreaterThan(guess.confidence, 0.95)
        XCTAssertLessThan(guess.spreadKm, 1)
    }

    func testTimeWeightsFallOff() {
        XCTAssertEqual(PlaceTimeline.weight(gap: 0), 0.95, accuracy: 0.001)
        XCTAssertGreaterThan(PlaceTimeline.weight(gap: 600), PlaceTimeline.weight(gap: 3600))
        XCTAssertGreaterThan(PlaceTimeline.weight(gap: -3600), PlaceTimeline.weight(gap: 5 * 3600))
        XCTAssertEqual(PlaceTimeline.weight(gap: 25 * 3600), 0)
    }

    func testTimelineFindsNeighborsOnBothSides() {
        let t0 = Date(timeIntervalSince1970: 1_000_000_000)
        let timeline = PlaceTimeline([
            .init(id: "a", time: t0.addingTimeInterval(-600), point: dc),
            .init(id: "b", time: t0.addingTimeInterval(1800), point: baltimore),
            .init(id: "c", time: t0.addingTimeInterval(-3 * 86400), point: paris),
        ])
        let e = timeline.evidence(at: t0)
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e.first { $0.referenceID == "a" }?.summary, "10 minutes after a photo with a location")
        XCTAssertEqual(e.first { $0.referenceID == "b" }?.summary, "30 minutes before a photo with a location")
        XCTAssertNil(e.first { $0.referenceID == "c" }, "days away doesn't count")
        XCTAssertLessThan(PlaceFusion.estimate(e)!.point.distanceKm(to: dc), 1, "the closer one in time wins")
    }

    func testProbeNeedsAgreement() {
        let votes = (0..<10).map { (point: $0 < 8 ? dc : paris, weight: 1.0, id: "\($0)") }
        XCTAssertEqual(PlaceProbe.clue(votes, maxWeight: 0.6)?.point, dc)
        let split = (0..<10).map { (point: $0 % 2 == 0 ? dc : paris, weight: 1.0, id: "\($0)") }
        XCTAssertNil(PlaceProbe.clue(split, maxWeight: 0.6))
    }

    func testProbeFindsLookalikes() {
        var examples: [PlaceProbe.Example] = []
        for i in 0..<60 {
            let atHome = i % 2 == 0
            var v = [Float](repeating: 0, count: 8)
            v[atHome ? 0 : 1] = 1
            v[2 + i % 6] = 0.1
            examples.append(.init(id: "\(i)", point: atHome ? dc : paris, print: v))
        }
        let probe = PlaceProbe(examples)
        let clues = probe.evidence(for: ["q": [0, 1, 0.05, 0, 0, 0, 0, 0]])
        XCTAssertLessThan(clues["q"]!.point.distanceKm(to: paris), 1)
    }
}

final class PlaceCalibrationTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_400_000_000)

    /// A phone wandering between far-apart spots every hour, and a camera with it.
    private func photos(cameraOffset: TimeInterval) -> [PlaceCalibration.Photo] {
        var out: [PlaceCalibration.Photo] = []
        for hour in 0..<200 {
            let spot = GeoPoint(lat: 30 + Double(hour % 17) * 0.5, lon: -90 + Double(hour % 13) * 0.5)
            for minute in stride(from: 0, to: 60, by: 20) {
                out.append(.init(camera: "Phone", time: t0.addingTimeInterval(Double(hour * 3600 + minute * 60)), point: spot))
            }
            // The camera's clock reads `cameraOffset` early, so its times need it added back.
            out.append(.init(camera: "Camera", time: t0.addingTimeInterval(Double(hour * 3600 + 600) - cameraOffset), point: spot))
        }
        return out
    }

    func testRightCameraKeepsFullWeight() {
        let calibration = PlaceCalibration.learn(photos(cameraOffset: 0))
        XCTAssertGreaterThan(calibration.reliability(camera: "Camera"), 0.95)
        XCTAssertEqual(calibration.reliability(camera: "Unknown"), 1)
    }

    func testUnreliableCameraCountsLess() {
        var p = photos(cameraOffset: 0)
        // Its photos land somewhere else entirely, whatever the time.
        for i in p.indices where p[i].camera == "Camera" { p[i].point = GeoPoint(lat: -40, lon: 170) }
        XCTAssertLessThan(PlaceCalibration.learn(p).reliability(camera: "Camera"), 0.3)
    }

    func testOutingsSplitOnGapsAndCameras() {
        let p: [PlaceOutings.Photo] = [
            .init(id: "a1", time: t0, camera: "A"),
            .init(id: "a2", time: t0.addingTimeInterval(3600), camera: "A"),
            .init(id: "a3", time: t0.addingTimeInterval(3 * 3600 + 3601), camera: "A"),
            .init(id: "b1", time: t0.addingTimeInterval(1800), camera: "B"),
        ]
        let outings = PlaceOutings.group(p)
        XCTAssertEqual(outings.first, ["a1", "a2"])
        XCTAssertEqual(Set(outings.dropFirst().map { $0 }), [["a3"], ["b1"]])
    }
}
