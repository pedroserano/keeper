import Foundation
import Testing
@testable import DateGuessCore

struct AlbumSuggestionsTests {
    let home = GeoPoint(lat: 41.76, lon: -72.68)
    let away = GeoPoint(lat: 43.66, lon: -70.26)   // about 300 km off
    let day = 86_400.0
    let t0 = Date(timeIntervalSince1970: 1_785_000_000)

    func photos(_ prefix: String, at point: GeoPoint, from start: Double, days: Int, perDay: Int = 5) -> [AlbumSuggestions.Photo] {
        (0..<days).flatMap { d in
            (0..<perDay).map { i in
                AlbumSuggestions.Photo(id: "\(prefix)\(d)-\(i)", time: t0.addingTimeInterval((start + Double(d)) * day + Double(i) * 600),
                                       point: point)
            }
        }
    }

    @Test func aTripIsSuggested() {
        let trip = photos("t", at: away, from: 0, days: 5)
        let out = AlbumSuggestions.suggest(trip, existing: [])
        #expect(out.count == 1)
        #expect(out.first?.ids.count == 25)
    }

    @Test func runsLongerThanThirtyDaysAreNot() {
        let everyday = photos("h", at: home, from: 0, days: 45, perDay: 1)
        #expect(AlbumSuggestions.suggest(everyday, existing: []).isEmpty)
    }

    @Test func aMoveOrALongGapStartsANewRun() {
        let first = photos("a", at: away, from: 0, days: 3)
        let home1 = photos("h", at: home, from: 3, days: 3)
        let later = photos("b", at: away, from: 10, days: 3)   // a week later: its own trip
        let out = AlbumSuggestions.suggest(first + home1 + later, existing: [])
        #expect(out.count == 3)
        #expect(out.first?.ids.first == "b0-0")   // newest first
    }

    @Test func smallRunsAreLeftOut() {
        #expect(AlbumSuggestions.suggest(photos("s", at: away, from: 0, days: 1, perDay: 4), existing: []).isEmpty)
    }

    @Test func aDatedAlbumHoldingHalfCoversIt() {
        let trip = photos("t", at: away, from: 0, days: 4)
        let half = Set(trip.prefix(10).map(\.id))
        #expect(AlbumSuggestions.suggest(trip, existing: [.init(title: "2026-08 Portland", ids: half)]).isEmpty)
        // No year and month in the name: still suggested.
        #expect(AlbumSuggestions.suggest(trip, existing: [.init(title: "Portland trip", ids: half)]).count == 1)
        // Too few of its photos: still suggested.
        let few = Set(trip.prefix(3).map(\.id))
        #expect(AlbumSuggestions.suggest(trip, existing: [.init(title: "2026-08 Portland", ids: few)]).count == 1)
    }

    @Test func yearAndMonthInNames() {
        for yes in ["2026-08 Hartford", "Trip 2026.08", "08/2026", "Aug 2026", "August, 2026", "2026 August", "Hartford 2026_8"] {
            #expect(AlbumSuggestions.hasYearAndMonth(yes), "\(yes)")
        }
        for no in ["Hartford", "2026", "Summer 2026", "Best of 2019-2020", "IMG 20260"] {
            #expect(!AlbumSuggestions.hasYearAndMonth(no), "\(no)")
        }
    }

    @Test func titles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14))!
        #expect(AlbumSuggestions.title(start: date, town: "Hartford, CT", calendar: calendar) == "2026-08 Hartford")
        #expect(AlbumSuggestions.title(start: date, town: nil, calendar: calendar) == "2026-08")
    }
}
