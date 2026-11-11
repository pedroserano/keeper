import XCTest
import DateGuessCore
@testable import DateGuesser

/// Key Photos, and a date you set spreading to the photos linked to it.
final class KeyPhotosTests: XCTestCase {
    func link(_ id: String, _ w: Double = 0.8) -> EventLinks.Link { EventLinks.Link(assetID: id, distance: 0.3, weight: w) }

    func testPhotosLinkedToManyUnsureOnesComeFirstAndSpreadOverEvents() {
        // "hub" is linked to ten unsure photos; "pair" to one; "twin" sits in hub's event too.
        var candidates: [String: Double] = ["hub": 0.2, "pair": 0.2, "lone": 0.2, "twin": 0.2, "other": 0.2]
        for i in 0..<10 { candidates["u\(i)"] = 0.1 }
        for i in 0..<6 { candidates["v\(i)"] = 0.1 }
        let links: [String: [EventLinks.Link]] = [
            "hub": (0..<10).map { link("u\($0)") },
            "pair": [link("lone")],
            "other": (0..<6).map { link("v\($0)") },
        ]
        let events = [["hub", "twin"] + (0..<10).map { "u\($0)" }]
        let ranked = AppState.rankKeyPhotos(candidates: candidates, links: links, events: events)
        XCTAssertEqual(ranked.first?.id, "hub")
        XCTAssertEqual(ranked.first?.helps, 11, "ten look-alikes and its event's other photo")
        XCTAssertEqual(ranked.dropFirst().first?.id, "other", "the next pick covers another event, not hub's again")
        XCTAssertFalse(ranked.contains { $0.id == "pair" }, "one link isn't worth a key photo")
    }

    func testADateYouSetDatesTheEvent() {
        var d = ReviewDecision()
        d.overrideYear = 1987
        d.overrideMonth = 6
        let clue = AppState.yourDateClue(d)!
        let options = EvidenceFusion.Options(allowExactMonth: true)
        // Three photos whose own clues say 1975; you dated one of them June 1987.
        let seventies = DateEvidence(source: .colorTone, summary: "Looks like 1975", yearLow: 1973, yearHigh: 1977, peakYear: 1975, weight: 0.6)
        let members = ["a", "b", "c"].map { GroupFusion.Member(assetID: $0, evidence: [seventies]) }
        let est = GroupFusion.estimates(members: members, groupEvidence: [clue], kind: .sameEvent, options: options)["b"]!
        XCTAssertEqual(est.year, 1987)
        var hidden = d
        hidden.ignored = true
        XCTAssertNil(AppState.yourDateClue(hidden), "a photo you hid tells nothing")
    }
}
