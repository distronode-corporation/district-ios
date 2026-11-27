@testable import DistrictAI
import SwiftUI
import XCTest

/// States the recorded answers reach with one field changed that no other file draws: the
/// knowledge mode as this workspace's own documents and as a mode this build has not learned,
/// the members roster as a viewer reads it, and the Desk queue with a ticket from a call, a
/// status this build predates, and a selected row.
final class SettingsAndDeskStatesSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let knowledgeMode = "/api/district/workspace/knowledge-mode"
    private static let tickets = "/api/district/desk/tickets"

    // MARK: - Knowledge

    /// Answers from this workspace's own documents: "own documents" is the stored mode and its
    /// button is the one withheld, the linked one offered.
    func testKnowledgeInternalMode() async throws {
        try await assertScreen(
            [Self.knowledgeMode: .json(#"{"success":true,"mode":"internal"}"#)],
            devices: [.iPhone]
        ) { container in
            KnowledgeView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// ⚠️ A MODE THIS BUILD HAS NOT LEARNED IS SHOWN AS ITSELF, with the note that says so,
    /// and both known modes stay on offer.
    func testKnowledgeUnknownMode() async throws {
        try await assertScreen(
            [Self.knowledgeMode: .json(#"{"success":true,"mode":"federated"}"#)],
            devices: [.iPhone]
        ) { container in
            KnowledgeView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// The same unknown mode for a viewer: the value and the note, no buttons, no add card.
    func testKnowledgeUnknownModeForAViewer() async throws {
        try await assertScreen(
            [Self.knowledgeMode: .json(#"{"success":true,"mode":"federated"}"#)],
            devices: [.iPhone],
            locales: [.en]
        ) { container in
            KnowledgeView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    // MARK: - Members

    /// A viewer reads the roster with the viewer's sentence, and neither the add card nor the
    /// rename card.
    func testMembersForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            MembersView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    // MARK: - Desk

    /// ⚠️ A STATUS THIS BUILD PREDATES IS DRAWN AS ITSELF IN A NEUTRAL BADGE, and a ticket the
    /// voice agent opened says it came from a call.
    func testDeskQueueWithACallTicketAndAnUnknownStatus() async throws {
        let reply = FixtureTransport.Reply.recorded("district-desk-tickets") { json in
            json.editEach("tickets") { row in
                switch row["id"] as? String {
                case "desk_ticket_open":
                    row["source"] = "voice-call"
                case "desk_ticket_waiting":
                    row["status"] = "escalated"
                default:
                    break
                }
            }
        }
        try await assertScreen([Self.tickets: reply], devices: [.iPhone]) { container in
            DeskView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// The queue as the regular-width shell's list column shows it, with the open ticket the
    /// selected row.
    func testDeskQueueWithASelectedTicket() async throws {
        let selected = Route.deskTicket(
            workspaceId: Self.workspace,
            role: .client,
            ticketId: "desk_ticket_open"
        )
        try await assertScreen(devices: [.iPad], locales: [.en]) { container in
            DeskView(
                container: container,
                workspaceId: Self.workspace,
                role: .client,
                selection: .constant(selected)
            )
        }
    }
}
