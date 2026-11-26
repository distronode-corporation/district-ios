@testable import DistrictAI
import DistrictModel
import SwiftUI
import XCTest

/// Every route drawn through ``RouteDestinations``, the one switch the shell pushes from, so
/// each reference shows which screen a route lands on (a route wired to the wrong screen, or
/// to a placeholder, changes its image). Phone and English only: the screens themselves are
/// drawn in both languages and on both devices by their own tests.
final class RouteDestinationSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let suite = "com.distronode.district.snapshot.routes"

    private func draw(_ route: Route, testName: String = #function) async throws {
        try await assertScreen(
            [
                "/api/district/calls/call_contract_answered": .fixture("district-call-detail"),
                "/api/district/contacts/get": .fixture("district-contact-detail"),
                "/api/district/desk/tickets/desk_ticket_open": .fixture("district-desk-ticket"),
                "/api/district/support/requests/support_filed": .fixture("district-support-request"),
                "/api/auth/native/devices": .fixture("district-devices"),
            ],
            devices: [.iPhone],
            locales: [.en],
            testName: testName
        ) { container in
            UserDefaults().removePersistentDomain(forName: Self.suite)
            let defaults = UserDefaults(suiteName: Self.suite) ?? .standard
            return RouteDestinations.view(
                for: route,
                container: container,
                session: WorkspaceSessionModel(
                    container: container,
                    selection: WorkspaceSelectionStore(defaults: defaults)
                ),
                accountSession: SessionModel(container: container, push: PushRegistrar(container: container))
            )
        }
    }

    func testCallDetail() async throws {
        try await draw(.callDetail(workspaceId: Self.workspace, callId: "call_contract_answered"))
    }

    func testContactDetail() async throws {
        try await draw(.contactDetail(workspaceId: Self.workspace, role: .client, contactId: "contact_contract_1"))
    }

    func testHQ() async throws {
        try await draw(.hq(workspaceId: Self.workspace, role: .client))
    }

    func testAnalytics() async throws {
        try await draw(.analytics(workspaceId: Self.workspace))
    }

    func testMarketplace() async throws {
        try await draw(.marketplace(workspaceId: Self.workspace, role: .client))
    }

    func testBilling() async throws {
        try await draw(.billing(workspaceId: Self.workspace, role: .client))
    }

    func testWorkflows() async throws {
        try await draw(.workflows(workspaceId: Self.workspace, role: .client))
    }

    func testRooms() async throws {
        try await draw(.rooms(workspaceId: Self.workspace, role: .client))
    }

    func testDialer() async throws {
        try await draw(.dialer(workspaceId: Self.workspace, role: .client))
    }

    func testLiveCalls() async throws {
        try await draw(.liveCalls(workspaceId: Self.workspace, role: .client))
    }

    func testSupport() async throws {
        try await draw(.support(workspaceId: Self.workspace, role: .client))
    }

    func testSupportRequest() async throws {
        try await draw(.supportRequest(workspaceId: Self.workspace, role: .client, key: "support_filed"))
    }

    func testDesk() async throws {
        try await draw(.desk(workspaceId: Self.workspace, role: .client))
    }

    func testDeskTicket() async throws {
        try await draw(.deskTicket(workspaceId: Self.workspace, role: .client, ticketId: "desk_ticket_open"))
    }

    func testDevices() async throws {
        try await draw(.devices)
    }

    /// Every settings section, through ``SettingsDestinations``.
    func testEverySettingsSection() async throws {
        for section in SettingsSection.allCases {
            try await draw(
                .workspaceSettings(workspaceId: Self.workspace, role: .client, section: section),
                testName: "testSettings_\(section.rawValue)"
            )
        }
    }

    /// Every scheduling section, through ``SchedulingDestinations``.
    func testEverySchedulingSection() async throws {
        let sections: [(String, SchedulingSection)] = [
            ("hub", .hub), ("overview", .overview), ("eventTypes", .eventTypes),
            ("eventType", .eventType(slug: "phone-consultation")), ("hours", .hours),
            ("bookings", .bookings), ("calendar", .calendar), ("team", .team),
            ("settings", .settings), ("developer", .developer),
        ]
        for (name, section) in sections {
            try await draw(
                .scheduling(workspaceId: Self.workspace, role: .client, section: section),
                testName: "testScheduling_\(name)"
            )
        }
    }
}
