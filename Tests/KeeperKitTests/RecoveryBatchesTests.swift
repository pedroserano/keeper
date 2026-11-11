import XCTest
@testable import KeeperCore

/// Recovered photos: dated the day they came back, found by what they lack.
final class RecoveryBatchesTests: XCTestCase {
    let day = 86400.0

    private func batch(day d: Double, count: Int, sizes: Int, name: String = "Recovered-File - 1") -> [RecoveryBatches.Photo] {
        (0..<count).map { i in
            .init(uuid: "r\(d)-\(i)", date: d * day + Double(i), hasCameraTime: false, hasLocation: false,
                  width: 1000 + i % sizes, height: 700, isScreenshot: false, filename: name.replacingOccurrences(of: "1", with: "\(i)") + ".jpg")
        }
    }

    private func camera(day d: Double, count: Int) -> [RecoveryBatches.Photo] {
        (0..<count).map { i in
            .init(uuid: "c\(d)-\(i)", date: d * day + Double(i), hasCameraTime: true, hasLocation: true,
                  width: 4032, height: 3024, isScreenshot: false, filename: "IMG_\(i).HEIC")
        }
    }

    func testARecoveryDayAndTheDayBeforeAreFoundButNotPhotosReallyTakenThen() {
        var photos = batch(day: 5000, count: 300, sizes: 80) + camera(day: 5000, count: 40)
        photos += batch(day: 4999, count: 6, sizes: 1)          // the day before: few, but named like the batch
        photos += camera(day: 4000, count: 500)                 // an ordinary busy day
        let found = RecoveryBatches.find(photos)
        XCTAssertEqual(found.batches.count, 1)
        XCTAssertEqual(found.photos.count, 306)
        XCTAssertNil(found.photos["c5000.0-0"], "a camera photo taken that day isn't recovered")
        XCTAssertNotNil(found.photos["r4999.0-0"])
    }

    func testScreenshotsAndDownloadsNextDoorStayOut() {
        var photos = batch(day: 5000, count: 300, sizes: 80)
        // The next day: downloads in a few sizes, named differently.
        photos += (0..<16).map { .init(uuid: "d\($0)", date: 5001 * day + Double($0), hasCameraTime: false, hasLocation: false,
                                       width: 960, height: 1280 + $0 % 3, isScreenshot: false, filename: "image_\($0).jpg") }
        photos += (0..<20).map { .init(uuid: "s\($0)", date: 5000 * day + Double($0), hasCameraTime: false, hasLocation: false,
                                       width: 1170, height: 2532, isScreenshot: true, filename: "IMG_\($0).PNG") }
        let found = RecoveryBatches.find(photos)
        XCTAssertEqual(found.photos.count, 300)
    }

    func testLabels() {
        let one = RecoveryBatches.Batch(firstDay: 5000 * day, lastDay: 5000 * day, count: 1)
        let three = RecoveryBatches.Batch(firstDay: 4732 * day, lastDay: 4734 * day, count: 1)
        XCTAssertFalse(one.label.contains("–"))
        XCTAssertTrue(three.label.contains("–"))
    }

    /// The real library (skipped unless KEEPER_LIBRARY is set): prints totals only.
    func testOnARealLibrary() throws {
        guard let path = ProcessInfo.processInfo.environment["KEEPER_LIBRARY"] else { throw XCTSkip("no KEEPER_LIBRARY") }
        let found = try PhotosDatabase.readRecoveryBatches(inLibrary: URL(fileURLWithPath: path))
        print("RECOVERY: \(found.photos.count) photos in \(found.batches.count) batches")
        for b in found.batches { print("  \(b.label): \(b.count)") }
    }
}

/// Year albums in the real library (skipped unless KEEPER_LIBRARY is set): totals only.
final class YearAlbumsLibraryTests: XCTestCase {
    func testOnARealLibrary() throws {
        guard let path = ProcessInfo.processInfo.environment["KEEPER_LIBRARY"] else { throw XCTSkip("no KEEPER_LIBRARY") }
        let found = try PhotosDatabase.readYearAlbums(inLibrary: URL(fileURLWithPath: path)) { title in
            let years = title.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1800...2099).contains($0) }
            return years.count == 1 ? years[0] : nil
        }
        let judged = found.values.filter { $0.dated >= 10 }
        let tidy = judged.filter { Double($0.sameYear + 1) / Double($0.dated + 2) >= 0.8 }.count
        let mixed = judged.filter { Double($0.withinYear + 1) / Double($0.dated + 2) < 0.5 }.count
        print("YEAR ALBUMS: \(found.count) albums; \(judged.count) with 10+ dated photos: \(tidy) mostly from their year, \(judged.count - tidy - mixed) give or take a year, \(mixed) mixed")
    }
}
