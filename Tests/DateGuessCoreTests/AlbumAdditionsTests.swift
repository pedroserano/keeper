import Foundation
import Testing
@testable import DateGuessCore

struct AlbumAdditionsTests {
    let portland = GeoPoint(lat: 43.66, lon: -70.26)
    let bangor = GeoPoint(lat: 44.80, lon: -68.77)   // about 170 km on
    let home = GeoPoint(lat: 41.76, lon: -72.68)
    let t0 = Date(timeIntervalSince1970: 1_785_000_000)
    let day = 86_400.0

    func photo(_ id: String, _ days: Double, _ p: GeoPoint) -> AlbumSuggestions.Photo {
        .init(id: id, time: t0.addingTimeInterval(days * day), point: p)
    }

    var trip: AlbumAdditions.Album {
        .init(id: "A", title: "Maine", located: [photo("a1", 0, portland), photo("a2", 1, portland),
                                                 photo("a3", 3, bangor), photo("a4", 4, bangor)])
    }

    @Test func photosFromTheTripAreFound() {
        let loose = [photo("x1", 0.5, portland), photo("x2", 3.5, bangor)]
        let out = AlbumAdditions.suggest(albums: [trip], loose: loose)
        #expect(out.first?.ids == ["x1", "x2"])
    }

    @Test func outsideTheDaysOrFarAwayIsNot() {
        let loose = [photo("before", -1, portland), photo("after", 5, bangor),
                     photo("home", 1, home),                 // during the trip, but at home
                     photo("wrongStop", 0.5, bangor)]        // Bangor while the album was in Portland
        #expect(AlbumAdditions.suggest(albums: [trip], loose: loose).isEmpty)
    }

    @Test func longAlbumsAreLeftOut() {
        let year = AlbumAdditions.Album(id: "Y", title: "2026", located: [photo("y1", 0, home), photo("y2", 100, home),
                                                                         photo("y3", 200, home)])
        #expect(AlbumAdditions.suggest(albums: [year], loose: [photo("x", 50, home)]).isEmpty)
    }

    @Test func aPhotoGoesToTheAlbumClosestInTime() {
        let party = AlbumAdditions.Album(id: "P", title: "Party", located: [photo("p1", 0.4, portland), photo("p2", 0.45, portland),
                                                                          photo("p3", 0.5, portland)])
        let out = AlbumAdditions.suggest(albums: [trip, party], loose: [photo("x", 0.46, portland)])
        #expect(out.count == 1)
        #expect(out.first?.albumID == "P")
    }
}
