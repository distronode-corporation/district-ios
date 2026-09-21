@testable import DistrictAI
import DistrictModel
import XCTest

/// The sidebar vocabulary: which items a role is offered, what each one opens on, and
/// which hub section every ``Route`` belongs under.
///
/// ⛔ THE GATING ASSERTIONS ARE CHECKED AGAINST ``RouteGate`` DIRECTLY, NOT AGAINST THE
/// SAME DERIVATION THE CODE USES. The sidebar is built from ``OverviewEntry``'s list; a
/// test that rebuilt it the same way would pass whatever that list said.
final class SidebarItemTests: XCTestCase {
    private let workspaceId = "ws_1"

    /// Every role the client can hold, plus nil (a role that did not parse).
    private let roles: [WorkspaceRole?] = WorkspaceRole.allCases.map { Optional($0) } + [nil]

    private let tabItems: [SidebarItem] = [.overview, .inbox, .calls, .contacts, .account]

    private var hubItems: [SidebarItem] {
        SidebarItem.allCases.filter { $0.tab == nil }
    }

    // MARK: - Tabs

    func test_IOS_SIDEBAR_01_everyTabIsAnItemAndRoundTrips() {
        for tab in Tab.allCases {
            XCTAssertEqual(SidebarItem(tab: tab).tab, tab, "\(tab)")
        }
        XCTAssertEqual(SidebarItem.allCases.filter { $0.tab != nil }, tabItems)
    }

    /// ⛔ ELEVEN HUB SECTIONS, one per `.route` row on the Overview.
    func test_IOS_SIDEBAR_02_theHubSectionsAreTheOverviewsRouteRows() {
        XCTAssertEqual(
            hubItems,
            [
                .hq, .analytics, .marketplace, .billing, .rooms, .workflows, .desk, .dialer,
                .scheduling, .support, .settings,
            ]
        )
    }

    // MARK: - Roots

    /// ⛔ A TAB HAS NO ROOT ROUTE and every hub section has one that maps back to it.
    func test_IOS_SIDEBAR_03_rootRouteRoundTripsThroughHubItem() {
        for role in roles {
            for item in tabItems {
                XCTAssertNil(item.rootRoute(workspaceId: workspaceId, role: role), "\(item)")
            }
            for item in hubItems {
                guard let root = item.rootRoute(workspaceId: workspaceId, role: role) else {
                    XCTFail("\(item) has no root")
                    continue
                }
                XCTAssertEqual(SidebarItem.hubItem(forRoot: root), item, "\(item)")
                XCTAssertEqual(SidebarItem.owner(of: root), item, "\(item)")
                XCTAssertEqual(SidebarItem.ownerRoot(of: root), root, "\(item)")
            }
        }
    }

    /// ⛔ THE SIDEBAR OPENS EACH SECTION ON THE ROUTE THE OVERVIEW PUSHES FOR IT. Two roots
    /// for one section would put different screens at the bottom of its stack depending on
    /// which layout opened it.
    func test_IOS_SIDEBAR_04_everyOverviewRouteRowIsAHubRootWithTheSameRoute() {
        for role in roles {
            for entry in OverviewEntry.all(workspaceId: workspaceId, role: role) {
                guard case let .route(route) = entry.target else { continue }
                guard let item = SidebarItem.hubItem(forRoot: route) else {
                    XCTFail("\(entry.title) is not a hub root for \(String(describing: role))")
                    continue
                }
                XCTAssertEqual(item.rootRoute(workspaceId: workspaceId, role: role), route, entry.title)
            }
        }
    }

    /// ⛔ A SECTION OF A HUB IS NOT ITS ROOT. Treating one as a root would open the hub
    /// with the section at the bottom of its stack, and a back press would skip the hub.
    func test_IOS_SIDEBAR_05_aHubSectionIsNotARoot() {
        let bookings = Route.scheduling(workspaceId: workspaceId, role: .agency, section: .bookings)
        let members = Route.workspaceSettings(workspaceId: workspaceId, role: .agency, section: .members)
        XCTAssertNil(SidebarItem.hubItem(forRoot: bookings))
        XCTAssertNil(SidebarItem.hubItem(forRoot: members))
        XCTAssertEqual(SidebarItem.owner(of: bookings), .scheduling)
        XCTAssertEqual(SidebarItem.owner(of: members), .settings)
    }

    // MARK: - Owners

    /// ⛔ EVERY ROUTE CASE HAS AN ANSWER, AND A NEW CASE CANNOT COMPILE HERE WITHOUT ONE.
    /// See ``expectation(for:)``.
    func test_IOS_SIDEBAR_06_everyRouteHasTheExpectedOwnerAndRootness() {
        XCTAssertEqual(
            Set(Self.everyRoute.map { expectation(for: $0).name }).count,
            Self.routeCaseCount,
            "everyRoute must hold at least one sample of every Route case"
        )
        for route in Self.everyRoute {
            let expected = expectation(for: route)
            XCTAssertEqual(SidebarItem.owner(of: route), expected.owner, "\(route)")
            XCTAssertEqual(SidebarItem.hubItem(forRoot: route), expected.isRoot ? expected.owner : nil, "\(route)")
            // ⚠️ The owner's root must be a ROOT of that owner, or a landing would open the
            // hub on a screen that is not its bottom.
            let root = SidebarItem.ownerRoot(of: route)
            XCTAssertEqual(root.flatMap { SidebarItem.hubItem(forRoot: $0) }, expected.owner, "\(route)")
        }
    }

    /// ⛔ THE OWNER'S ROOT CARRIES THE ROUTE'S OWN TENANT AND ROLE, never the selected
    /// workspace's. A link to another tenant's ticket must open that tenant's desk.
    func test_IOS_SIDEBAR_07_theOwnerRootCarriesTheRoutesOwnTenantAndRole() {
        XCTAssertEqual(
            SidebarItem.ownerRoot(of: .deskTicket(workspaceId: "ws_2", role: .client, ticketId: "t_1")),
            .desk(workspaceId: "ws_2", role: .client)
        )
        XCTAssertEqual(
            SidebarItem.ownerRoot(of: .scheduling(workspaceId: "ws_2", role: nil, section: .booking(id: "b_1"))),
            .scheduling(workspaceId: "ws_2", role: nil, section: .hub)
        )
        XCTAssertEqual(
            SidebarItem.ownerRoot(of: .activeRoom(workspaceId: "ws_2", role: .viewer, roomName: "meet_ws_2_a")),
            .rooms(workspaceId: "ws_2", role: .viewer)
        )
        XCTAssertEqual(
            SidebarItem.ownerRoot(of: .workspaceSettings(workspaceId: "ws_2", role: .agency, section: .members)),
            .workspaceSettings(workspaceId: "ws_2", role: .agency, section: .hub)
        )
        XCTAssertEqual(
            SidebarItem.ownerRoot(of: .supportRequest(workspaceId: "ws_2", role: .client, key: "DA-1")),
            .support(workspaceId: "ws_2", role: .client)
        )
    }

    // MARK: - Visibility

    /// ⛔ A HUB SECTION IS OFFERED EXACTLY WHEN ``RouteGate`` DOES NOT HIDE ITS ROOT, the
    /// tabs are offered to everyone, and the order is the declared sidebar order.
    func test_IOS_SIDEBAR_08_visibleMatchesRouteGateForEveryRole() {
        for role in roles {
            let expected = SidebarItem.allCases.filter { item in
                guard let root = item.rootRoute(workspaceId: workspaceId, role: role) else { return true }
                if case .hidden = RouteGate.gate(for: root, role: role) {
                    return false
                }
                return true
            }
            XCTAssertEqual(
                SidebarItem.visible(workspaceId: workspaceId, role: role),
                expected,
                String(describing: role)
            )
        }
    }

    /// ⛔ THE SAME ROWS AS THE OVERVIEW'S COLUMN, AND WITH THE SAME GATE. The sidebar must
    /// not offer a role a section the Overview hides, or caption one differently.
    func test_IOS_SIDEBAR_09_theHubRowsAndGatesMatchTheOverview() {
        for role in roles {
            let overview = OverviewEntry.all(workspaceId: workspaceId, role: role).compactMap(sidebarEntry)
            let hubs = SidebarItem.entries(workspaceId: workspaceId, role: role).filter { $0.item.tab == nil }
            XCTAssertEqual(hubs, overview, String(describing: role))
        }
    }

    private func sidebarEntry(_ entry: OverviewEntry) -> SidebarEntry? {
        guard case let .route(route) = entry.target, let item = SidebarItem.hubItem(forRoot: route) else {
            return nil
        }
        return SidebarEntry(item: item, gate: entry.gate)
    }

    /// Pinned literally, so a gate change on either side is a deliberate edit here.
    func test_IOS_SIDEBAR_10_theViewerAndNilRoleLists() {
        let readOnly: [SidebarItem] = [
            .overview, .inbox, .calls, .contacts, .hq, .analytics, .marketplace, .billing, .rooms,
            .workflows, .scheduling, .settings, .account,
        ]
        XCTAssertEqual(SidebarItem.visible(workspaceId: workspaceId, role: .viewer), readOnly)
        XCTAssertEqual(SidebarItem.visible(workspaceId: workspaceId, role: nil), readOnly)
        for role in [WorkspaceRole.agency, .client] {
            XCTAssertEqual(SidebarItem.visible(workspaceId: workspaceId, role: role), SidebarItem.allCases)
        }
    }

    /// ⚠️ `.partial` IS CARRIED THROUGH so the sidebar can caption a row "Read-only".
    func test_IOS_SIDEBAR_11_aViewerSeesPartialGatesAndTabsAreNeverGated() {
        let entries = SidebarItem.entries(workspaceId: workspaceId, role: .viewer)
        let gates = Dictionary(uniqueKeysWithValues: entries.map { ($0.item, $0.gate) })
        XCTAssertEqual(gates[.workflows], .partial)
        XCTAssertEqual(gates[.scheduling], .partial)
        XCTAssertEqual(gates[.settings], .partial)
        XCTAssertEqual(gates[.billing], RouteGate.none)
        for item in tabItems {
            XCTAssertEqual(gates[item], RouteGate.none, "\(item)")
        }
    }

    // MARK: - Every route

    /// ⛔ BUMP THIS AND ADD A SAMPLE BELOW when ``expectation(for:)`` gains an arm.
    private static let routeCaseCount = 18

    private static let everyRoute: [Route] = [
        .callDetail(workspaceId: "ws_1", callId: "call_1"),
        .thread(
            workspaceId: "ws_1",
            role: .agency,
            threadKey: "contact:c_1",
            replyTargets: [ReplyTarget(to: "+15555550100", channel: "sms")],
            title: nil
        ),
        .contactDetail(workspaceId: "ws_1", role: .agency, contactId: "c_1"),
        .hq(workspaceId: "ws_1", role: .agency),
        .analytics(workspaceId: "ws_1"),
        .marketplace(workspaceId: "ws_1", role: .agency),
        .billing(workspaceId: "ws_1", role: .agency),
        .workflows(workspaceId: "ws_1", role: .agency),
        .rooms(workspaceId: "ws_1", role: .agency),
        .activeRoom(workspaceId: "ws_1", role: .agency, roomName: "meet_ws_1_a"),
        .dialer(workspaceId: "ws_1", role: .agency),
        .workspaceSettings(workspaceId: "ws_1", role: .agency, section: .hub),
        .workspaceSettings(workspaceId: "ws_1", role: .agency, section: .members),
        .scheduling(workspaceId: "ws_1", role: .agency, section: .hub),
        .scheduling(workspaceId: "ws_1", role: .agency, section: .bookings),
        .scheduling(workspaceId: "ws_1", role: .agency, section: .booking(id: "b_1")),
        .support(workspaceId: "ws_1", role: .agency),
        .supportRequest(workspaceId: "ws_1", role: .agency, key: "DA-1"),
        .desk(workspaceId: "ws_1", role: .agency),
        .deskTicket(workspaceId: "ws_1", role: .agency, ticketId: "t_1"),
        .devices,
    ]

    private struct Expectation {
        /// The case's name, so a missing sample shows up as a short count.
        let name: String
        let owner: SidebarItem?
        let isRoot: Bool

        init(_ name: String, _ owner: SidebarItem?, root isRoot: Bool = false) {
            self.name = name
            self.owner = owner
            self.isRoot = isRoot
        }
    }

    /// Where each route belongs, restated independently of the code under test.
    ///
    /// ⛔ EXHAUSTIVE AND WITHOUT `default`, so a new ``Route`` case stops this file
    /// compiling until someone decides whether it belongs to a tab or to a hub section,
    /// and whether it is that section's root.
    private func expectation(for route: Route) -> Expectation {
        switch route {
        case .callDetail: Expectation("callDetail", nil)
        case .thread: Expectation("thread", nil)
        case .contactDetail: Expectation("contactDetail", nil)
        case .devices: Expectation("devices", nil)
        case .hq: Expectation("hq", .hq, root: true)
        case .analytics: Expectation("analytics", .analytics, root: true)
        case .marketplace: Expectation("marketplace", .marketplace, root: true)
        case .billing: Expectation("billing", .billing, root: true)
        case .workflows: Expectation("workflows", .workflows, root: true)
        case .rooms: Expectation("rooms", .rooms, root: true)
        case .activeRoom: Expectation("activeRoom", .rooms)
        case .dialer: Expectation("dialer", .dialer, root: true)
        case .desk: Expectation("desk", .desk, root: true)
        case .deskTicket: Expectation("deskTicket", .desk)
        case .support: Expectation("support", .support, root: true)
        case .supportRequest: Expectation("supportRequest", .support)
        case let .scheduling(_, _, section): Expectation("scheduling", .scheduling, root: section == .hub)
        case let .workspaceSettings(_, _, section): Expectation("workspaceSettings", .settings, root: section == .hub)
        }
    }
}
