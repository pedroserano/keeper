import Foundation
import Testing
@testable import DateGuessCore

struct PlaceDateCluesTests {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }
    let beach = GeoPoint(lat: 41.30, lon: -70.10)
    let home = GeoPoint(lat: 41.76, lon: -72.68)

    @Test func aOneTimeTripDatesThePhoto() {
        let refs = (1...8).map { PlaceDateClues.Reference(time: date(2019, 8, $0), point: beach) }
        let e = PlaceDateClues.evidence(for: ["u": beach], references: refs, calendar: utc)["u"]
        #expect(e?.source == .location)
        #expect(e?.yearLow == 2019 && e?.yearHigh == 2019)
        #expect(e?.exactMonth == 8)
        #expect((e?.weight ?? 0) >= 0.85)
    }

    @Test func aPlacePhotographedAllTheTimeSaysNothing() {
        let refs = (0..<24).map { PlaceDateClues.Reference(time: date(2015 + $0 / 12, $0 % 12 + 1, 10), point: home) }
        #expect(PlaceDateClues.evidence(for: ["u": home], references: refs, calendar: utc).isEmpty)
    }

    @Test func mostlyOneMonthIsALesserClue() {
        let refs = (1...8).map { PlaceDateClues.Reference(time: date(2019, 8, $0), point: beach) }
            + [.init(time: date(2012, 3, 1), point: beach), .init(time: date(2014, 5, 1), point: beach)]
        let e = PlaceDateClues.evidence(for: ["u": beach], references: refs, calendar: utc)["u"]
        #expect(e?.weight == 0.6)
        #expect(e?.exactMonth == nil)
    }

    @Test func tooFewOrTooFarSaysNothing() {
        let two = (1...2).map { PlaceDateClues.Reference(time: date(2019, 8, $0), point: beach) }
        #expect(PlaceDateClues.evidence(for: ["u": beach], references: two, calendar: utc).isEmpty)
        let far = (1...8).map { PlaceDateClues.Reference(time: date(2019, 8, $0), point: GeoPoint(lat: 41.33, lon: -70.10)) }
        #expect(PlaceDateClues.evidence(for: ["u": beach], references: far, calendar: utc).isEmpty)   // about 3 km off
    }
}
