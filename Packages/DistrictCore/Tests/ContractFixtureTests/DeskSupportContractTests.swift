import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for District Desk and the in-product helpdesk.
///
/// ⚠️ THE STRICT GATE PROVES THE KEY SET; THESE PROVE THE BRANCHES. See
/// `AuthWorkspaceContractTests` for why both exist. The gate cannot tell a
/// fixture that exercises a null from one that never does, so the rows each
/// fixture exists to cover are asserted here by value.
final class DeskSupportContractTests: XCTestCase {
    /// ⛔ ROW 1 IS THE VOICE-CALL TICKET WITH EVERY REQUESTER FIELD NULL, and it is
    /// the commonest row on a voice workspace rather than an edge case.
    func testTheQueueCoversAVoiceCallRowWithNoRequester() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-desk-tickets.json",
            as: DeskTicketsResponse.self
        )
        XCTAssertEqual(response.tickets.count, 3)
        XCTAssertEqual(response.tickets[0].displayReference, "T-41")

        let voiceRow = response.tickets[1]
        XCTAssertTrue(voiceRow.fromCall)
        XCTAssertNil(voiceRow.contactId)
        XCTAssertNil(voiceRow.requesterName)
        XCTAssertNil(voiceRow.requesterEmail)
        XCTAssertNil(voiceRow.requesterPhone)
        XCTAssertEqual(response.tickets[2].knownStatus, .resolved)
        XCTAssertNotNil(response.tickets[2].resolvedAt)
    }

    /// ⛔ ONLY THE READ CARRIES A THREAD, WITH ALL THREE AUTHORS. The reply and
    /// status echoes are summaries, which is why they are gated against a
    /// summary-based type and not ``DeskTicketDetail``.
    func testTheReadCarriesAllThreeAuthorsAndTheEchoesCarryNoThread() throws {
        let read = try StrictDecodeVerifier.verify(
            fixture: "district-desk-ticket.json",
            as: DeskTicketResponse.self
        )
        let authors = try XCTUnwrap(read.ticket).messages.map(\.knownAuthor)
        XCTAssertEqual(authors, [.customer, .assistant, .team])

        let reply = try StrictDecodeVerifier.verify(
            fixture: "district-desk-ticket-reply.json",
            as: DeskReplyResponse.self
        )
        XCTAssertEqual(reply.ticket?.knownStatus, .waiting)
        XCTAssertEqual(reply.notified, true)
        XCTAssertNil(reply.deduplicated)

        let status = try StrictDecodeVerifier.verify(
            fixture: "district-desk-ticket-status.json",
            as: DeskTicketStatusResponse.self
        )
        XCTAssertEqual(status.ticket?.knownStatus, .resolved)
        XCTAssertNotNil(status.ticket?.resolvedAt)
    }

    /// ⛔ THE LOGO DELETE ADDS `objectRemoved`, AND IT IS THE ONLY THING THAT SAYS
    /// WHETHER THE STORED BYTES WENT. The column is cleared first and the object
    /// second, and the second half can fail alone.
    func testTheLogoDeleteReportsTheObjectSeparatelyFromTheColumn() throws {
        let removal = try StrictDecodeVerifier.verify(
            fixture: "district-desk-logo-delete.json",
            as: DeskLogoRemovalResponse.self
        )
        XCTAssertTrue(removal.objectRemoved)
        XCTAssertNil(removal.settings.publicLogoUrl)

        let patched = try StrictDecodeVerifier.verify(
            fixture: "district-desk-settings-patch.json",
            as: DeskSettingsResponse.self
        )
        XCTAssertFalse(patched.settings.enabled)
        XCTAssertNil(patched.settings.publicBrandName)
    }

    /// ⛔ THE UNFILED ROW HAS A NULL `issueKey` AND THE SYNTHETIC `PENDING`
    /// CATEGORY, which must never read as resolved.
    func testTheSupportListCoversAnUnfiledRow() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-support-requests.json",
            as: SupportRequestListResponse.self
        )
        XCTAssertEqual(response.requests.count, 3)
        let pending = response.requests[1]
        XCTAssertNil(pending.issueKey)
        XCTAssertFalse(pending.filed)
        XCTAssertEqual(pending.statusCategory, "PENDING")
        XCTAssertEqual(pending.source, "voice-call")
    }

    /// ⛔ `author` IS A LABEL THE ROUTE SYNTHESISES; the vendor's display name
    /// never reaches this client.
    func testTheRequestReadSubstitutesTheAuthor() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-support-request.json",
            as: SupportRequestDetailResponse.self
        )
        XCTAssertTrue(response.request.closeable)
        XCTAssertEqual(response.request.messages.map(\.author), ["You", "Distronode Support"])

        let create = try StrictDecodeVerifier.verify(
            fixture: "district-support-request-create.json",
            as: SupportRequestCreateResponse.self
        )
        XCTAssertEqual(create.issueKey, "DA-43")
        XCTAssertNil(create.deduplicated)
        XCTAssertNil(create.pending)
    }
}
