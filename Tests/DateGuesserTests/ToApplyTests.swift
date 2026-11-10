import XCTest
import DateGuessCore
@testable import DateGuesser

/// Right-click Set Date… and Set Location… wait in To Apply instead of writing to Photos.
@MainActor
final class ToApplyTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        setenv("PDG_DATA_DIR", NSTemporaryDirectory() + "PhotoDateGuesserTests-\(UUID().uuidString)", 1)
    }

    let paris = PlaceChoice(name: "Paris", point: GeoPoint(lat: 48.8566, lon: 2.3522))

    func testSetDateAndLocationWaitForApply() {
        let state = AppState()
        state.pending = [:]
        state.decisions = [:]
        state.select(["a"], true)   // selected in Undated Photos
        let day = Date(timeIntervalSince1970: 600_000_000)

        _ = state.queueDate(["a", "b"], day: day)
        _ = state.queuePlace(["b", "c"], paris)
        XCTAssertEqual(state.pending["a"]?.date, day)
        XCTAssertEqual(state.pending["b"]?.date, day)
        XCTAssertEqual(state.pending["b"]?.place, paris)
        XCTAssertNil(state.pending["c"]?.date)
        XCTAssertFalse(state.decision("a").selected, "a queued date replaces the selection, so Apply can't write two")
        XCTAssertEqual(state.waitingCount, 4)

        state.dontApply(["b"], dates: true)
        XCTAssertNil(state.pending["b"]?.date)
        XCTAssertEqual(state.pending["b"]?.place, paris, "leaving out the date keeps the place")
        state.dontApply(["b"], dates: false)
        XCTAssertNil(state.pending["b"], "nothing left waiting")
    }

    func testHistoryFixWaitsWithItsCheck() {
        let state = AppState()
        state.pending = [:]
        let now = Date(timeIntervalSince1970: 700_000_000)
        let shift = AppState.DateShift(assetID: "x", appDate: Date(timeIntervalSince1970: 500_000_000), current: now)
        XCTAssertNotNil(state.queueDate([shift], year: 1984, month: 6))
        XCTAssertEqual(state.pending["x"]?.expected, now, "Apply skips it if its date changes again")
        XCTAssertEqual(state.pending["x"]?.keepsTime, false)
    }

    func testKeepingTheTimeOfDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 1990, month: 5, day: 2, hour: 12))!
        let old = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: 8, minute: 15, second: 3))!
        let both = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                           from: AppState.day(day, keepingTimeOf: old, calendar: calendar))
        XCTAssertEqual([both.year, both.month, both.day, both.hour, both.minute, both.second], [1990, 5, 2, 8, 15, 3])
        XCTAssertEqual(calendar.component(.hour, from: AppState.day(day, keepingTimeOf: nil, calendar: calendar)), 12)
    }
}

/// A place you give an undated scan in Keeper dates it straight away, from the trip photos there.
@MainActor
final class PlacedHereDateTests: XCTestCase {
    func testAPlaceSetInKeeperIsADateClue() {
        let rome = GeoPoint(lat: 41.9, lon: 12.5)
        var located = LocatedPhotos()
        let july2010 = Date(timeIntervalSince1970: 1_279_000_000)
        for i in 0..<10 { located.append("trip\(i)", july2010.addingTimeInterval(Double(i) * 3600), rome) }
        let undated = ["scan": UndatedPhoto(id: "scan", reason: .noCaptureDateInFile, libraryDate: nil, format: FormatInfo(), albums: [])]
        XCTAssertNil(AppState.placeDateClues(located: located, undated: undated, notReferences: ["scan"])["scan"],
                     "no location, no clue")
        let clue = AppState.placeDateClues(located: located, undated: undated, notReferences: ["scan"],
                                           placedHere: ["scan": rome])["scan"]
        XCTAssertEqual(clue?.peakYear, 2010)
    }
}
