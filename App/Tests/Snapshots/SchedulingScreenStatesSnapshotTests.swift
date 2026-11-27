@testable import DistrictAI
import DistrictModel
import SwiftUI
import XCTest

/// The scheduling screens in the states besides "loaded, as a client": one event type and
/// one booking opened from their lists, the hub over every tenancy the status route
/// records, and each screen as a viewer, who reads everything and is offered no write.
final class SchedulingScreenStatesSnapshotTests: SchedulingWriteSnapshotCase {
    private typealias Reply = FixtureTransport.Reply

    // MARK: - One event type

    func testEventTypeAsClient() async throws {
        try await assertScreen { container in
            SchedulingEventTypeView(container: container, workspaceId: Self.workspace, role: .client, slug: Self.slug)
        }
    }

    /// A viewer gets the inspector without the write bar.
    func testEventTypeAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingEventTypeView(container: container, workspaceId: Self.workspace, role: .viewer, slug: Self.slug)
        }
    }

    /// ⛔ THREE READS, THREE FAILURES: the row itself refused, its hosts and questions still
    /// drawn, and no write bar, because a form must not open over a row that never loaded.
    func testEventTypeRowRefused() async throws {
        try await assertScreen(["op:eventTypes.get": .notReady], devices: [.iPhone]) { container in
            SchedulingEventTypeView(container: container, workspaceId: Self.workspace, role: .client, slug: Self.slug)
        }
    }

    /// The row loaded and both lists refused: each says so in its own card.
    func testEventTypeListsRefused() async throws {
        try await assertScreen(
            ["op:eventTypes.hosts.get": .refused, "op:eventTypes.questions.list": .refused],
            devices: [.iPhone]
        ) { container in
            SchedulingEventTypeView(container: container, workspaceId: Self.workspace, role: .client, slug: Self.slug)
        }
    }

    func testEventTypeNoHostsNoQuestions() async throws {
        try await assertScreen(
            ["op:eventTypes.hosts.get": .noItems, "op:eventTypes.questions.list": .noItems],
            devices: [.iPhone]
        ) { container in
            SchedulingEventTypeView(container: container, workspaceId: Self.workspace, role: .client, slug: Self.slug)
        }
    }

    // MARK: - One booking

    func testBookingAsClient() async throws {
        try await assertScreen { container in
            SchedulingBookingDetailView(
                container: container,
                workspaceId: Self.workspace,
                role: .client,
                bookingId: Self.bookingId
            )
        }
    }

    func testBookingAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingBookingDetailView(
                container: container,
                workspaceId: Self.workspace,
                role: .viewer,
                bookingId: Self.bookingId
            )
        }
    }

    func testBookingNoAnswers() async throws {
        try await assertScreen(["op:bookings.answers": .noItems], devices: [.iPhone]) { container in
            SchedulingBookingDetailView(
                container: container,
                workspaceId: Self.workspace,
                role: .client,
                bookingId: Self.bookingId
            )
        }
    }

    func testBookingAnswersRefused() async throws {
        try await assertScreen(["op:bookings.answers": .refused], devices: [.iPhone]) { container in
            SchedulingBookingDetailView(
                container: container,
                workspaceId: Self.workspace,
                role: .client,
                bookingId: Self.bookingId
            )
        }
    }

    // MARK: - The hub, per tenancy

    /// Still being created: the host it will live at, and no sections.
    func testHubProvisioning() async throws {
        try await assertScreen(Self.status("district-scheduling-status-provisioning")) { container in
            SchedulingHubView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// A provision that failed, its classified reason shown to any member.
    func testHubProvisionFailed() async throws {
        try await assertScreen(Self.status("district-scheduling-status-error"), devices: [.iPhone]) { container in
            SchedulingHubView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// No tenancy yet, for a member who may create one: Enable is offered.
    func testHubNoTenancy() async throws {
        try await assertScreen(Self.status("district-scheduling-status-legacy"), devices: [.iPhone]) { container in
            SchedulingHubView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testHubNotEligible() async throws {
        let reply = Reply.json(#"{"eligible":false,"canManage":false,"tenant":null}"#)
        try await assertScreen(
            ["/api/district/scheduling/status": reply],
            devices: [.iPhone]
        ) { container in
            SchedulingHubView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// ⛔ A FAILED STATUS READ IS A FAILURE, NEVER AN EMPTY CARD, and draws no section rows.
    func testHubStatusFailed() async throws {
        try await assertScreen(["/api/district/scheduling/status": .serverError], devices: [.iPhone]) { container in
            SchedulingHubView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testHubAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingHubView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    private static func status(_ fixture: String) -> [String: Reply] {
        ["/api/district/scheduling/status": .fixture(fixture)]
    }
}
