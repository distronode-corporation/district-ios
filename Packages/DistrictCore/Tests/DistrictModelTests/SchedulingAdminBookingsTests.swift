import DistrictModel
import Foundation
import XCTest

/// The `bookings.*` row DTOs, decoded from inline bytes.
///
/// ⛔ THE CONTRACT FIXTURES ARE NOT WHAT THESE ASSERT AND MUST NOT BE DUPLICATED
/// HERE. `ContractFixtureTests` runs the committed bodies through the strict
/// decode/re-encode walk, which is what pins the wire SHAPE; what this file pins
/// is the branches a single fixture cannot hold at once — an absent key and a
/// present one on the same field, a discriminated shape in both of its states.
final class SchedulingAdminBookingsTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - The booking row

    /// The fully-populated shape: every optional present, which is what a booking
    /// read through `bookings.cancel` looks like.
    func testAFullBookingDecodesEveryColumn() throws {
        let booking = try decode(
            SchedulingBooking.self,
            #"""
            {"id":"bk_1","event_type_id":"et_1","event_type_slug":"intro-call",
             "host_id":"u_1","host_name":"Dana","start_at":"2026-09-14T13:00:00Z",
             "end_at":"2026-09-14T13:30:00Z","status":"cancelled",
             "cancellation_reason":"Postponed","location_value":"+14165550134",
             "created_at":"2026-09-10T09:00:00Z","updated_at":"2026-09-11T11:00:00Z",
             "attendees":[{"name":"Ada","email":"ada@test"}]}
            """#
        )
        XCTAssertEqual(booking.id, "bk_1")
        XCTAssertEqual(booking.eventTypeSlug, "intro-call")
        XCTAssertEqual(booking.hostId, "u_1")
        XCTAssertEqual(booking.hostName, "Dana")
        XCTAssertEqual(booking.eventTypeId, "et_1")
        XCTAssertEqual(booking.cancellationReason, "Postponed")
        XCTAssertEqual(booking.locationValue, "+14165550134")
        XCTAssertEqual(booking.createdAt, "2026-09-10T09:00:00Z")
        XCTAssertEqual(booking.updatedAt, "2026-09-11T11:00:00Z")
        XCTAssertEqual(booking.startAt, "2026-09-14T13:00:00Z")
        XCTAssertEqual(booking.endAt, "2026-09-14T13:30:00Z")
        XCTAssertEqual(booking.status, "cancelled")
        XCTAssertEqual(booking.attendees?.count, 1)
        XCTAssertEqual(booking.attendees?.first?.name, "Ada")
        XCTAssertEqual(booking.attendees?.first?.email, "ada@test")
    }

    /// ⛔ FOUR KEYS IS A LEGAL BOOKING, AND IT IS THE ROW THAT BREAKS A CARELESS
    /// DTO. `bookingSchema` requires only `id`, `start_at`, `end_at` and `status`
    /// — not the event type and not the host — so a screen has to be able to draw
    /// this.
    func testASparseBookingDecodesWithOnlyTheFourRequiredKeys() throws {
        let booking = try decode(
            SchedulingBooking.self,
            #"""
            {"id":"bk_2","start_at":"2026-09-15T18:00:00Z","end_at":"2026-09-15T18:30:00Z",
             "status":"cancelled"}
            """#
        )
        XCTAssertEqual(booking.id, "bk_2")
        XCTAssertNil(booking.eventTypeId)
        XCTAssertNil(booking.eventTypeSlug)
        XCTAssertNil(booking.hostId)
        XCTAssertNil(booking.hostName)
        // ⚠️ ABSENT, NOT "NOT CANCELLED". The status says it was cancelled; the
        // reason simply was not recorded, and the two are not distinguishable here.
        XCTAssertNil(booking.cancellationReason)
        XCTAssertNil(booking.locationValue)
        XCTAssertNil(booking.createdAt)
        XCTAssertNil(booking.updatedAt)
        XCTAssertNil(booking.attendees)
    }

    /// ⛔ `status` IS NOT AN ENUM AND A VALUE THIS CLIENT HAS NEVER HEARD OF MUST
    /// NOT TAKE OUT THE LIST. The column belongs to the scheduler fork and is not
    /// CHECK-constrained on our side, which is the opposite call from
    /// ``SchedulingTenantStatus`` and for the opposite reason.
    func testAnUnknownStatusIsCarriedRatherThanRefused() throws {
        let booking = try decode(
            SchedulingBooking.self,
            #"{"id":"bk_3","start_at":"a","end_at":"b","status":"no-show"}"#
        )
        XCTAssertEqual(booking.status, "no-show")
    }

    /// ⚠️ BOTH ATTENDEE FIELDS ARE `.optional()` ON THE SERVER, so an attendee row
    /// with neither is legal and a non-optional `email` would throw on it.
    func testAnAttendeeMayCarryNeitherNameNorEmail() throws {
        let booking = try decode(
            SchedulingBooking.self,
            #"""
            {"id":"bk_4","start_at":"a","end_at":"b","status":"confirmed",
             "attendees":[{"name":"Ada"},{"email":"pat@test"},{}]}
            """#
        )
        XCTAssertEqual(booking.attendees?.count, 3)
        XCTAssertNil(booking.attendees?[0].email)
        XCTAssertNil(booking.attendees?[1].name)
        XCTAssertEqual(booking.attendees?[1].email, "pat@test")
        XCTAssertNil(booking.attendees?[2].name)
        XCTAssertNil(booking.attendees?[2].email)
    }

    /// ⛔ THE FOUR REQUIRED KEYS ARE REQUIRED. A row missing `status` is contract
    /// drift and must throw rather than decode to a default.
    func testABookingWithoutAStatusIsRefused() {
        XCTAssertThrowsError(
            try decode(SchedulingBooking.self, #"{"id":"bk_5","start_at":"a","end_at":"b"}"#)
        )
    }

    // MARK: - The page

    func testAPageCarriesItsTotalsAndItsEcho() throws {
        let page = try decode(
            SchedulingBookingPage.self,
            #"""
            {"items":[{"id":"bk_1","start_at":"a","end_at":"b","status":"confirmed"}],
             "total":2,"counts":{"upcoming":1,"past":1},"limit":50,"offset":0}
            """#
        )
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.counts?.upcoming, 1)
        XCTAssertEqual(page.counts?.past, 1)
        XCTAssertEqual(page.limit, 50)
        XCTAssertEqual(page.offset, 0)
    }

    /// ⛔ EVERY KEY BESIDE `items` IS `.optional()`, so a pager that read the echo
    /// unconditionally would crash on a perfectly ordinary answer. The absence is
    /// what forces it to keep its own offset as the fallback.
    func testAPageWithNoEchoAndNoTotalsStillDecodes() throws {
        let page = try decode(SchedulingBookingPage.self, #"{"items":[]}"#)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.total)
        XCTAssertNil(page.counts)
        XCTAssertNil(page.limit)
        XCTAssertNil(page.offset)
    }

    // MARK: - Answers

    /// ⛔ AN UNANSWERED OPTIONAL QUESTION IS `""`, NOT A MISSING KEY OR A MISSING
    /// ROW. `value` is non-optional in the schema for that reason.
    func testAnEmptyAnswerIsAnEmptyStringRatherThanAnAbsence() throws {
        let answer = try decode(
            SchedulingBookingAnswer.self,
            #"{"question_id":"q_1","label":"Anything to read first?","type":"text","value":""}"#
        )
        XCTAssertEqual(answer.questionId, "q_1")
        XCTAssertEqual(answer.label, "Anything to read first?")
        XCTAssertEqual(answer.type, "text")
        XCTAssertEqual(answer.value, "")
    }

    /// ⚠️ `type` IS THE QUESTION'S INPUT KIND AND `value` IS A STRING WHATEVER IT
    /// SAYS — a multi-select answer is pre-joined by the fork — so nothing should
    /// branch on `type` to decide how to decode.
    func testASelectAnswerStillDecodesAsAString() throws {
        let answer = try decode(
            SchedulingBookingAnswer.self,
            #"{"question_id":"q_2","label":"Which product?","type":"select","value":"District"}"#
        )
        XCTAssertEqual(answer.value, "District")
    }

    // MARK: - Notes and transcript, in both states

    func testNotesCarryTheirContentWhenTheyExist() throws {
        let notes = try decode(
            SchedulingBookingNotes.self,
            #"{"exists":true,"content":"Wants a quote.","status":"ready","updated_at":"2026-09-14T13:35:00Z"}"#
        )
        XCTAssertTrue(notes.exists)
        XCTAssertEqual(notes.content, "Wants a quote.")
        XCTAssertEqual(notes.status, "ready")
        XCTAssertEqual(notes.updatedAt, "2026-09-14T13:35:00Z")
    }

    /// ⛔ `exists:false` CARRIES NO OTHER KEY AT ALL, which is the whole reason the
    /// other three are Optional. Most bookings are in this state.
    func testNotesThatDoNotExistCarryNothingElse() throws {
        let notes = try decode(SchedulingBookingNotes.self, #"{"exists":false}"#)
        XCTAssertFalse(notes.exists)
        XCTAssertNil(notes.content)
        XCTAssertNil(notes.status)
        XCTAssertNil(notes.updatedAt)
    }

    /// ⛔ THE REGENERATE ANSWER IS A THIRD SHAPE AND HAS NO `updated_at` KEY IN ITS
    /// SCHEMA AT ALL. Sharing ``SchedulingBookingNotes`` would model a key the op
    /// never sends, which is invisible at runtime and a dropped/added-key report
    /// the moment the fixture is gated.
    func testARegeneratedNotesAnswerIsPendingWithThePreviousText() throws {
        let notes = try decode(
            SchedulingBookingNotesRegenerated.self,
            #"{"exists":true,"content":"Wants a quote, and a security review.","status":"pending"}"#
        )
        XCTAssertTrue(notes.exists)
        XCTAssertEqual(notes.status, "pending")
        XCTAssertEqual(notes.content, "Wants a quote, and a security review.")
    }

    func testARegeneratedNotesAnswerMayCarryNeitherFieldYet() throws {
        let notes = try decode(SchedulingBookingNotesRegenerated.self, #"{"exists":false}"#)
        XCTAssertFalse(notes.exists)
        XCTAssertNil(notes.content)
        XCTAssertNil(notes.status)
    }

    func testATranscriptCarriesItsTextWhenOneWasCaptured() throws {
        let transcript = try decode(
            SchedulingBookingTranscript.self,
            #"{"exists":true,"text":"Host: Thanks for joining."}"#
        )
        XCTAssertTrue(transcript.exists)
        XCTAssertEqual(transcript.text, "Host: Thanks for joining.")
    }

    func testATranscriptThatDoesNotExistCarriesNoText() throws {
        let transcript = try decode(SchedulingBookingTranscript.self, #"{"exists":false}"#)
        XCTAssertFalse(transcript.exists)
        XCTAssertNil(transcript.text)
    }
}
