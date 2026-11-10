import XCTest
@testable import DateGuesser

/// ⌘Z on the Dates screens, and moving and selecting in their grids.
@MainActor
final class SelectionTests: XCTestCase {
    func testUndoAndRedoPutBackOnlyTheChangedPhotos() {
        var history = DecisionHistory<Int>()
        var decisions = ["a": 1, "b": 2]
        history.record(["a", "c"], from: decisions)
        decisions["a"] = 10
        decisions["c"] = 30
        decisions["b"] = 20   // not recorded: stays as it is

        XCTAssertTrue(history.undo(&decisions))
        XCTAssertEqual(decisions, ["a": 1, "b": 20])
        XCTAssertFalse(history.undo(&decisions))

        XCTAssertTrue(history.redo(&decisions))
        XCTAssertEqual(decisions, ["a": 10, "b": 20, "c": 30])
    }

    func testANewChangeClearsRedo() {
        var history = DecisionHistory<Int>()
        var decisions = ["a": 1]
        history.record(["a"], from: decisions)
        decisions["a"] = 2
        XCTAssertTrue(history.undo(&decisions))
        history.record(["a"], from: decisions)
        decisions["a"] = 3
        XCTAssertFalse(history.canRedo)
    }

    func testMovingStaysInsideTheList() {
        let ids = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(GridCursor.moved(nil, by: 1, in: ids), "a")
        XCTAssertEqual(GridCursor.moved("b", by: 3, in: ids), "e")
        XCTAssertEqual(GridCursor.moved("b", by: 10, in: ids), "e")
        XCTAssertEqual(GridCursor.moved("b", by: -4, in: ids), "a")
        XCTAssertNil(GridCursor.moved("b", by: 1, in: []))
        XCTAssertEqual(GridCursor.neighbour(of: "e", in: ids), "d")
        XCTAssertEqual(GridCursor.neighbour(of: "b", in: ids), "c")
        XCTAssertNil(GridCursor.neighbour(of: "a", in: ["a"]))
    }

    func testClicksSelectLikeKeepersLists() {
        let ids = ["a", "b", "c", "d"]
        var selected: Set<String> = []
        let actions = GridActions(
            isSelected: { selected.contains($0) },
            canSelect: { $0 != "c" },
            select: { ids, on in if on { selected.formUnion(ids) } else { selected.subtract(ids) } },
            accept: { _ in }, decline: { _ in }, rotate: { _ in }, open: { _ in }, message: { _ in })
        var cursor = GridCursor()

        cursor.click("a", in: ids, modifiers: [], actions)
        XCTAssertEqual(cursor.id, "a")
        XCTAssertTrue(selected.isEmpty, "a plain click only makes it current")

        cursor.click("d", in: ids, modifiers: .shift, actions)
        XCTAssertEqual(selected, ["a", "b", "d"], "Shift-click selects the range, except photos that can't be")

        cursor.click("b", in: ids, modifiers: .command, actions)
        XCTAssertEqual(selected, ["a", "d"])

        cursor.toggle("a", in: ids, extend: false, actions)
        XCTAssertEqual(selected, ["d"])
    }

    func testShiftClickGoesTheWayOfThePhotoClicked() {
        let ids = ["a", "b", "c", "d", "e"]
        var selected: Set<String> = Set(ids)
        let actions = GridActions(
            isSelected: { selected.contains($0) },
            select: { ids, on in if on { selected.formUnion(ids) } else { selected.subtract(ids) } },
            accept: { _ in }, decline: { _ in }, rotate: { _ in }, open: { _ in }, message: { _ in })
        var cursor = GridCursor()

        cursor.click("a", in: ids, modifiers: [], actions)
        cursor.click("b", in: ids, modifiers: .shift, actions)
        XCTAssertEqual(selected, ["c", "d", "e"], "Shift-clicking a selected photo deselects the range")

        cursor.click("e", in: ids, modifiers: .command, actions)
        XCTAssertEqual(selected, ["c", "d"])
        cursor.click("a", in: ids, modifiers: .shift, actions)
        XCTAssertEqual(selected, Set(ids), "after a ⌘-click deselects, Shift-clicking one not selected still selects")

        cursor.toggle("b", in: ids, extend: false, actions)
        cursor.toggle("d", in: ids, extend: true, actions)
        XCTAssertEqual(selected, ["a", "e"], "Shift-circle on a selected photo deselects the range")
        cursor.toggle("c", in: ids, extend: true, actions)
        XCTAssertEqual(selected, ["a", "e", "c", "d"], "and on one not selected, selects it")
    }
}
