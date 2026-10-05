@testable import DistrictAI
import DistrictModel
import XCTest

/// Where a push or a link lands, and what a workspace switch clears.
///
/// ⛔ ``ShellPaths/apply(_:)`` IS THE PURE HALF OF THE SHELL'S ONE MOVER, so every landing
/// is pinned here in both layouts' terms rather than left to a device run.
final class ShellLandingTests: ShellPathsTestCase {
    // MARK: - The tenant

    /// ⛔ A SWITCH CLEARS EVERY ITEM, the hub sections included, and the open hub's root,
    /// which carries the previous tenant's id.
    func test_IOS_NAV_15_resetClearsEveryItemAndTheHubRoot() {
        var paths = seeded()
        for item in SidebarItem.allCases {
            paths.setRegularPath([call], for: item)
        }
        paths.setRegularSelection(.billing, workspaceId: workspaceId, role: role)
        paths.reset(to: "ws_2")
        for item in SidebarItem.allCases {
            XCTAssertEqual(paths.regularPath(for: item), [], "\(item)")
        }
        for tab in Tab.allCases {
            XCTAssertEqual(paths.compactPath(for: tab), [], "\(tab)")
        }
        XCTAssertNil(paths.overviewHubRoot)
        XCTAssertEqual(paths.regularSelection, .overview)
    }

    /// ⚠️ A TAB SELECTION SURVIVES A SWITCH: the tab root reads the new
    /// tenant on its own.
    func test_IOS_NAV_16_resetKeepsATabSelection() {
        var paths = seeded()
        paths.compactTab = .inbox
        paths.reset(to: "ws_2")
        XCTAssertEqual(paths.regularSelection, .inbox)
    }

    /// ⛔ `adopt`: the first id seeds, nil is the middle of a switch, the same
    /// id is a reload, and only a different id clears.
    func test_IOS_NAV_17_adoptSeedsIgnoresNilAndTheSameIdAndResetsOnANewOne() {
        var paths = ShellPaths()
        paths.setRegularPath([.devices], for: .account)
        paths.adopt(workspaceId)
        XCTAssertEqual(paths.regularPath(for: .account), [.devices], "the first id seeds")
        paths.adopt(nil)
        XCTAssertEqual(paths.regularPath(for: .account), [.devices], "nil is a no-op")
        paths.adopt(workspaceId)
        XCTAssertEqual(paths.regularPath(for: .account), [.devices], "a reload is not a switch")
        paths.adopt("ws_2")
        XCTAssertEqual(paths.regularPath(for: .account), [], "a new id clears")
    }

    // MARK: - Landing

    /// ⛔ A HUB ROOT OPENS ITS HUB WITH NOTHING PUSHED, and resets a stack it had.
    func test_IOS_NAV_18_applyingAHubRootOpensItWithAnEmptyStack() {
        var paths = seeded()
        paths.setRegularSelection(.analytics, workspaceId: workspaceId, role: role)
        paths.setRegularPath([call], for: .analytics)
        paths.compactTab = .inbox
        let analytics = Route.analytics(workspaceId: workspaceId)
        paths.apply(PushRouteAction(tab: .overview, selectWorkspaceId: nil, route: analytics))
        XCTAssertEqual(paths.regularSelection, .analytics)
        XCTAssertEqual(paths.overviewHubRoot, analytics)
        XCTAssertEqual(paths.regularPath(for: .analytics), [])
        XCTAssertEqual(paths.compactTab, .overview)
        XCTAssertEqual(paths.compactPath(for: .overview), [analytics])
    }

    /// ⛔ A ROUTE A HUB OWNS LANDS ON THAT HUB'S FRESH ROOT: a scheduling section has the
    /// scheduling hub beneath it, not the dashboard.
    func test_IOS_NAV_19_applyingAnOwnedRouteOpensItsHubBeneathIt() {
        var paths = seeded()
        let bookings = Route.scheduling(workspaceId: workspaceId, role: role, section: .bookings)
        paths.apply(PushRouteAction(tab: .overview, selectWorkspaceId: nil, route: bookings))
        XCTAssertEqual(paths.regularSelection, .scheduling)
        XCTAssertEqual(paths.regularPath(for: .scheduling), [bookings])
        XCTAssertEqual(paths.compactTab, .overview)
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.scheduling), bookings])
    }

    /// ⛔ AND THE HUB IS THE ROUTE'S TENANT'S, not the one on screen.
    func test_IOS_NAV_20_anOwnedRouteForAnotherTenantOpensThatTenantsHub() {
        var paths = seeded()
        let ticket = Route.deskTicket(workspaceId: "ws_2", role: nil, ticketId: "t_1")
        paths.reset(to: "ws_2")
        paths.apply(PushRouteAction(tab: .overview, selectWorkspaceId: "ws_2", route: ticket))
        XCTAssertEqual(paths.regularSelection, .desk)
        XCTAssertEqual(paths.compactPath(for: .overview), [.desk(workspaceId: "ws_2", role: nil), ticket])
    }

    /// ⚠️ A TAB'S OWN ROUTE LANDS ON THAT TAB, and leaves the Overview's open hub alone.
    func test_IOS_NAV_21_applyingATabRouteLandsOnTheTab() {
        var paths = seeded()
        paths.compactTab = .overview
        paths.setCompactPath([root(.billing), contact], for: .overview)
        paths.setRegularPath([contact], for: .calls)
        paths.apply(PushRouteAction(tab: .calls, selectWorkspaceId: nil, route: call))
        XCTAssertEqual(paths.regularSelection, .calls)
        XCTAssertEqual(paths.regularPath(for: .calls), [call])
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.billing), contact])
    }

    /// ⚠️ NO ROUTE RESETS THE TAB TO ITS ROOT, and on the Overview that closes the hub.
    func test_IOS_NAV_22_applyingNoRouteResetsTheTabToItsRoot() {
        var paths = seeded()
        paths.setRegularPath([contact], for: .inbox)
        paths.apply(PushRouteAction(tab: .inbox, selectWorkspaceId: nil))
        XCTAssertEqual(paths.regularSelection, .inbox)
        XCTAssertEqual(paths.regularPath(for: .inbox), [])

        paths.compactTab = .overview
        paths.setCompactPath([root(.billing), call], for: .overview)
        paths.apply(PushRouteAction(tab: .overview, selectWorkspaceId: nil))
        XCTAssertEqual(paths.regularSelection, .overview)
        XCTAssertNil(paths.overviewHubRoot)
        XCTAssertEqual(paths.compactPath(for: .overview), [])
    }

    /// ⛔ A LINK TO A HUB-OWNED ROUTE LANDS ON THAT HUB, end to end through ``AppLinkRouting``.
    func test_IOS_NAV_23_aSchedulingSectionLinkLandsWithTheHubBeneathIt() throws {
        let url = try XCTUnwrap(URL(string: "https://www.distronode.com/dashboard/district/scheduling/bookings"))
        guard case let .destination(destination) = AppLinkResolver.resolve(url) else {
            return XCTFail("expected a destination")
        }
        let action = AppLinkRouting.action(for: destination, selectedWorkspaceId: workspaceId, role: role)
        var paths = seeded()
        paths.apply(action)
        let bookings = Route.scheduling(workspaceId: workspaceId, role: role, section: .bookings)
        XCTAssertEqual(paths.compactTab, .overview)
        XCTAssertEqual(paths.compactPath(for: .overview), [root(.scheduling), bookings])
        XCTAssertEqual(paths.regularSelection, .scheduling)
        XCTAssertEqual(paths.regularPath(for: .scheduling), [bookings])
    }

    /// ⛔ A STUDIO AREA LINK LANDS ON ITS SETTINGS SCREEN WITH THE HUB BENEATH IT, end to
    /// end through ``AppLinkRouting``, and the bare Studio link opens the hub alone.
    func test_IOS_NAV_24_aStudioAreaLinkLandsWithTheSettingsHubBeneathIt() throws {
        let url = try XCTUnwrap(URL(string: "https://www.distronode.com/dashboard/district/studio/knowledge"))
        guard case let .destination(destination) = AppLinkResolver.resolve(url) else {
            return XCTFail("expected a destination")
        }
        var paths = seeded()
        paths.apply(AppLinkRouting.action(for: destination, selectedWorkspaceId: workspaceId, role: role))
        let hub = Route.workspaceSettings(workspaceId: workspaceId, role: role, section: .hub)
        let knowledge = Route.workspaceSettings(workspaceId: workspaceId, role: role, section: .knowledge)
        XCTAssertEqual(paths.compactTab, .overview)
        XCTAssertEqual(paths.compactPath(for: .overview), [hub, knowledge])
    }

    func test_IOS_NAV_25_theBareStudioLinkOpensTheSettingsHub() throws {
        let url = try XCTUnwrap(URL(string: "https://www.distronode.com/dashboard/district/studio"))
        guard case let .destination(destination) = AppLinkResolver.resolve(url) else {
            return XCTFail("expected a destination")
        }
        var paths = seeded()
        paths.apply(AppLinkRouting.action(for: destination, selectedWorkspaceId: workspaceId, role: role))
        let hub = Route.workspaceSettings(workspaceId: workspaceId, role: role, section: .hub)
        XCTAssertEqual(paths.compactTab, .overview)
        XCTAssertEqual(paths.compactPath(for: .overview), [hub])
    }
}
