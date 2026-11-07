import Foundation
import SQLite3
import XCTest
@testable import DateGuesser

final class PhotosPeopleReaderTests: XCTestCase {
    /// Builds a tiny library with the same tables Photos uses (current column names).
    func makeLibrary() throws -> URL {
        let lib = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Test \(UUID().uuidString).photoslibrary")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("database"), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(lib.appendingPathComponent("database/Photos.sqlite").path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE ZPERSON (Z_PK INTEGER PRIMARY KEY, ZFULLNAME TEXT, ZDISPLAYNAME TEXT, ZPERSONUUID TEXT, ZMERGETARGETPERSON INTEGER);
            CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZTRASHEDSTATE INTEGER, ZDATECREATED REAL, ZLATITUDE REAL, ZLONGITUDE REAL);
            CREATE TABLE ZDETECTEDFACE (Z_PK INTEGER PRIMARY KEY, ZPERSONFORFACE INTEGER, ZASSETFORFACE INTEGER, ZHIDDEN INTEGER, ZSIZE REAL, ZCENTERX REAL, ZCENTERY REAL, ZAGETYPE INTEGER);
            INSERT INTO ZPERSON VALUES (1, 'Rose Smith', 'Rose', 'P-ROSE', NULL), (2, '', 'Dad', 'P-DAD', NULL),
                                       (3, '', '', 'P-UNNAMED', NULL), (4, 'Rose Smith', '', 'P-OLD', 1);
            INSERT INTO ZASSET VALUES (1, 'A1', 0, 0, -180, -180), (2, 'A2', 0, 200000000, 40.7, -74.0), (3, 'A3', 1, 0, -180, -180);
            INSERT INTO ZDETECTEDFACE VALUES (1, 1, 1, 0, 0.1, 0.25, 0.8, 3), (2, 1, 2, 0, 0.3, 0.5, 0.5, 3),
                                             (3, 2, 1, 0, 0.2, 0.7, 0.4, 5), (4, 2, 3, 0, 0.2, 0.5, 0.5, 5),
                                             (5, 3, 2, 0, 0.2, 0.5, 0.5, 1), (6, 4, 2, 0, 0.2, 0.5, 0.5, 3),
                                             (7, 2, 2, 1, 0.2, 0.5, 0.5, 5);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        return lib
    }

    func testReadsNamedPeopleAndTheirPhotos() throws {
        let people = try PhotosPeopleReader.read(libraryURL: try makeLibrary()).people
        let byName = Dictionary(uniqueKeysWithValues: people.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["Rose Smith", "Dad"], "unnamed and merged people are skipped")
        XCTAssertEqual(byName["Rose Smith"]?.assetIDs, ["A2/L0/001", "A1/L0/001"], "biggest face first")
        XCTAssertEqual(byName["Dad"]?.assetIDs, ["A1/L0/001"], "trashed photos and hidden faces are skipped")
    }

    func testReadsFacesForRequestedPhotosOnly() throws {
        let faces = try PhotosPeopleReader.read(libraryURL: try makeLibrary(), facesFor: ["A1/L0/001"]).faces
        XCTAssertEqual(Array(faces.keys), ["A1/L0/001"])
        let a1 = faces["A1/L0/001"] ?? []
        XCTAssertEqual(a1.count, 2)
        let rose = a1.first { $0.name == "Rose Smith" }
        XCTAssertEqual(rose?.clusterID, "P-ROSE")
        XCTAssertEqual(rose?.ageType, 3)
        XCTAssertEqual(rose?.x ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(rose?.y ?? 0, 0.2, accuracy: 1e-9, "flipped to measure from the top")
    }

    /// Dated photos of the face groups seen in undated photos become references, with their dates.
    func testReadsDatedReferencesForFaceGroups() throws {
        let refs = try PhotosPeopleReader.read(libraryURL: try makeLibrary(), facesFor: ["A1/L0/001"]).references
        // A1 is undated (excluded); A2 shows Rose, who is in A1, and is dated 2007-05-04 with a location.
        let a2 = try XCTUnwrap(refs["A2/L0/001"])
        XCTAssertEqual(a2.year, 2007)
        XCTAssertTrue(a2.hasGPS)
        XCTAssertTrue(a2.clusterIDs.contains("P-ROSE"))
        XCTAssertNil(refs["A1/L0/001"])
        XCTAssertNil(refs["A3/L0/001"], "trashed photos are left out")
    }

    func testRejectsFoldersThatAreNotLibraries() {
        XCTAssertThrowsError(try PhotosPeopleReader.read(libraryURL: URL(fileURLWithPath: NSTemporaryDirectory())))
    }
}

final class ContactLinkTests: XCTestCase {
    func testDecodesPhotosContactRecord() throws {
        let record: NSDictionary = ["contact-identifier": "ABC-123:ABPerson", "email-addresses": ["rose@example.com"],
                                    "phone-numbers": ["+1 555 0100"], "first-name": "Rose", "last-name": "", "version": 2]
        let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        let match = try XCTUnwrap(ContactMatch(archive: data))
        XCTAssertEqual(match.identifiers, ["ABC-123:ABPerson"])
        XCTAssertEqual(match.emails, ["rose@example.com"])
        XCTAssertEqual(match.phones, ["+1 555 0100"])
        XCTAssertEqual(match.firstName, "Rose")
        XCTAssertNil(match.lastName)
    }

    /// Contacts identifiers include the ":ABPerson" suffix; stripping it made every lookup fail.
    func testLinkKeepsFullIdentifiers() {
        var tagged = TaggedPerson(id: "P1", name: "Rose", assetIDs: [], contactID: "XYZ-9:ABPerson")
        tagged.contactMatch = nil
        XCTAssertEqual(ContactBirthdays.Link(tagged).identifiers, ["XYZ-9:ABPerson"])
    }
}

final class ShowInPhotosTests: XCTestCase {
    /// The full identifier, slashes encoded, is what makes Photos select the photo.
    func testLinkUsesFullEncodedIdentifier() {
        XCTAssertEqual(ShowInPhotos.url(for: "61B4A2C0-1D2E-4F00-9A8B-0123456789AB/L0/001")?.absoluteString,
                       "photos://asset?identifier=61B4A2C0-1D2E-4F00-9A8B-0123456789AB%2FL0%2F001")
    }
}

final class OnDeviceModelTests: XCTestCase {
    func testParsesTheModelsAnswer() {
        let r = OnDeviceModel.parse("Season: Autumn; Occasion: halloween")
        XCTAssertEqual(r.season, .fall)
        XCTAssertEqual(r.occasion, .halloween)
        let none = OnDeviceModel.parse("season: unknown; occasion: none")
        XCTAssertNil(none.season)
        XCTAssertNil(none.occasion)
    }

    /// Analyses saved by earlier versions (with Claude fields) must still load.
    func testOldSavedAnalysesStillDecode() throws {
        let json = """
        {"assetID":"A/L0/001","localEvidence":[],"aiEvidence":[],"usedAI":false,"analyzedAt":0,"localVersion":2}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let a = try decoder.decode(PhotoAnalysis.self, from: Data(json.utf8))
        XCTAssertEqual(a.assetID, "A/L0/001")
        XCTAssertTrue(a.isCurrent)
        XCTAssertNil(a.modelChecked)
    }
}

final class ApplySafetyTests: XCTestCase {
    /// Only undated, checked, not-hidden photos the app hasn't already dated can be written.
    func testOnlyCheckedUndatedPhotosAreApplied() {
        var checked = ReviewDecision(); checked.selected = true
        var hidden = ReviewDecision(); hidden.selected = true; hidden.ignored = true
        let decisions: [String: ReviewDecision] = [
            "u1": checked, "u2": ReviewDecision(), "u3": hidden, "u4": checked,
            // Checked but not on the undated list: a dated reference photo, or a group member that's dated.
            "dated": checked,
        ]
        let targets = AppState.applyTargets(order: ["u1", "u2", "u3", "u4"], applied: ["u4"], decisions: decisions,
                                            hasEstimate: { _ in true })
        XCTAssertEqual(targets, ["u1"])
    }

    func testPhotosWithoutAnEstimateAreSkipped() {
        var checked = ReviewDecision(); checked.selected = true
        XCTAssertTrue(AppState.applyTargets(order: ["u1"], applied: [], decisions: ["u1": checked],
                                            hasEstimate: { _ in false }).isEmpty)
    }

    /// A photo re-dated in Photos after the scan must be left alone.
    func testDetectsDatesChangedSinceTheScan() {
        let scanned = Date(timeIntervalSince1970: 1_500_000_000)
        XCTAssertFalse(DateWriter.dateChangedSinceScan(current: scanned, expected: scanned))
        XCTAssertFalse(DateWriter.dateChangedSinceScan(current: scanned.addingTimeInterval(0.5), expected: scanned), "rounding")
        XCTAssertTrue(DateWriter.dateChangedSinceScan(current: Date(timeIntervalSince1970: 300_000_000), expected: scanned))
        XCTAssertFalse(DateWriter.dateChangedSinceScan(current: nil, expected: nil), "still no date")
        XCTAssertTrue(DateWriter.dateChangedSinceScan(current: scanned, expected: nil), "someone gave it a date")
    }
}

@MainActor
final class DatedEventTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        setenv("PDG_DATA_DIR", NSTemporaryDirectory() + "PhotoDateGuesserTests-\(UUID().uuidString)", 1)
    }

    /// Dating an event sets every photo's date and checks it for Apply (hidden photos stay hidden).
    func testDatedEventChecksItsPhotos() {
        let state = AppState()
        var hidden = ReviewDecision(); hidden.ignored = true
        state.decisions = ["c": hidden]
        state.saveEvent(["a", "b", "c"], name: "Picnic", year: 1979, month: 7, season: nil)
        for id in ["a", "b"] {
            XCTAssertEqual(state.decisions[id]?.selected, true)
            XCTAssertEqual(state.decisions[id]?.overrideYear, 1979)
            XCTAssertEqual(state.decisions[id]?.overrideMonth, 7)
        }
        XCTAssertEqual(state.decisions["c"]?.selected, false, "a hidden photo isn't checked")
    }

    /// Confirming an event without a date still checks its photos; they keep the shared guess.
    func testEventWithoutADateChecksItsPhotosWithoutOverriding() {
        let state = AppState()
        state.saveEvent(["a", "b"], name: "Picnic", year: nil, month: nil, season: nil)
        XCTAssertEqual(state.decisions["a"]?.selected, true)
        XCTAssertEqual(state.decisions["a"]?.isOverridden, false)
    }

    func testSettingAMonthKeepsTheYearAndChecksThePhoto() {
        let state = AppState()
        state.setOverride("a", year: 1981, season: .winter)
        state.setMonth("a", 8)
        XCTAssertEqual(state.decisions["a"]?.overrideYear, 1981)
        XCTAssertEqual(state.decisions["a"]?.overrideMonth, 8)
        XCTAssertNil(state.decisions["a"]?.overrideSeason)
        XCTAssertEqual(state.decisions["a"]?.selected, true)
    }
}
