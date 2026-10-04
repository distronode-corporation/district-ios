@testable import DistrictAI
import DistrictModel
import XCTest

/// How a scheduling URL becomes a destination, and who may reach one.
final class SchedulingRoutingTests: XCTestCase {
    private func outcome(_ path: String, query: String = "") -> AppLinkOutcome? {
        AppLinkResolver.resolve(URL(string: "https://www.distronode.com\(path)\(query)")!)
    }

    private func destination(_ path: String) -> AppLinkDestination? {
        guard case let .destination(value) = outcome(path) else { return nil }
        return value
    }

    // MARK: - Resolving

    /// ⛔ THE BARE PATH IS THE HUB, which is where the tenancy card and Enable live.
    func test_IOS_SCHLINK_01_theBarePathCarriesNoSubSection() {
        XCTAssertEqual(destination("/dashboard/district/scheduling")?.section, .scheduling)
        XCTAssertNil(destination("/dashboard/district/scheduling")?.detailId)
    }

    /// ⛔ ALL EIGHT SUB-PATHS RESOLVE. The web publishes seven of them (and `overview` is
    /// the register at its root) and the app draws every one, so sending them to the
    /// hub would show somebody a screen they did not ask for — the exact failure
    /// `openInBrowser` was introduced to stop.
    func test_IOS_SCHLINK_02_allEightSubPathsResolveToTheirSection() {
        let expected: [(String, SchedulingSection)] = [
            ("overview", .overview),
            ("event-types", .eventTypes),
            ("hours", .hours),
            ("bookings", .bookings),
            ("calendar", .calendar),
            ("team", .team),
            ("settings", .settings),
            ("developer", .developer),
        ]
        for (segment, section) in expected {
            let detail = destination("/dashboard/district/scheduling/\(segment)")?.detailId
            XCTAssertEqual(detail, segment, segment)
            XCTAssertEqual(SchedulingSection.forPathSegment(detail), section, segment)
        }
    }

    /// ⛔ THE SEGMENT IS CASE-FOLDED, because a shared link is retyped by humans. A rule
    /// applied to half a path is worse than either rule applied whole: `/Scheduling`
    /// already folded, so the sub-path has to as well.
    func test_IOS_SCHLINK_03_theSubPathIsCaseFolded() {
        XCTAssertEqual(
            destination("/dashboard/district/scheduling/Event-Types")?.detailId,
            "event-types"
        )
        XCTAssertEqual(
            destination("/dashboard/district/SCHEDULING/BOOKINGS")?.detailId,
            "bookings"
        )
    }

    /// ⚠️ AN UNKNOWN SUB-PATH STILL RESOLVES TO THE SCHEDULING SECTION and lands on the
    /// hub, rather than bouncing to a browser. See the ⛔ on
    /// ``SchedulingSection/forPathSegment(_:)``.
    func test_IOS_SCHLINK_04_anUnknownSubPathLandsOnTheHub() {
        XCTAssertEqual(destination("/dashboard/district/scheduling/nope")?.section, .scheduling)
        XCTAssertEqual(
            SchedulingSection.forPathSegment(destination("/dashboard/district/scheduling/nope")?.detailId),
            .hub
        )
    }

    /// ⚠️ ONLY THE SECOND SEGMENT DECIDES IT. A deeper path lands on the section it names.
    func test_IOS_SCHLINK_05_onlyTheSecondSegmentIsRead() {
        XCTAssertEqual(
            destination("/dashboard/district/scheduling/bookings/b_123")?.detailId,
            "bookings"
        )
    }

    /// ⛔ `calls/<id>` IS UNAFFECTED AND KEEPS ITS OPAQUE, UN-FOLDED ID. The scheduling
    /// change lowercases only its own branch; a call id is whatever the API minted and
    /// folding it would address a different row.
    func test_IOS_SCHLINK_06_aCallIdIsStillCarriedVerbatim() {
        XCTAssertEqual(destination("/dashboard/district/calls/CaLl_9")?.detailId, "CaLl_9")
    }

    // MARK: - Becoming a route

    private func route(_ path: String, selected: String?, role: WorkspaceRole?) -> Route? {
        guard let value = destination(path) else { return nil }
        return AppLinkRouting.action(
            for: value,
            selectedWorkspaceId: selected,
            role: role
        ).route
    }

    func test_IOS_SCHLINK_07_aSubPathBecomesItsSectionsRoute() {
        let route = route("/dashboard/district/scheduling/settings", selected: "ws_1", role: .agency)
        guard case let .scheduling(workspaceId, role, section) = route else {
            return XCTFail("expected a scheduling route, got \(String(describing: route))")
        }
        XCTAssertEqual(workspaceId, "ws_1")
        XCTAssertEqual(role, .agency)
        XCTAssertEqual(section, .settings)
    }

    /// ⛔ THE ROLE IS DROPPED FOR A CROSS-TENANT LINK, and the section survives. A link
    /// naming another tenant must not carry the SELECTED workspace's role onto it — which
    /// matters because the sections read that role to decide whether to offer their
    /// writes.
    func test_IOS_SCHLINK_08_aCrossTenantLinkDropsTheRoleAndKeepsTheSection() {
        guard case let .destination(value) = outcome(
            "/dashboard/district/scheduling/settings",
            query: "?workspaceId=ws_2"
        ) else {
            return XCTFail("expected a destination")
        }
        let route = AppLinkRouting.action(
            for: value,
            selectedWorkspaceId: "ws_1",
            role: .agency
        ).route
        guard case let .scheduling(workspaceId, role, section) = route else {
            return XCTFail("expected a scheduling route, got \(String(describing: route))")
        }
        XCTAssertEqual(workspaceId, "ws_2")
        XCTAssertNil(role, "a cross-tenant link must not carry the selected workspace's role")
        XCTAssertEqual(section, .settings)
    }

    /// ⚠️ SCHEDULING HANGS OFF THE OVERVIEW TAB, which is where ``OverviewEntry`` already
    /// offers it. A second way in would let a back swipe land somewhere nobody chose.
    func test_IOS_SCHLINK_09_schedulingLandsOnTheOverviewTab() {
        guard let value = destination("/dashboard/district/scheduling/team") else {
            return XCTFail("expected a destination")
        }
        let action = AppLinkRouting.action(for: value, selectedWorkspaceId: "ws_1", role: .client)
        XCTAssertEqual(action.tab, .overview)
    }

    // MARK: - The gate

    /// ⛔ `.partial` FOR A VIEWER RATHER THAN `.hidden` OR `.none`, AND ALL THREE ARE
    /// MEANINGFUL. `.hidden` would withhold eight screens the server would serve; `.none`
    /// would claim nothing on the surface is gated, which stopped being true when the
    /// write controls arrived.
    func test_IOS_SCHLINK_10_aViewerReachesSchedulingReadOnly() {
        let route = Route.scheduling(workspaceId: "ws_1", role: .viewer, section: .hub)
        guard case .partial = RouteGate.gate(for: route, role: .viewer) else {
            return XCTFail("a viewer must reach scheduling read-only")
        }
    }

    func test_IOS_SCHLINK_11_aMutatorIsNotGated() {
        for role in [WorkspaceRole.agency, .client] {
            let route = Route.scheduling(workspaceId: "ws_1", role: role, section: .hub)
            guard case .none = RouteGate.gate(for: route, role: role) else {
                return XCTFail("\(role) must not be gated on scheduling")
            }
        }
    }

    /// ⛔ A ROLE THAT DID NOT PARSE IS TREATED AS A VIEWER, never as a client.
    func test_IOS_SCHLINK_12_anUnparseableRoleGetsTheReadOnlyGate() {
        let route = Route.scheduling(workspaceId: "ws_1", role: nil, section: .hub)
        guard case .partial = RouteGate.gate(for: route, role: nil) else {
            return XCTFail("a nil role must fail closed to read-only")
        }
    }

    /// ⛔ THE SETTINGS HUB'S SCHEDULING ROW IS NOT HIDDEN FROM A VIEWER. Every read
    /// behind it admits a viewer.
    func test_IOS_SCHLINK_13_theSettingsHubOffersSchedulingToAViewer() {
        let route = Route.workspaceSettings(workspaceId: "ws_1", role: .viewer, section: .scheduling)
        guard case .partial = RouteGate.gate(for: route, role: .viewer) else {
            return XCTFail("the scheduling settings row must be offered to a viewer")
        }
    }

    /// ⚠️ THE OVERVIEW ROW IS PRESENT FOR EVERY ROLE and captioned read-only for a viewer.
    func test_IOS_SCHLINK_14_theOverviewRowIsOfferedToEveryRole() {
        for role in [WorkspaceRole.agency, .client, .viewer] {
            let entries = OverviewEntry.all(workspaceId: "ws_1", role: role)
            XCTAssertTrue(
                entries.contains { $0.title == "Scheduling" },
                "Scheduling must be offered to \(role)"
            )
        }
        let viewerRow = OverviewEntry.all(workspaceId: "ws_1", role: .viewer)
            .first { $0.title == "Scheduling" }
        XCTAssertEqual(viewerRow?.caption, "Read-only")
    }

    /// ⛔ AND THE ROW OPENS THE HUB, not a section. A workspace with no booking page has
    /// nothing in any of the eight, so landing elsewhere would be a screen whose every read
    /// answers `scheduling_not_ready`.
    func test_IOS_SCHLINK_15_theOverviewRowOpensTheHub() {
        let entry = OverviewEntry.all(workspaceId: "ws_1", role: .agency)
            .first { $0.title == "Scheduling" }
        guard case let .route(route) = entry?.target,
              case let .scheduling(_, _, section) = route
        else {
            return XCTFail("expected a scheduling route")
        }
        XCTAssertEqual(section, .hub)
    }
}
