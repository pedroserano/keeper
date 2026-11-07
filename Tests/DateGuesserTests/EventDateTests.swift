import SwiftUI
import XCTest
import DateGuessCore
@testable import DateGuesser

/// Changing a confirmed event's date sets it on every photo still waiting, and checks them.
@MainActor
final class EventDateTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        setenv("PDG_DATA_DIR", NSTemporaryDirectory() + "PhotoDateGuesserTests-\(UUID().uuidString)", 1)
    }

    func testEventDateChangesEveryWaitingPhoto() {
        let state = AppState()
        state.groups = []   // other tests in this run share the data folder
        for id in ["a", "b", "c", "d"] {
            state.scan.undated[id] = UndatedPhoto(id: id, reason: .noCaptureDateInFile, libraryDate: nil, format: FormatInfo(), albums: [])
        }
        // "c" was already applied, "d" is hidden: neither changes.
        state.journal = [ApplyBatch(date: Date(), entries: [JournalEntry(assetID: "c", previousDate: nil, newDate: Date())])]
        state.setIgnored("d", true)
        let group = state.saveEvent(["a", "b", "c", "d"], name: "Picnic", year: 1990, month: nil, season: .summer)
        state.setOverride("b", year: 1991, season: nil)   // one changed on its own

        state.setEventDate(group.id, year: 1987, month: 7, season: nil)
        for id in ["a", "b"] {
            let d = state.decision(id)
            XCTAssertEqual(d.overrideYear, 1987, id)
            XCTAssertEqual(d.overrideMonth, 7, id)
            XCTAssertTrue(d.selected, id)
        }
        XCTAssertNil(state.decision("c").overrideMonth, "already applied")
        XCTAssertNil(state.decision("d").overrideMonth, "hidden")
        XCTAssertEqual(state.groups.first?.hint, "July 1987")

        // Back to the shared guess.
        state.setEventDate(group.id, year: nil, month: nil, season: nil)
        XCTAssertNil(state.decision("a").overrideYear)
        XCTAssertNil(state.decision("a").overrideMonth)
        XCTAssertNil(state.groups.first?.yearFrom)
        XCTAssertEqual(state.groups.first?.hint, "")

        // The user's own notes are kept.
        state.groups[0].hint = "At the lake"
        state.setEventDate(group.id, year: 1988, month: 5, season: nil)
        XCTAssertEqual(state.groups.first?.hint, "At the lake")
    }

    /// Picking only a year still gives every photo of the event the very same date.
    func testYearAloneGivesEveryPhotoOneDate() {
        let state = AppState()
        state.groups = []
        state.journal = []
        for id in ["y1", "y2", "y3"] {
            state.scan.undated[id] = UndatedPhoto(id: id, reason: .noCaptureDateInFile, libraryDate: nil, format: FormatInfo(), albums: [])
        }
        let group = state.saveEvent(["y1", "y2", "y3"], name: "Trip", year: 1990, month: 8, season: nil)
        state.setOverride("y3", year: 1990, season: .winter)   // one drifted to its own season
        state.setMonth("y2", 3)

        state.setEventDate(group.id, year: 1984, month: nil, season: nil)
        let months = Set(["y1", "y2", "y3"].map { state.decision($0).overrideMonth })
        XCTAssertEqual(months.count, 1, "one month for all")
        XCTAssertNotNil(months.first!)
        XCTAssertEqual(Set(["y1", "y2", "y3"].map { state.decision($0).overrideYear }), [1984])
        XCTAssertEqual(Set(["y1", "y2", "y3"].map { state.decision($0).overrideSeason }), [nil], "no season to drift by")

        // Saving an event with only a year does the same.
        let other = state.saveEvent(["y1", "y2"], name: "Again", year: 1975, month: nil, season: nil)
        XCTAssertEqual(state.decision("y1").overrideMonth, state.decision("y2").overrideMonth)
        XCTAssertNotNil(state.decision("y1").overrideMonth)
        _ = other
    }

    /// Photos this app dated and that were moved in Photos afterward are found; kept ones aren't.
    func testFindsDatesChangedInPhotos() {
        let t = Date(timeIntervalSince1970: 300_000_000)
        let journal = [
            ApplyBatch(date: Date(), entries: [JournalEntry(assetID: "p", previousDate: nil, newDate: t)]),
            ApplyBatch(date: Date().addingTimeInterval(-60), entries: [JournalEntry(assetID: "p", previousDate: nil, newDate: t.addingTimeInterval(-9e6)),
                                                                   JournalEntry(assetID: "q", previousDate: nil, newDate: t)]),
            ApplyBatch(date: Date().addingTimeInterval(-120), entries: [JournalEntry(assetID: "r", previousDate: nil, newDate: t)], undone: true),
        ]
        let applied = AppState.appliedDates(journal)
        XCTAssertEqual(applied["p"], t, "the newest date this app set")
        XCTAssertNil(applied["r"], "undone")
        let twoYears = t.addingTimeInterval(-730 * 86400)
        let shifts = AppState.shifts(applied: applied, current: ["p": twoYears, "q": t.addingTimeInterval(1)], kept: [])
        XCTAssertEqual(shifts.map(\.assetID), ["p"], "a second off doesn't count")
        XCTAssertEqual(shifts.first?.days, -730)
        XCTAssertEqual(HistoryView.amount(-730), "2 years earlier")
        XCTAssertEqual(HistoryView.amount(61), "61 days later")
        XCTAssertTrue(AppState.shifts(applied: applied, current: ["p": twoYears], kept: [shifts[0].keepKey]).isEmpty)
    }

    /// Photos already dated here drop out of the scan after a rescan, but the event's grid must
    /// still show them (it once showed nothing for such events).
    func testEventGridShowsPhotosNoLongerInTheScan() {
        let state = AppState()
        let grid = PhotoGrid(ids: ["gone-1", "gone-2", "gone-3"], selected: .constant([]))
        let host = NSHostingController(rootView: grid.environment(state).frame(width: 400))
        XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 400, height: 2000)).height, 50)
    }

    /// Undoing one event's applied dates puts back only those photos; the rest of the batch stays.
    func testUndoingSomePhotosOfABatch() {
        let state = AppState()
        let first = Date(timeIntervalSince1970: 0), later = Date(timeIntervalSince1970: 1000)
        var batch = ApplyBatch(date: Date(), entries: [
            JournalEntry(assetID: "x", previousDate: first, newDate: later),
            JournalEntry(assetID: "y", previousDate: first, newDate: later)])
        batch.undoneIDs = ["x"]
        state.journal = [batch]
        XCTAssertEqual(state.appliedIDs, ["y"])
        XCTAssertTrue(state.liveEntries("x").isEmpty)
        XCTAssertEqual(state.liveEntries("y").map(\.newDate), [later])

        // A second change stacks on the first; the original date is the oldest entry's.
        state.journal.insert(ApplyBatch(date: Date(), entries: [JournalEntry(assetID: "y", previousDate: later, newDate: first)]), at: 0)
        XCTAssertEqual(state.liveEntries("y").first?.previousDate, first)
        XCTAssertEqual(state.liveEntries("y").last?.newDate, first)

        let d = AppState.appliedDate(year: 1987, month: 7)!
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: d)
        XCTAssertEqual([c.year, c.month, c.day, c.hour], [1987, 7, 1, 12])
    }

    /// The window for a confirmed event has the event's date controls, including for applied photos.
    func testEventWindowShowsDateControls() {
        let state = AppState()
        let group = PhotoGroup(name: "Applied event", kind: .sameEvent, assetIDs: ["p1", "p2"])
        state.groups = [group]
        state.journal = [ApplyBatch(date: Date(), entries: ["p1", "p2"].map {
            JournalEntry(assetID: $0, previousDate: nil, newDate: AppState.appliedDate(year: 1985, month: 6)!)
        })]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GroupEditor(groupID: group.id).environment(state))
        window.layoutIfNeeded()
        func boxes(_ v: NSView) -> [NSComboBox] { ((v as? NSComboBox).map { [$0] } ?? []) + v.subviews.flatMap(boxes) }
        XCTAssertEqual(boxes(window.contentView!).first?.stringValue, "1985")
        window.close()
    }

    /// After Cancel, the year box shows the event's year again even though it still has focus.
    func testYearBoxResetsAfterCancel() {
        final class Holder: ObservableObject { @Published var reset = 0 }
        let holder = Holder()
        struct Box: View {
            @ObservedObject var holder: Holder
            var body: some View { YearComboBox(year: 2002, range: 1900...2026, reset: holder.reset) { _ in } }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Box(holder: holder))
        window.layoutIfNeeded()
        func box(_ v: NSView) -> NSComboBox? { (v as? NSComboBox) ?? v.subviews.lazy.compactMap(box).first }
        let combo = box(window.contentView!)!
        window.makeFirstResponder(combo)
        combo.currentEditor()?.string = "1987"
        combo.stringValue = "1987"
        holder.reset += 1
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        XCTAssertEqual(combo.stringValue, "2002")
        window.close()
    }
}

