import XCTest
import DateGuessCore
@testable import DateGuesser

/// Setting one date for many checked photos at once.
@MainActor
final class SetDateTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        setenv("PDG_DATA_DIR", NSTemporaryDirectory() + "PhotoDateGuesserTests-\(UUID().uuidString)", 1)
    }

    func testOneDateForManyPhotos() {
        let state = AppState()
        state.decisions = [:]   // other tests in this run share the data folder
        state.setMonth("a", 3)           // had its own month
        state.setOverride("b", year: 1970, season: .fall)
        state.setIgnored("c", true)       // hidden photos are left alone

        state.setDate(["a", "b", "c"], year: 1988, season: nil, month: 7)
        for id in ["a", "b"] {
            XCTAssertEqual(state.decision(id).overrideYear, 1988, id)
            XCTAssertEqual(state.decision(id).overrideMonth, 7, id)
            XCTAssertNil(state.decision(id).overrideSeason, id)
            XCTAssertTrue(state.decision(id).selected, id)
        }
        XCTAssertNil(state.decision("c").overrideYear)

        // A season replaces the month; no season keeps each photo's guessed season.
        state.setDate(["a"], year: 1990, season: .winter, month: nil)
        XCTAssertEqual(state.decision("a").overrideSeason, .winter)
        XCTAssertNil(state.decision("a").overrideMonth)
        state.setDate(["b"], year: 1991, season: nil, month: nil)
        XCTAssertEqual(state.decision("b").overrideYear, 1991)
        XCTAssertNil(state.decision("b").overrideSeason)
        XCTAssertNil(state.decision("b").overrideMonth)
    }
}
