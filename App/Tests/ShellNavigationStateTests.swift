@testable import DistrictAI
import DistrictModel
import XCTest

/// The shell's one navigation state, read and written through both layouts' projections.
///
/// ⛔ THE FLIP TESTS ARE THE POINT OF THIS FILE. A rotation or a Split View resize can
/// swap the tab bar for the sidebar at any moment, and the dialler's in-call controls and
/// a meeting's controls live on pushed routes. Every assertion below that a stack
/// survives a flip is an assertion that a live call keeps its hang-up button.
final class ShellNavigationStateTests: ShellPathsTestCase {
    // MARK: - Layout flips

    /// ⛔ REGULAR → COMPACT, FOR EVERY HUB SECTION: the sidebar's row becomes the first
    /// push on the Overview tab, with its stack on top.
    func test_IOS_NAV_01_aHubOpenInRegularIsTheOverviewStackInCompact() {
        for hub in hubItems {
            var paths = seeded()
            paths.setRegularSelection(hub, workspaceId: workspaceId, role: role)
            paths.setRegularPath([call], for: hub)
            XCTAssertEqual(paths.compactTab, .overview, "\(hub)")
            XCTAssertEqual(paths.compactPath(for: .overview), [root(hub), call], "\(hub)")
        }
    }

    /// ⛔ COMPACT → REGULAR, FOR EVERY HUB SECTION: the first push becomes the selected
    /// row and the rest becomes its stack.
    func test_IOS_NAV_02_aHubPushedInCompactIsASelectedRowInRegular() {
        for hub in hubItems {
            var paths = seeded()
            paths.compactTab = .overview
            paths.setCompactPath([root(hub), contact], for: .overview)
            XCTAssertEqual(paths.regularSelection, hub, "\(hub)")
            XCTAssertEqual(paths.regularPath(for: hub), [contact], "\(hub)")
            XCTAssertEqual(paths.regularPath(for: .overview), [], "\(hub)")
        }
    }

    /// ⛔ AND BACK AGAIN UNCHANGED, with each layout's rebuild writing its bindings back.
    func test_IOS_NAV_03_everyHubRoundTripsRegularCompactRegular() {
        for hub in hubItems {
            var paths = seeded()
            paths.setRegularSelection(hub, workspaceId: workspaceId, role: role)
            paths.setRegularPath([call, contact], for: hub)
            rebuildCompact(&paths)
            rebuildRegular(&paths)
            XCTAssertEqual(paths.regularSelection, hub, "\(hub)")
            XCTAssertEqual(paths.regularPath(for: hub), [call, contact], "\(hub)")
            XCTAssertEqual(paths.compactPath(for: .overview), [root(hub), call, contact], "\(hub)")
        }
    }

    /// ⛔ A LIVE DIALLER DEEP IN A TAB'S STACK SURVIVES regular → compact → regular.
    func test_IOS_NAV_04_theDialerDeepInAStackSurvivesAFlip() {
        var paths = seeded()
        paths.setRegularSelection(.calls, workspaceId: workspaceId, role: role)
        paths.setRegularPath([call, dialer], for: .calls)
        rebuildCompact(&paths)
        XCTAssertEqual(paths.compactTab, .calls)
        XCTAssertEqual(paths.compactPath(for: .calls), [call, dialer])
        rebuildRegular(&paths)
        XCTAssertEqual(paths.regularSelection, .calls)
        XCTAssertEqual(paths.regularPath(for: .calls), [call, dialer])
    }

    /// ⛔ AND THE DIALLER OPENED AS ITS OWN SECTION survives too, in both directions.
    func test_IOS_NAV_05_theDialerSectionSurvivesAFlipBothWays() {
        var paths = seeded()
        paths.compactTab = .overview
        paths.setCompactPath([root(.dialer)], for: .overview)
        rebuildRegular(&paths)
        XCTAssertEqual(paths.regularSelection, .dialer)
        rebuildCompact(&paths)
        XCTAssertEqual(paths.compactTab, .overview)
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.dialer)])
    }

    /// ⛔ A LIVE ROOM SURVIVES, whether it was joined from the Rooms section or from a
    /// contact on another tab.
    func test_IOS_NAV_06_anActiveRoomDeepInAStackSurvivesAFlip() {
        var paths = seeded()
        paths.setRegularSelection(.rooms, workspaceId: workspaceId, role: role)
        paths.setRegularPath([room], for: .rooms)
        paths.setRegularPath([contact, room], for: .contacts)
        rebuildCompact(&paths)
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.rooms), room])
        XCTAssertEqual(paths.compactPath(for: .contacts), [contact, room])
        rebuildRegular(&paths)
        XCTAssertEqual(paths.regularSelection, .rooms)
        XCTAssertEqual(paths.regularPath(for: .rooms), [room])
        XCTAssertEqual(paths.regularPath(for: .contacts), [contact, room])
    }

    /// ⛔ WRITING BACK WHAT WAS READ CHANGES NOTHING, in either layout and from any state,
    /// including the Overview row's own stack hidden behind an open hub on compact width.
    func test_IOS_NAV_24_aRebuildOfEitherLayoutIsANoOp() {
        var paths = seeded()
        paths.setRegularSelection(.overview, workspaceId: workspaceId, role: role)
        paths.setRegularPath([call], for: .overview)
        paths.setRegularSelection(.billing, workspaceId: workspaceId, role: role)
        paths.setRegularPath([contact], for: .billing)
        paths.setRegularPath([room], for: .contacts)
        paths.setRegularPath([dialer], for: .calls)
        let before = snapshot(paths)
        rebuildCompact(&paths)
        XCTAssertEqual(snapshot(paths), before)
        rebuildRegular(&paths)
        XCTAssertEqual(snapshot(paths), before)
        paths.setRegularSelection(.overview, workspaceId: workspaceId, role: role)
        XCTAssertEqual(paths.regularPath(for: .overview), [call])
    }

    /// ⛔ THE HUB ROOT IS KEPT AS PUSHED. Re-selecting the open section with a refreshed
    /// role must not rewrite the bottom of a live stack.
    func test_IOS_NAV_07_reselectingTheOpenHubKeepsItsRootAsPushed() {
        var paths = seeded()
        paths.setRegularSelection(.billing, workspaceId: workspaceId, role: .agency)
        paths.setRegularPath([call], for: .billing)
        paths.setRegularSelection(.billing, workspaceId: workspaceId, role: .viewer)
        XCTAssertEqual(paths.overviewHubRoot, root(.billing, role: .agency))
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.billing, role: .agency), call])
    }

    // MARK: - Compact behaviour

    /// ⛔ BACKING OUT OF A HUB TO THE DASHBOARD DISCARDS THE HUB'S STACK, as it does on a
    /// phone, and opening it again lands on its root.
    func test_IOS_NAV_08_aCompactPopToTheDashboardClosesTheHubAndClearsItsStack() {
        var paths = seeded()
        paths.compactTab = .overview
        paths.setCompactPath([root(.billing), call], for: .overview)
        paths.setCompactPath([], for: .overview)
        XCTAssertNil(paths.overviewHubRoot)
        XCTAssertEqual(paths.regularSelection, .overview)
        XCTAssertEqual(paths.regularPath(for: .billing), [])
        XCTAssertEqual(paths.compactPath(for: .overview), [])
        paths.setCompactPath([root(.billing)], for: .overview)
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.billing)])
    }

    /// ⚠️ A POP WITHIN THE HUB KEEPS IT OPEN.
    func test_IOS_NAV_09_aCompactPopWithinTheHubKeepsItOpen() {
        var paths = seeded()
        paths.compactTab = .overview
        paths.setCompactPath([root(.desk), call, contact], for: .overview)
        paths.setCompactPath([root(.desk)], for: .overview)
        XCTAssertEqual(paths.regularSelection, .desk)
        XCTAssertEqual(paths.regularPath(for: .desk), [])
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.desk)])
    }

    /// ⛔ EACH TAB KEEPS ITS PLACE: switching away from an open hub and back reopens it.
    func test_IOS_NAV_10_switchingCompactTabsPreservesTheOpenHub() {
        var paths = seeded()
        paths.compactTab = .overview
        paths.setCompactPath([root(.billing), call], for: .overview)
        paths.compactTab = .inbox
        XCTAssertEqual(paths.regularSelection, .inbox)
        XCTAssertEqual(paths.overviewHubRoot, root(.billing))
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.billing), call])
        paths.compactTab = .overview
        XCTAssertEqual(paths.regularSelection, .billing)
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.billing), call])
    }

    /// ⚠️ A WRITE TO A TAB NOBODY IS LOOKING AT DOES NOT CHANGE WHICH TAB IS SHOWING.
    func test_IOS_NAV_11_aWriteToAHiddenOverviewDoesNotMoveTheSelection() {
        var paths = seeded()
        paths.compactTab = .inbox
        paths.setCompactPath([root(.billing)], for: .overview)
        XCTAssertEqual(paths.compactTab, .inbox)
        XCTAssertEqual(paths.regularSelection, .inbox)
        paths.compactTab = .overview
        XCTAssertEqual(paths.regularSelection, .billing)
    }

    /// ⚠️ A DASHBOARD PUSH IS THE OVERVIEW'S OWN STACK, NOT A HUB.
    func test_IOS_NAV_12_aNonHubPushOnTheOverviewStaysOnTheOverview() {
        var paths = seeded()
        paths.compactTab = .overview
        paths.setCompactPath([call, dialer], for: .overview)
        XCTAssertNil(paths.overviewHubRoot)
        XCTAssertEqual(paths.regularSelection, .overview)
        XCTAssertEqual(paths.regularPath(for: .overview), [call, dialer])
        XCTAssertEqual(paths.regularPath(for: .dialer), [])
    }

    // MARK: - Regular behaviour

    /// ⚠️ SELECTING THE OVERVIEW ROW SHOWS THE DASHBOARD IN BOTH LAYOUTS, and the hub it
    /// left keeps its stack for the next time its row is selected.
    func test_IOS_NAV_13_selectingTheOverviewRowKeepsTheHubsStack() {
        var paths = seeded()
        paths.setRegularSelection(.billing, workspaceId: workspaceId, role: role)
        paths.setRegularPath([call], for: .billing)
        paths.setRegularSelection(.overview, workspaceId: workspaceId, role: role)
        XCTAssertEqual(paths.compactTab, .overview)
        XCTAssertEqual(paths.compactPath(for: .overview), [])
        XCTAssertEqual(paths.regularPath(for: .billing), [call])
        paths.setRegularSelection(.billing, workspaceId: workspaceId, role: role)
        XCTAssertEqual(paths.regularPath(for: .billing), [call])
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.billing), call])
    }

    /// ⚠️ EVERY ROW KEEPS ITS OWN STACK, LIKE A TAB.
    func test_IOS_NAV_14_regularRowsKeepIndependentStacks() {
        var paths = seeded()
        paths.setRegularSelection(.desk, workspaceId: workspaceId, role: role)
        paths.setRegularPath([call], for: .desk)
        paths.setRegularSelection(.support, workspaceId: workspaceId, role: role)
        paths.setRegularPath([contact], for: .support)
        paths.setRegularSelection(.desk, workspaceId: workspaceId, role: role)
        XCTAssertEqual(paths.regularPath(for: .desk), [call])
        XCTAssertEqual(paths.regularPath(for: .support), [contact])
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.desk), call])
    }
}
