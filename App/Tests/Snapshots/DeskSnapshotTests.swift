@testable import DistrictAI
import SwiftUI
import XCTest

/// The Desk queue in the states its two reads can leave it in, and the compose sheet,
/// drawn from the service's recorded settings and tickets.
final class DeskSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let settings = "/api/district/desk/settings"
    private static let tickets = "/api/district/desk/tickets"

    /// The recorded settings with the desk switched off.
    private static var deskOff: FixtureTransport.Reply {
        .recorded("district-desk-settings") { json in
            json.editObject("settings") { $0["enabled"] = false }
        }
    }

    // MARK: - The queue

    /// Off, as an owner sees it: the card offers the settings that turn it on, and the
    /// queue is never read.
    func testDeskOff() async throws {
        try await assertScreen([Self.settings: Self.deskOff]) { container in
            DeskView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// Off, as a viewer sees it: the same card without the button.
    func testDeskOffForAViewer() async throws {
        try await assertScreen([Self.settings: Self.deskOff], devices: [.iPhone]) { container in
            DeskView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    /// The settings read refused: the desk's state is unknown, said as such, with a retry.
    /// The queue is still read, and answers.
    func testDeskStateUnknown() async throws {
        try await assertScreen([Self.settings: .refused(500)]) { container in
            DeskView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// On, with the queue read refused: the failure with its retry, and no new-ticket button.
    func testQueueFailed() async throws {
        try await assertScreen([Self.tickets: .refused(500)]) { container in
            DeskView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// On, with nothing in the queue: the filters at zero and the empty sentence.
    func testQueueEmpty() async throws {
        try await assertScreen([Self.tickets: .json(#"{"success":true,"tickets":[]}"#)]) { container in
            DeskView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// A viewer's queue: the recorded rows, no new-ticket button, settings disabled.
    func testQueueForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            DeskView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    // MARK: - The compose sheet

    /// The sheet as it opens: every box empty and Create disabled.
    func testComposeSheet() async throws {
        try await assertScreen { container in
            DeskComposeSheet(model: DeskModel(container: container, workspaceId: Self.workspace, role: .client))
        }
    }

    /// A create the service refused: its sentence above the form, which stays open.
    ///
    /// ⚠️ THE BOXES DRAW EMPTY because what was typed is the sheet's own view state, which a
    /// test cannot reach; the failure line is the model's, and that is what this pins.
    func testComposeSheetCreateRefused() async throws {
        var draft = DeskComposerState()
        draft.subject = "Refund not received"
        draft.message = "Ordered on the 3rd."
        let submitted = draft
        try await assertScreen(
            ["POST \(Self.tickets)": .refused(400, "Requester email is not valid")],
            devices: [.iPhone]
        ) { container in
            let model = DeskModel(container: container, workspaceId: Self.workspace, role: .client)
            return DeskComposeSheet(model: model)
                .task { _ = await model.createTicket(submitted) }
        }
    }

    // MARK: - One ticket

    private static let ticket = "/api/district/desk/tickets/desk_ticket_open"

    /// A viewer reads the thread without the reply box or the status controls.
    func testDeskTicketForAViewer() async throws {
        try await assertScreen([Self.ticket: .fixture("district-desk-ticket")], devices: [.iPhone]) { container in
            DeskTicketView(
                container: container,
                workspaceId: Self.workspace,
                ticketId: "desk_ticket_open",
                role: .viewer
            )
        }
    }

    /// A resolved ticket: the Resolved badge, and Resolved not offered again.
    func testDeskTicketResolved() async throws {
        let resolved = FixtureTransport.Reply.recorded("district-desk-ticket") { json in
            json.editObject("ticket") { ticket in
                ticket["status"] = "resolved"
                ticket["resolvedAt"] = "2026-09-06T16:40:00.000Z"
            }
        }
        try await assertScreen([Self.ticket: resolved], devices: [.iPhone]) { container in
            DeskTicketView(
                container: container,
                workspaceId: Self.workspace,
                ticketId: "desk_ticket_open",
                role: .client
            )
        }
    }

    /// A refused ticket read: the failure with its retry.
    func testDeskTicketFailed() async throws {
        try await assertScreen([Self.ticket: .refused(500)], devices: [.iPhone]) { container in
            DeskTicketView(
                container: container,
                workspaceId: Self.workspace,
                ticketId: "desk_ticket_open",
                role: .client
            )
        }
    }

    // MARK: - Settings

    /// The settings with the desk off: the dependent controls (notify, brand, logo) disabled.
    func testDeskSettingsOff() async throws {
        try await assertScreen([Self.settings: Self.deskOff]) { container in
            DeskSettingsView(container: container, workspaceId: Self.workspace, role: .client, onDismiss: {})
        }
    }

    /// A viewer sees the settings and can change none of them.
    func testDeskSettingsForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            DeskSettingsView(container: container, workspaceId: Self.workspace, role: .viewer, onDismiss: {})
        }
    }

    /// A refused settings read: the failure with its retry, and no form.
    func testDeskSettingsFailed() async throws {
        try await assertScreen([Self.settings: .refused(500)], devices: [.iPhone]) { container in
            DeskSettingsView(container: container, workspaceId: Self.workspace, role: .client, onDismiss: {})
        }
    }
}
