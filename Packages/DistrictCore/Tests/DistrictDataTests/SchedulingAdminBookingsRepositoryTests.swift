import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The typed `bookings.*` wrappers.
///
/// ⛔ WHAT IS UNDER TEST IS THE PAIRING, NOT THE TRANSPORT.
/// `SchedulingAdminRepositoryTests` already proves the envelope — the 200 that is
/// a failure, the refusal mapping, the decode guard — against a trivial payload.
/// These assert the two things a generic `perform` cannot check for itself: that
/// each wrapper sends the OP NAME the catalog knows it by, and that it names the
/// response TYPE that op actually answers. Both cross the wire as nothing at all,
/// so a mismatch is a runtime `SchedulingAdminError.decoding` rather than a
/// compile error.
///
/// ⛔ AND THAT THE PATH KEYS ARE STILL IN THE BODY. The server validates the
/// params against a schema that REQUIRES `id` and only then strips it for the
/// URL, so a client that helpfully removed it gets a 400 naming the field.
final class SchedulingAdminBookingsRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> SchedulingAdminRepository {
        SchedulingAdminRepository(client: .repositoryTest(transport), reportUnknownOp: { _ in })
    }

    private static let bookingRow = #"""
    {"id":"bk_1","event_type_slug":"intro-call","start_at":"2026-09-14T13:00:00Z",
     "end_at":"2026-09-14T13:30:00Z","status":"confirmed"}
    """#

    // MARK: - The list, and its filters

    /// ⚠️ AN UNFILTERED LIST SENDS `"params":{}` RATHER THAN DROPPING THE KEY —
    /// every optional filter is omitted by `JSONValue.object(_:)`, and `allHosts:
    /// false` omits `scope` entirely because `z.literal("all")` has no other legal
    /// value.
    func testAnUnfilteredListSendsNoParamsAndDecodesThePage() async throws {
        let transport = RepositoryTransport(
            json: #"""
            {"ok":true,"data":{"items":[\#(Self.bookingRow)],"total":2,
             "counts":{"upcoming":1,"past":1},"limit":50,"offset":0}}
            """#
        )
        let page = try await repository(transport).bookings(workspaceId: "ws_1")
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].id, "bk_1")
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.counts?.upcoming, 1)
        XCTAssertEqual(page.limit, 50)
        XCTAssertEqual(page.offset, 0)
        XCTAssertEqual(transport.bodies, [#"{"op":"bookings.list","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⛔ EVERY FILTER AT ONCE, AND THE WIRE SPELLINGS ARE NOT THE SWIFT ONES.
    /// `eventTypeSlug` goes out as `event_type` and `allHosts` as `scope: "all"`;
    /// both are the catalog's names, and a renamed one is a 400 rather than a
    /// compile error.
    func testEveryFilterIsSentUnderTheCatalogsOwnKeys() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"items":[]}}"#)
        _ = try await repository(transport).bookings(
            workspaceId: "ws_1",
            status: "confirmed",
            when: "upcoming",
            from: "2026-09-01",
            to: "2026-09-30",
            eventTypeSlug: "intro-call",
            host: "u_1",
            team: "t_1",
            limit: 50,
            offset: 10,
            allHosts: true,
            order: "asc"
        )
        let expected = #"{"op":"bookings.list","params":{"event_type":"intro-call","from":"2026-09-01","#
            + #""host":"u_1","limit":50,"offset":10,"order":"asc","scope":"all","status":"confirmed","#
            + #""team":"t_1","to":"2026-09-30","when":"upcoming"},"workspaceId":"ws_1"}"#
        XCTAssertEqual(transport.bodies, [expected])
    }

    // MARK: - The reads that take an id

    /// ⚠️ THE `{items}` WRAPPER IS UNWRAPPED HERE, which is why the repository
    /// returns an array: three ops on this surface use it, one uses `{calendars}`
    /// and one answers a bare array.
    func testAnswersUnwrapTheItemsContainer() async throws {
        let transport = RepositoryTransport(
            json: #"""
            {"ok":true,"data":{"items":[{"question_id":"q_1","label":"Which product?",
             "type":"select","value":"District"}]}}
            """#
        )
        let answers = try await repository(transport).bookingAnswers(workspaceId: "ws_1", bookingId: "bk_1")
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers[0].questionId, "q_1")
        XCTAssertEqual(answers[0].value, "District")
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"bookings.answers","params":{"id":"bk_1"},"workspaceId":"ws_1"}"#]
        )
    }

    func testNotesDecodeTheDiscriminatedShape() async throws {
        let transport = RepositoryTransport(
            json: #"{"ok":true,"data":{"exists":true,"content":"Wants a quote.","status":"ready"}}"#
        )
        let notes = try await repository(transport).bookingNotes(workspaceId: "ws_1", bookingId: "bk_1")
        XCTAssertTrue(notes.exists)
        XCTAssertEqual(notes.content, "Wants a quote.")
        XCTAssertNil(notes.updatedAt)
        XCTAssertEqual(transport.bodies, [#"{"op":"bookings.notes","params":{"id":"bk_1"},"workspaceId":"ws_1"}"#])
    }

    /// ⛔ A DIFFERENT OP AND A DIFFERENT TYPE, one hyphenated word apart from the
    /// read above. The regenerate answer has no `updated_at` in its schema at all.
    func testRegeneratingNotesUsesItsOwnOpAndItsOwnShape() async throws {
        let transport = RepositoryTransport(
            json: #"{"ok":true,"data":{"exists":true,"content":"Wants a quote.","status":"pending"}}"#
        )
        let notes = try await repository(transport).regenerateBookingNotes(workspaceId: "ws_1", bookingId: "bk_1")
        XCTAssertEqual(notes.status, "pending")
        XCTAssertTrue(notes.exists)
        XCTAssertEqual(notes.content, "Wants a quote.")
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"bookings.notes.regenerate","params":{"id":"bk_1"},"workspaceId":"ws_1"}"#]
        )
    }

    func testATranscriptThatWasNeverCapturedIsAnOrdinaryAnswer() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"exists":false}}"#)
        let transcript = try await repository(transport).bookingTranscript(workspaceId: "ws_1", bookingId: "bk_1")
        XCTAssertFalse(transcript.exists)
        XCTAssertNil(transcript.text)
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"bookings.transcript","params":{"id":"bk_1"},"workspaceId":"ws_1"}"#]
        )
    }

    // MARK: - The three writes, which all answer a booking

    /// ⚠️ THE REASON IS OPTIONAL AND IS DROPPED WHEN ABSENT rather than sent as
    /// null — an explicit null would fail the catalog's `.optional()` validation
    /// instead of meaning "no reason".
    func testCancellingWithoutAReasonSendsOnlyTheId() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.bookingRow)}"#)
        let booking = try await repository(transport).cancelBooking(workspaceId: "ws_1", bookingId: "bk_1")
        XCTAssertEqual(booking.id, "bk_1")
        XCTAssertEqual(transport.bodies, [#"{"op":"bookings.cancel","params":{"id":"bk_1"},"workspaceId":"ws_1"}"#])
    }

    func testCancellingWithAReasonCarriesItBesideThePathKey() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.bookingRow)}"#)
        _ = try await repository(transport).cancelBooking(
            workspaceId: "ws_1",
            bookingId: "bk_1",
            reason: "Customer asked to postpone"
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"bookings.cancel","params":{"id":"bk_1","reason":"Customer asked to postpone"},"#
                    + #""workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⛔ A START AND NO END. The far end recomputes the end from the event type's
    /// duration, and the schema offers nowhere to put one.
    func testReschedulingSendsOnlyTheNewStart() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.bookingRow)}"#)
        let booking = try await repository(transport).rescheduleBooking(
            workspaceId: "ws_1",
            bookingId: "bk_1",
            startAt: "2026-09-20T15:00:00Z"
        )
        XCTAssertEqual(booking.status, "confirmed")
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"bookings.reschedule","params":{"id":"bk_1","start_at":"2026-09-20T15:00:00Z"},"#
                    + #""workspaceId":"ws_1"}"#,
            ]
        )
    }

    func testReassigningSendsTheSchedulerUsersId() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.bookingRow)}"#)
        _ = try await repository(transport).reassignBooking(
            workspaceId: "ws_1",
            bookingId: "bk_1",
            hostId: "u_2"
        )
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"bookings.reassign","params":{"host_id":"u_2","id":"bk_1"},"workspaceId":"ws_1"}"#]
        )
    }

    /// ⛔ A `slot_taken` REFUSAL IS A **200**, and it must reach the caller as a
    /// failure rather than as a decode error — which is only true because the
    /// repository reads the envelope's flag before the payload. Reschedule is the
    /// one op on this surface that meets it in normal use.
    func testAReschedulingCollisionArrivesAsAFailureRatherThanADecodeError() async {
        let transport = RepositoryTransport(json: #"{"ok":false,"failure":"slot_taken","status":409}"#)
        do {
            _ = try await repository(transport).rescheduleBooking(
                workspaceId: "ws_1",
                bookingId: "bk_1",
                startAt: "2026-09-20T15:00:00Z"
            )
            XCTFail("expected a failure")
        } catch let error as SchedulingAdminError {
            XCTAssertEqual(error, .failure(.slotTaken))
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }
}
