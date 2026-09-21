@testable import DistrictAI
import DistrictModel
import XCTest

/// The list/detail split of a list section's stack, on its own and through ``ShellPaths``.
///
/// ⛔ THE WRITE-BACK TESTS ARE THE POINT OF THIS FILE. A `List` may write its selection
/// back while a column rebuilds; a mapping that answered that write with `[route]` would
/// drop whatever the detail column had pushed, and a dialler or a room is exactly the kind
/// of thing that gets pushed there.
final class ListDetailPathTests: ShellPathsTestCase {
    private var otherCall: Route {
        .callDetail(workspaceId: workspaceId, callId: "call_2")
    }

    private var ticket: Route {
        .deskTicket(workspaceId: workspaceId, role: role, ticketId: "t_1")
    }

    // MARK: - The mapping

    func test_IOS_LISTDETAIL_01_theSelectionIsTheFirstPushAndNothingWhenEmpty() {
        XCTAssertNil(ListDetailPath.selection(in: []))
        XCTAssertEqual(ListDetailPath.selection(in: [call, dialer]), call)
    }

    func test_IOS_LISTDETAIL_02_selectingAnotherRowReplacesTheWholeStack() {
        XCTAssertEqual(ListDetailPath.selecting(otherCall, in: [call, contact, dialer]), [otherCall])
        XCTAssertEqual(ListDetailPath.selecting(call, in: []), [call])
    }

    /// ⛔ WRITING BACK THE ROW THAT IS OPEN KEEPS WHAT IS PUSHED BESIDE IT.
    func test_IOS_LISTDETAIL_03_reselectingTheOpenRowIsANoOp() {
        let path = [call, contact, dialer]
        XCTAssertEqual(ListDetailPath.selecting(call, in: path), path)
    }

    /// ⚠️ AND A nil WRITE IS SwiftUI's, NEVER A PERSON'S, so it leaves the stack alone.
    func test_IOS_LISTDETAIL_04_aNilSelectionLeavesThePathAlone() {
        XCTAssertEqual(ListDetailPath.selecting(nil, in: [call, room]), [call, room])
        XCTAssertEqual(ListDetailPath.selecting(nil, in: []), [])
    }

    func test_IOS_LISTDETAIL_05_theTailRoundTripsUnderTheSelectedRow() {
        let path = [call, contact, room]
        let tail = ListDetailPath.tail(of: path)
        XCTAssertEqual(tail, [contact, room])
        XCTAssertEqual(ListDetailPath.replacingTail(tail, in: path), path)
        XCTAssertEqual(ListDetailPath.replacingTail([dialer], in: path), [call, dialer])
        XCTAssertEqual(ListDetailPath.replacingTail([], in: path), [call])
    }

    /// ⚠️ A TAIL WRITTEN WITH NOTHING SELECTED CANNOT RESURRECT SCREENS.
    func test_IOS_LISTDETAIL_06_aTailWithNoSelectionIsDropped() {
        XCTAssertEqual(ListDetailPath.replacingTail([dialer], in: []), [])
    }

    func test_IOS_LISTDETAIL_07_leavingARowIsANewFirstPushAndNotAPopOrAPush() {
        XCTAssertTrue(ListDetailPath.leftSelection(from: [call], to: [otherCall]))
        XCTAssertTrue(ListDetailPath.leftSelection(from: [call, contact], to: [otherCall]))
        XCTAssertFalse(ListDetailPath.leftSelection(from: [], to: [call]))
        XCTAssertFalse(ListDetailPath.leftSelection(from: [call], to: [call, contact]))
        XCTAssertFalse(ListDetailPath.leftSelection(from: [call, contact], to: [call]))
    }

    func test_IOS_LISTDETAIL_08_exactlyTheFiveListSectionsAreThreeColumns() {
        XCTAssertEqual(
            SidebarItem.allCases.filter(\.isListSection),
            [.inbox, .calls, .contacts, .desk, .support]
        )
    }

    // MARK: - Through the shell's state

    /// ⛔ A ROW SELECTED BESIDE THE LIST, WITH A DIALLER PUSHED ON ITS DETAIL, IS THE TAB'S
    /// STACK ON THE PHONE, AND COMES BACK UNCHANGED.
    func test_IOS_LISTDETAIL_09_aTabSectionsSplitIsItsCompactStack() {
        var paths = seeded()
        paths.setRegularSelection(.calls, workspaceId: workspaceId, role: role)
        paths.setRegularPath(ListDetailPath.selecting(call, in: paths.regularPath(for: .calls)), for: .calls)
        let withDialer = ListDetailPath.replacingTail([dialer], in: paths.regularPath(for: .calls))
        paths.setRegularPath(withDialer, for: .calls)

        rebuildCompact(&paths)
        XCTAssertEqual(paths.compactTab, .calls)
        XCTAssertEqual(paths.compactPath(for: .calls), [call, dialer])

        rebuildRegular(&paths)
        let path = paths.regularPath(for: .calls)
        XCTAssertEqual(ListDetailPath.selection(in: path), call)
        XCTAssertEqual(ListDetailPath.tail(of: path), [dialer])
    }

    /// ⛔ FOR A HUB LIST (THE DESK) THE ROOT IS THE SIDEBAR ROW, SO THE SELECTED TICKET IS
    /// THE FIRST PUSH AFTER IT ON THE PHONE.
    func test_IOS_LISTDETAIL_10_aHubListsSplitIsTheOverviewStackAfterItsRoot() {
        var paths = seeded()
        paths.compactTab = .overview
        paths.setCompactPath([root(.desk), ticket, contact], for: .overview)

        rebuildRegular(&paths)
        XCTAssertEqual(paths.regularSelection, .desk)
        let path = paths.regularPath(for: .desk)
        XCTAssertEqual(ListDetailPath.selection(in: path), ticket)
        XCTAssertEqual(ListDetailPath.tail(of: path), [contact])

        paths.setRegularPath(ListDetailPath.selecting(ticket, in: path), for: .desk)
        rebuildCompact(&paths)
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.desk), ticket, contact])
    }
}
