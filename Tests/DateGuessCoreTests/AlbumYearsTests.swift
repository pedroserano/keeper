import XCTest
@testable import DateGuessCore

/// Albums named for a year count as much as their own dated photos say they should.
final class AlbumYearsTests: XCTestCase {
    func clue(_ title: String, _ year: Int) -> DateEvidence {
        TextClues.evidence(fromAlbumName: title).first { $0.yearLow == year }!
    }

    func testTheYearInATitle() {
        XCTAssertEqual(AlbumYears.year(inTitle: "1998"), 1998)
        XCTAssertEqual(AlbumYears.year(inTitle: "Beach 2004"), 2004)
        XCTAssertNil(AlbumYears.year(inTitle: "1998–2001"), "several years")
        XCTAssertNil(AlbumYears.year(inTitle: "Holidays"))
    }

    func testAnAlbumWhosePhotosAreFromItsYearCountsHeavily() {
        let e = clue("1998", 1998)
        let tidy = AlbumYears.adjust(e, albums: ["1998": YearAlbum(year: 1998, dated: 200, sameYear: 190, withinYear: 198)])
        XCTAssertGreaterThan(tidy.weight, e.weight)
        XCTAssertEqual(tidy.yearLow, 1998)
        XCTAssertEqual(tidy.yearHigh, 1998)
    }

    func testAnAlbumThatSpillsIntoNeighbouringYearsSaysGiveOrTakeOne() {
        let e = clue("1998", 1998)
        let spill = AlbumYears.adjust(e, albums: ["1998": YearAlbum(year: 1998, dated: 200, sameYear: 120, withinYear: 185)])
        XCTAssertEqual(spill.yearLow, 1997)
        XCTAssertEqual(spill.yearHigh, 1999)
        XCTAssertEqual(spill.peakYear, 1998)
        XCTAssertGreaterThan(spill.weight, e.weight)
    }

    func testAMixedOrSmallAlbum() {
        let e = clue("1998", 1998)
        let mixed = AlbumYears.adjust(e, albums: ["1998": YearAlbum(year: 1998, dated: 200, sameYear: 40, withinYear: 60)])
        XCTAssertLessThan(mixed.weight, e.weight, "photos from all over: counts for less")
        let small = AlbumYears.adjust(e, albums: ["1998": YearAlbum(year: 1998, dated: 3, sameYear: 3, withinYear: 3)])
        XCTAssertEqual(small.weight, e.weight, "too few dated photos to judge")
        XCTAssertEqual(AlbumYears.adjust(e, albums: [:]).weight, e.weight)
    }
}
