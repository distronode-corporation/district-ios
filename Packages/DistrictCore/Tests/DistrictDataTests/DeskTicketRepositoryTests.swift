import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// District Desk: the queue, the writes against one ticket, and the merge a screen
/// applies afterwards.
///
/// ⛔ THE ASSERTIONS HERE ARE ABOUT OUTCOMES THAT LOOK ALIKE ON A SCREEN AND ARE NOT
/// THE SAME VALUE. An empty queue and a failed read are one picture; a create that
/// answered `deduplicated` is a success with nothing to SHOW; a reply that answered
/// `deduplicated` with no body is a success with nothing to APPEND, which is a
/// different thing again and is the one that leaves an operator believing their
/// customer was not answered.
///
/// ⚠️ THE BODIES IN `DeskTestBodies` ARE NOT CONTRACT FIXTURES. They are written from
/// the ROUTE SOURCE to drive the repository's branches. The generated
/// `district-desk-*.json` fixtures pin the real shapes, gated in
/// `ImplementedFixtures+DeskSupport.swift`; re-check these bodies against those files
/// if either side changes.
///
/// ⚠️ THE SETTINGS AND LOGO CALLS ARE IN `DeskRepositoryTests`.
final class DeskTicketRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> DeskRepository {
        DeskRepository(client: .repositoryTest(transport))
    }

    // MARK: - The queue

    func testListingTicketsGetsTheQueueUnfilteredByDefault() async {
        let transport = RepositoryTransport(json: DeskBodies.tickets(ids: ["tkt_a", "tkt_b"]))

        let result = await repository(transport).tickets(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.map(\.id), ["tkt_a", "tkt_b"])
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/desk/tickets?workspaceId=ws_1"
        )
    }

    /// ⚠️ THE FILTER IS THE ENUM'S RAW VALUE, which is what makes an unrecognised
    /// status unsendable. The route would IGNORE one rather than refuse it, so a typo
    /// there presents as "the filter did nothing".
    func testAStatusFilterIsSentAsItsWireValue() async {
        let transport = RepositoryTransport(json: DeskBodies.tickets(ids: ["tkt_a"]))

        _ = await repository(transport).tickets(workspaceId: "ws_1", status: .waiting)

        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/desk/tickets?workspaceId=ws_1&status=waiting"
        )
    }

    /// ⛔ AN EMPTY QUEUE IS A SUCCESS. It is a workspace whose customers have not
    /// raised anything, and it is a different screen from "the desk is off" and a
    /// different one again from a failed read.
    func testAnEmptyQueueIsASuccessRatherThanAFailure() async {
        let transport = RepositoryTransport(json: #"{"success":true,"tickets":[]}"#)

        let result = await repository(transport).tickets(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.isEmpty, true)
        XCTAssertNil(result.failureOnly)
    }

    func testAQueueThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"tickets":[]}"#)

        let result = await repository(transport).tickets(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("DeskTicketsResponse did not affirm success=true"))
    }

    /// ⚠️ `status` AND `source` ARE FREE TEXT, so a value this build has not learned
    /// must decode and be displayable rather than failing the read. Painting an
    /// unknown status as resolved would tell an operator a customer has been dealt
    /// with.
    func testAnUnknownStatusDecodesAndReportsNoKnownStatus() async {
        let transport = RepositoryTransport(json: DeskBodies.tickets(ids: ["tkt_a"], status: "escalated"))

        let result = await repository(transport).tickets(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.first?.status, "escalated")
        XCTAssertNil(result.successOnly?.first?.knownStatus)
        XCTAssertEqual(result.successOnly?.first?.fromCall, false)
    }

    func testAVoiceFiledTicketReportsItsOriginAndItsKnownStatus() async {
        let transport = RepositoryTransport(
            json: DeskBodies.tickets(ids: ["tkt_a"], status: "open", source: "voice-call")
        )

        let result = await repository(transport).tickets(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.first?.fromCall, true)
        XCTAssertEqual(result.successOnly?.first?.knownStatus, .open)
        XCTAssertEqual(result.successOnly?.first?.displayReference, "T-7")
    }

    // MARK: - Creating a ticket

    /// ⛔ BLANK OPTIONALS ARE ABSENT FROM THE BYTES, NEVER `""`. An empty
    /// `requesterEmail` fails `.email()` and takes the whole object down, and the
    /// route then reports a missing subject and description — naming two fields that
    /// were both filled in.
    func testCreatingATicketOmitsBlankRequesterFieldsRatherThanSendingEmptyStrings() async {
        let transport = RepositoryTransport(json: DeskBodies.createdTicket(id: "tkt_a"))

        let result = await repository(transport).createTicket(
            workspaceId: "ws_1",
            draft: DeskTicketDraft(
                subject: "Refund not received",
                message: "Ordered on the 3rd.",
                requesterName: "  ",
                requesterEmail: "",
                requesterPhone: "+1 555 555 0111"
            ),
            idempotencyKey: "6f1c3f2e-6c4a-4a2f-9b1e-2c9d0f5a7b31"
        )

        guard case let .created(ticket) = result.successOnly else {
            return XCTFail("expected a created ticket, got \(String(describing: result))")
        }
        XCTAssertEqual(ticket.id, "tkt_a")
        XCTAssertEqual(ticket.displayReference, "T-7")
        XCTAssertEqual(transport.bodies, [
            #"{"idempotencyKey":"6f1c3f2e-6c4a-4a2f-9b1e-2c9d0f5a7b31","message":"Ordered on the 3rd.","#
                + #""requesterPhone":"+1 555 555 0111","subject":"Refund not received"}"#,
        ])
    }

    /// ⛔ A DEDUPLICATED CREATE IS A SUCCESS WITH NOTHING TO SHOW, not a failure. The
    /// key already produced a ticket, which is what the key is for; reporting it as an
    /// error would make a retried submit look broken and invite a third.
    func testADeduplicatedCreateIsASuccessCarryingNoTicket() async {
        let transport = RepositoryTransport(json: #"{"success":true,"deduplicated":true}"#)

        let result = await repository(transport).createTicket(
            workspaceId: "ws_1",
            draft: DeskTicketDraft(subject: "Refund", message: "Again"),
            idempotencyKey: "6f1c3f2e-6c4a-4a2f-9b1e-2c9d0f5a7b31"
        )

        XCTAssertEqual(result.successOnly, .deduplicated)
    }

    /// ⚠️ NEITHER A TICKET NOR A DEDUPE FLAG IS DRIFT. Reporting it as a create would
    /// leave a caller to invent a row that was never made; reporting it as a dedupe
    /// would claim one exists.
    func testACreateWithNeitherATicketNorADedupeFlagIsDrift() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).createTicket(
            workspaceId: "ws_1",
            draft: DeskTicketDraft(subject: "Refund", message: "Again")
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("DeskTicketCreateResponse affirmed success with no ticket")
        )
    }

    func testACreateThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await repository(transport).createTicket(
            workspaceId: "ws_1",
            draft: DeskTicketDraft(subject: "Refund", message: "Again")
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("DeskTicketCreateResponse did not affirm success=true")
        )
    }

    // MARK: - One ticket

    /// ⛔ THE THREAD IS NESTED INSIDE THE TICKET. Reading a top-level `messages` yields
    /// nothing and renders as an empty conversation with a correct header and no error
    /// anywhere.
    func testReadingATicketAnswersTheNestedThread() async {
        let transport = RepositoryTransport(json: DeskBodies.ticketDetail(id: "tkt_a"))

        let result = await repository(transport).ticket(workspaceId: "ws_1", ticketId: "tkt_a")

        XCTAssertEqual(result.successOnly?.messages.map(\.id), ["msg_1", "msg_2"])
        XCTAssertEqual(result.successOnly?.messages.first?.knownAuthor, .customer)
        XCTAssertEqual(result.successOnly?.messages.last?.knownAuthor, .team)
        XCTAssertEqual(result.successOnly?.knownStatus, .waiting)
        XCTAssertEqual(result.successOnly?.fromCall, false)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/desk/tickets/tkt_a?workspaceId=ws_1"
        )
    }

    /// ⚠️ AN UNKNOWN AUTHOR MUST DECODE. `authorType` is free text server-side, and a
    /// kind this build has not learned belongs on the team's side of a thread rather
    /// than failing the read.
    func testAnUnknownAuthorTypeDecodesAndReportsNoKnownAuthor() async {
        let transport = RepositoryTransport(json: DeskBodies.ticketDetail(id: "tkt_a", lastAuthor: "supervisor"))

        let result = await repository(transport).ticket(workspaceId: "ws_1", ticketId: "tkt_a")

        XCTAssertEqual(result.successOnly?.messages.last?.authorType, "supervisor")
        XCTAssertNil(result.successOnly?.messages.last?.knownAuthor)
    }

    /// ⚠️ A FOREIGN ID IS A 404 RATHER THAN AN EMPTY 200, so a nil ticket on a 200 is
    /// drift and is reported as such rather than as "not found".
    func testATicketReadWithNoTicketOnA200IsDrift() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).ticket(workspaceId: "ws_1", ticketId: "tkt_a")

        XCTAssertEqual(result.failureOnly, .decoding("DeskTicketResponse affirmed success with no ticket"))
    }

    func testATicketReadThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await repository(transport).ticket(workspaceId: "ws_1", ticketId: "tkt_a")

        XCTAssertEqual(result.failureOnly, .decoding("DeskTicketResponse did not affirm success=true"))
    }

    /// ⚠️ A 404 REACHES THE CALLER AS AN HTTP FAILURE, which is what lets a screen say
    /// "that ticket is no longer available" rather than showing an empty thread.
    func testAMissingTicketArrivesAsA404() async {
        let transport = RepositoryTransport(json: #"{"success":false,"error":"Ticket not found."}"#, status: 404)

        let result = await repository(transport).ticket(workspaceId: "ws_1", ticketId: "tkt_a")

        XCTAssertEqual(result.failureOnly?.httpStatus, 404)
    }

    // MARK: - Replying

    /// ⛔ THE WIRE FIELD IS `message`, NOT `body`. The adjacent SUPPORT desk's reply
    /// takes `body`, and transposing them is a silent 400 from a request that reads
    /// perfectly well.
    func testReplyingSendsMessageAndNotBody() async {
        let transport = RepositoryTransport(json: DeskBodies.reply(notified: true))

        _ = await repository(transport).reply(
            workspaceId: "ws_1",
            ticketId: "tkt_a",
            message: "Refunded this morning."
        )

        XCTAssertEqual(transport.bodies, [#"{"message":"Refunded this morning."}"#])
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/desk/tickets/tkt_a/reply?workspaceId=ws_1"
        )
    }

    /// ⛔ THE APPENDED ROW IS THE SERVER'S, AND THE ECHOED STATUS COMES WITH IT. A team
    /// reply auto-sets `waiting` unless the ticket is resolved, which is a fact the
    /// request did not carry.
    func testAPostedReplyCarriesTheServersRowAndTheEchoedStatus() async {
        let transport = RepositoryTransport(json: DeskBodies.reply(notified: true))

        let result = await repository(transport).reply(
            workspaceId: "ws_1",
            ticketId: "tkt_a",
            message: "Refunded this morning.",
            idempotencyKey: "6f1c3f2e-6c4a-4a2f-9b1e-2c9d0f5a7b31"
        )

        guard case let .posted(reply) = result.successOnly else {
            return XCTFail("expected a posted reply, got \(String(describing: result))")
        }
        XCTAssertEqual(reply.message.id, "msg_9")
        XCTAssertEqual(reply.message.body, "Refunded this morning.")
        XCTAssertEqual(reply.ticket.status, "waiting")
        XCTAssertTrue(reply.notified)
        XCTAssertFalse(reply.deduplicated)
    }

    /// ⚠️ `notified: false` IS AN ORDINARY OUTCOME and never a failure of the reply
    /// itself: no address on file, notifications off, the daily cap, or Postmark
    /// refusing. The reply is the durable artefact; the email is a doorbell.
    func testAnUnnotifiedReplyIsStillAPostedReply() async {
        let transport = RepositoryTransport(json: DeskBodies.reply(notified: false))

        let result = await repository(transport).reply(
            workspaceId: "ws_1",
            ticketId: "tkt_a",
            message: "Refunded this morning."
        )

        guard case let .posted(reply) = result.successOnly else {
            return XCTFail("expected a posted reply, got \(String(describing: result))")
        }
        XCTAssertFalse(reply.notified)
    }

    /// ⚠️ A CACHED REPLAY STILL CARRIES THE REAL MESSAGE, and is flagged so a caller
    /// can tell a retried submit from a first one without treating it differently.
    func testACachedReplayCarriesTheOriginalMessageAndIsFlagged() async {
        let transport = RepositoryTransport(json: DeskBodies.reply(notified: true, deduplicated: true))

        let result = await repository(transport).reply(
            workspaceId: "ws_1",
            ticketId: "tkt_a",
            message: "Refunded this morning.",
            idempotencyKey: "6f1c3f2e-6c4a-4a2f-9b1e-2c9d0f5a7b31"
        )

        guard case let .posted(reply) = result.successOnly else {
            return XCTFail("expected a posted reply, got \(String(describing: result))")
        }
        XCTAssertTrue(reply.deduplicated)
        XCTAssertEqual(reply.message.id, "msg_9")
    }

    /// ⛔ THE DEGRADED REPLAY IS A REACHABLE STATE, NOT A DEFENSIVE BRANCH: two
    /// concurrent submits, or Redis dying between the claim and the cached-result
    /// read. No second row was written, and there is nothing to append — so a caller
    /// must refetch rather than treat this as an ordinary success.
    func testADeduplicatedReplyWithNoBodyIsItsOwnOutcome() async {
        let transport = RepositoryTransport(json: #"{"success":true,"deduplicated":true}"#)

        let result = await repository(transport).reply(
            workspaceId: "ws_1",
            ticketId: "tkt_a",
            message: "Refunded this morning.",
            idempotencyKey: "6f1c3f2e-6c4a-4a2f-9b1e-2c9d0f5a7b31"
        )

        XCTAssertEqual(result.successOnly, .deduplicatedWithoutBody)
    }

    /// ⚠️ HALF A BODY IS TREATED AS THE DEGRADED REPLAY RATHER THAN AS A POST. A
    /// ticket with no message would mean inventing the row that is missing, and the
    /// reply is safe either way — refetching is the answer that cannot mislead.
    func testAReplyCarryingATicketButNoMessageDegradesRatherThanInventingOne() async {
        let transport = RepositoryTransport(json: DeskBodies.replyWithoutMessage())

        let result = await repository(transport).reply(
            workspaceId: "ws_1",
            ticketId: "tkt_a",
            message: "Refunded this morning."
        )

        XCTAssertEqual(result.successOnly, .deduplicatedWithoutBody)
    }

    /// ⚠️ AN ABSENT `notified` READS AS "NOT SENT", NOT AS "UNKNOWN". No shape the
    /// route sends omits the key alongside a real message, so this is contract drift
    /// — and false is the answer that cannot mislead, because it states no email went
    /// out, which is something a caller can act on. Claiming the customer was emailed
    /// on the strength of a missing key is the failure worth ruling out.
    func testAReplyWithNoNotifiedKeyReportsNotNotifiedRatherThanAssumingSent() async {
        let transport = RepositoryTransport(json: DeskBodies.replyWithoutNotified())

        let result = await repository(transport).reply(
            workspaceId: "ws_1",
            ticketId: "tkt_a",
            message: "Refunded this morning."
        )

        guard case let .posted(reply) = result.successOnly else {
            return XCTFail("expected a posted reply, got \(String(describing: result))")
        }
        XCTAssertFalse(reply.notified)
        XCTAssertFalse(reply.deduplicated)
    }

    func testAReplyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await repository(transport).reply(
            workspaceId: "ws_1",
            ticketId: "tkt_a",
            message: "Refunded this morning."
        )

        XCTAssertEqual(result.failureOnly, .decoding("DeskReplyResponse did not affirm success=true"))
    }

    // MARK: - Status

    /// ⛔ THE ECHOED TICKET IS ADOPTED. Resolving stamps `resolvedAt` and reopening
    /// clears it, both server-side, so the row carries a fact the request did not.
    func testSettingAStatusSendsTheWireValueAndAdoptsTheEchoedRow() async {
        let transport = RepositoryTransport(json: DeskBodies.statusEcho(status: "resolved"))

        let result = await repository(transport).setStatus(
            workspaceId: "ws_1",
            ticketId: "tkt_a",
            status: .resolved
        )

        XCTAssertEqual(result.successOnly?.status, "resolved")
        XCTAssertEqual(result.successOnly?.resolvedAt, "2026-09-06T10:00:00.000Z")
        XCTAssertEqual(transport.bodies, [#"{"status":"resolved"}"#])
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/desk/tickets/tkt_a/status?workspaceId=ws_1"
        )
    }

    func testAStatusChangeWithNoTicketOnA200IsDrift() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).setStatus(
            workspaceId: "ws_1",
            ticketId: "tkt_a",
            status: .open
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("DeskTicketStatusResponse affirmed success with no ticket")
        )
    }

    func testAStatusChangeThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await repository(transport).setStatus(
            workspaceId: "ws_1",
            ticketId: "tkt_a",
            status: .open
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("DeskTicketStatusResponse did not affirm success=true")
        )
    }
}
