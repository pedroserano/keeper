import AppKit
import SwiftUI
import XCTest
import DateGuessCore
@testable import DateGuesser

/// Changing the rows of a table or list once crashed. Filtering the People table (the "Missing Birth Year" button) did: its rows read AppState
/// from the environment, which macOS's table rows don't always have yet.
@MainActor
final class PeopleTableTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        setenv("PDG_DATA_DIR", NSTemporaryDirectory() + "PhotoDateGuesserTests-\(UUID().uuidString)", 1)
    }

    func testFilteringRowsDoesNotCrash() {
        let state = AppState()
        state.people = (0..<30).map { PersonInfo(name: "Person \($0)", birthYear: $0.isMultiple(of: 2) ? 1950 + $0 : nil) }
        for missingOnly in [false, true] {
            let view = PeopleView(_onlyMissing: State(initialValue: missingOnly)).environment(state)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.layoutIfNeeded()
            state.people.removeLast(5)
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            window.close()
        }
    }

    func testChangingEventsListDoesNotCrash() {
        let state = AppState()
        state.groups = (0..<10).map { PhotoGroup(name: "Group \($0)", kind: .sameEvent, assetIDs: ["a\($0)", "b\($0)"]) }
        state.eventSuggestions = (0..<10).map { ["x\($0)", "y\($0)"] }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EventsView().environment(state))
        window.layoutIfNeeded()
        state.eventSuggestions.removeFirst(3)
        state.groups.removeLast(4)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.close()
    }
}
