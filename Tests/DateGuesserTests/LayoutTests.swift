import AppKit
import SwiftUI
import XCTest
import DateGuessCore
@testable import DateGuesser

/// If a step screen needs more width than the window leaves beside the sidebar, macOS collapses the
/// sidebar and there's no way back to the other steps. These tests keep every screen narrow enough.
@MainActor
final class LayoutTests: XCTestCase {
    let maxWidth = ContentView.detailMinWidth

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "PhotoDateGuesserTests-\(UUID().uuidString)"
        setenv("PDG_DATA_DIR", dir, 1)
    }

    func requiredWidth<V: View>(_ view: V, state: AppState) -> CGFloat {
        let host = NSHostingController(rootView: view.environment(state))
        return host.sizeThatFits(in: CGSize(width: maxWidth, height: 3000)).width
    }

    func assertFits<V: View>(_ name: String, _ view: V, state: AppState? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        let width = requiredWidth(view, state: state ?? AppState())
        XCTAssertLessThanOrEqual(width, maxWidth + 0.5, "\(name) needs \(Int(width)) pt but only \(Int(maxWidth)) pt is guaranteed",
                                 file: file, line: line)
    }

    func testStepsFitBesideSidebar() {
        assertFits("People", PeopleView())
        assertFits("Cameras", CamerasView())
        assertFits("Events", EventsView())
        assertFits("Review", ReviewView())
        assertFits("History", HistoryView())
        assertFits("Scan settings", ScanSettingsView())
    }

    func testGroupSheetFits() {
        let state = AppState()
        let group = PhotoGroup(name: "Grandma and Grandpa’s 50th anniversary party at the lake house",
                               hint: "Probably the summer of 1978, everyone is there")
        state.groups = [group]
        assertFits("Group editor", GroupEditor(groupID: group.id), state: state)
        assertFits("Events with a saved group", EventsView(), state: state)
    }

    /// A Review card's photo must fit its grid column; when it overflowed, it covered the next
    /// column and swallowed clicks on that card's checkbox and menus.
    func testReviewThumbnailFitsNarrowColumn() {
        let host = NSHostingController(rootView: AssetThumbnail(assetID: "x", side: .infinity, height: 180).frame(width: 220))
        XCTAssertLessThanOrEqual(host.sizeThatFits(in: CGSize(width: 220, height: 400)).width, 220.5)
    }

    func testWindowLeavesRoomForSidebarAndSteps() {
        // Window minimum (1020) must hold the sidebar's ideal width (220, checked at 240) plus the detail minimum.
        XCTAssertLessThanOrEqual(240 + maxWidth, 1020)
    }
}
