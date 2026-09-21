import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// What a screen does with a desk write's ECHO once it has one.
///
/// ⛔ THE MERGE ITSELF LIVES IN `DistrictModel` RATHER THAN IN THE SCREEN, AND THESE
/// TESTS ARE WHY. `App/` has no test lane at all, so a hand-rolled rebuild of a
/// `DeskTicketDetail` from a `DeskTicketSummary` plus the loaded thread would be
/// unverified code holding the two fields most worth verifying: the STATUS, which a
/// team reply moves to `waiting`, and `resolvedAt`, which reopening CLEARS.
///
/// ⚠️ THE TWO TYPES ARE NOT INTERCHANGEABLE. The reply and status routes answer a
/// summary, which carries no `messages`; the detail route answers the thread. Adopting
/// one as the other is how a conversation disappears from a screen whose header is
/// still correct.
///
/// ⚠️ ALSO PINS THE WIRE VOCABULARIES, because those strings are what the routes
/// validate against and a renamed Swift case would be a 400 nobody could explain.
final class DeskThreadMergeTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> DeskRepository {
        DeskRepository(client: .repositoryTest(transport))
    }

    // MARK: - Applying a write's echo to a loaded thread

    /// ⛔ THE APPENDED MESSAGE COMES WITH THE SERVER'S WHOLE ROW, AND THE STATUS IS THE
    /// HALF THAT MATTERS. A team reply auto-sets `waiting`, so a merge that kept the
    /// local status would leave a ticket reading as though the ball were still with
    /// the team after they had answered.
    func testAppendingAReplyAdoptsTheEchoedRowAndKeepsTheThread() async {
        let transport = RepositoryTransport(queue: [
            DeskBodies.ticketDetail(id: "tkt_a"),
            DeskBodies.reply(notified: true),
        ])
        let repo = repository(transport)
        let loaded = await repo.ticket(workspaceId: "ws_1", ticketId: "tkt_a")
        let replied = await repo.reply(workspaceId: "ws_1", ticketId: "tkt_a", message: "Refunded.")

        guard let detail = loaded.successOnly, case let .posted(reply) = replied.successOnly else {
            return XCTFail("expected a loaded ticket and a posted reply")
        }
        let merged = detail.appending(reply.message, adopting: reply.ticket)

        XCTAssertEqual(merged.messages.map(\.id), ["msg_1", "msg_2", "msg_9"])
        XCTAssertEqual(merged.status, "waiting")
        // ⚠️ RECOMPUTED FROM THE THREAD, not adopted from the echo: the server's count
        // predates this append reaching the local copy, so taking it would leave the
        // header one behind the messages visible underneath it.
        XCTAssertEqual(merged.messageCount, 3)
        XCTAssertEqual(merged.id, "tkt_a")
    }

    /// ⛔ REOPENING CLEARS `resolvedAt`, AND THAT IS WHY THE ECHO IS ADOPTED WHOLE. A
    /// screen that kept the requested status alone would leave a reopened ticket
    /// carrying a resolution time in the past.
    func testAdoptingAStatusEchoCarriesResolvedAtAndLeavesTheThreadAlone() async {
        let transport = RepositoryTransport(queue: [
            DeskBodies.ticketDetail(id: "tkt_a"),
            DeskBodies.statusEcho(status: "resolved"),
        ])
        let repo = repository(transport)
        let loaded = await repo.ticket(workspaceId: "ws_1", ticketId: "tkt_a")
        let moved = await repo.setStatus(workspaceId: "ws_1", ticketId: "tkt_a", status: .resolved)

        guard let detail = loaded.successOnly, let summary = moved.successOnly else {
            return XCTFail("expected a loaded ticket and a status echo")
        }
        let merged = detail.adopting(summary)

        XCTAssertEqual(merged.status, "resolved")
        XCTAssertEqual(merged.resolvedAt, "2026-09-06T10:00:00.000Z")
        XCTAssertEqual(merged.messages.map(\.id), ["msg_1", "msg_2"])
        XCTAssertEqual(merged.messageCount, 2)
        XCTAssertEqual(merged.knownStatus, .resolved)
    }

    // MARK: - The vocabularies

    /// ⚠️ THE WIRE SPELLINGS ARE WHAT THE SERVER VALIDATES AGAINST, so they are pinned
    /// rather than left to the enum's own case names. `DESK_TICKET_STATUSES` is the
    /// route's `z.enum`, and a renamed case here would be a 400 nobody could explain.
    func testTheStatusAndAuthorVocabulariesMatchTheWire() {
        XCTAssertEqual(DeskTicketStatus.allCases.map(\.rawValue), ["open", "waiting", "resolved"])
        XCTAssertEqual(DeskMessageAuthor.allCases.map(\.rawValue), ["customer", "team", "assistant"])
        XCTAssertEqual(DeskSettings.brandNameMaxLength, 80)
        XCTAssertEqual(DeskLogoLimits.maximumByteCount, 512 * 1024)
        XCTAssertEqual(DeskLogoLimits.allowedMimeTypes, ["image/png", "image/jpeg", "image/webp"])
        XCTAssertNil(DeskLogoLimits.refusal(mimeType: "image/webp", byteCount: 1024))
    }
}
