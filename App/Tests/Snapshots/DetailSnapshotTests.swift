@testable import DistrictAI
import SwiftUI
import XCTest

/// The detail screens and the lists that lead to them, each drawn from the service's
/// recorded responses for the record the fixture names.
final class DetailSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"

    func testCallLog() async throws {
        try await assertScreen { container in
            CallLogView(container: container, workspaceId: Self.workspace, selection: nil)
        }
    }

    func testCallDetail() async throws {
        try await assertScreen(
            ["/api/district/calls/call_contract_answered": .fixture("district-call-detail")]
        ) { container in
            CallDetailView(container: container, workspaceId: Self.workspace, callId: "call_contract_answered")
        }
    }

    func testContactDetail() async throws {
        try await assertScreen(
            ["/api/district/contacts/get": .fixture("district-contact-detail")]
        ) { container in
            ContactDetailView(
                container: container,
                workspaceId: Self.workspace,
                role: .client,
                contactId: "contact_contract_1"
            )
        }
    }

    func testDeskTicket() async throws {
        try await assertScreen(
            ["/api/district/desk/tickets/desk_ticket_open": .fixture("district-desk-ticket")]
        ) { container in
            DeskTicketView(
                container: container,
                workspaceId: Self.workspace,
                ticketId: "desk_ticket_open",
                role: .client
            )
        }
    }

    func testDeskSettings() async throws {
        try await assertScreen { container in
            DeskSettingsView(container: container, workspaceId: Self.workspace, role: .client, onDismiss: {})
        }
    }

    func testSupportThread() async throws {
        try await assertScreen(
            ["/api/district/support/requests/support_filed": .fixture("district-support-request")]
        ) { container in
            SupportThreadView(container: container, workspaceId: Self.workspace, role: .client, key: "support_filed")
        }
    }

    func testInbox() async throws {
        try await assertScreen { container in
            InboxView(
                container: container,
                workspaceId: Self.workspace,
                role: .client,
                path: .constant([]),
                pushSignal: 0,
                selection: nil
            )
        }
    }

    func testSetupWizard() async throws {
        try await assertScreen { container in
            SetupWizardView(container: container, workspaceId: Self.workspace, workspaceName: "Contract Clinic") {}
        }
    }
}
