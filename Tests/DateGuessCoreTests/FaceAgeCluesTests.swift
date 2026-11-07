import XCTest
@testable import DateGuessCore

final class FaceAgeCluesTests: XCTestCase {
    let peter = PersonInfo(name: "Peter", birthYear: 1984)
    let sarah = PersonInfo(name: "Sarah", birthYear: 1987)
    let doug = PersonInfo(name: "Doug", birthYear: 1955)

    func testOneChildGivesATightRange() {
        let e = FaceAgeClues.evidence([.init(personID: peter.id, age: 4)], people: [peter])!
        XCTAssertEqual(e.peakYear, 1988)
        XCTAssertLessThanOrEqual(e.yearHigh! - e.yearLow!, 5)
        XCTAssertGreaterThanOrEqual(e.weight, 0.7)
        XCTAssertEqual(e.calibrationKey, "person:faceModel")
        XCTAssertTrue(e.summary.contains("Peter looks about 4"))
    }

    func testFacesThatAgreeCombine() {
        let one = FaceAgeClues.evidence([.init(personID: peter.id, age: 10)], people: [peter, sarah])!
        let two = FaceAgeClues.evidence([.init(personID: peter.id, age: 10), .init(personID: sarah.id, age: 7)], people: [peter, sarah])!
        XCTAssertLessThan(two.yearHigh! - two.yearLow!, one.yearHigh! - one.yearLow!, "two agreeing faces narrow it")
        XCTAssertEqual(two.peakYear, 1994)
    }

    func testAFaceFarFromTheOthersIsLeftOut() {
        // Two children agree on ~1990; an "adult" reading that would mean 2020 is probably someone else.
        let e = FaceAgeClues.evidence([.init(personID: peter.id, age: 6), .init(personID: sarah.id, age: 3),
                                       .init(personID: doug.id, age: 65)], people: [peter, sarah, doug])!
        XCTAssertEqual(e.peakYear, 1990)
        XCTAssertFalse(e.summary.contains("Doug"))
    }

    func testNoBirthYearNoClue() {
        let riley = PersonInfo(name: "Riley", birthYear: nil)
        XCTAssertNil(FaceAgeClues.evidence([.init(personID: riley.id, age: 5)], people: [riley]))
    }

    func testCorrectionLearnsTheModelsBias() {
        // The model reads teenagers 5 years too old.
        var pairs: [(read: Double, real: Double)] = []
        for i in 0..<40 {
            let real = 15.0 + Double(i % 5)
            pairs.append((read: real + 5, real: real))
        }
        let c = FaceAgeClues.Correction.learn(pairs)
        XCTAssertEqual(c.bracket(19).bias, 0, "the 13–19 bracket had no readings in it")
        XCTAssertEqual(c.bracket(22).bias, 5, accuracy: 0.01)
        let e = FaceAgeClues.evidence([.init(personID: peter.id, age: 22)], people: [peter], correction: c)!
        XCTAssertEqual(e.peakYear, 2001, "17 after correcting")
        XCTAssertEqual(FaceAgeClues.Correction.learn([]), .standard)
    }
}
