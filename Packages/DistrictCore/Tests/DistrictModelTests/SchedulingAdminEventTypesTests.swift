import DistrictModel
import Foundation
import XCTest

/// ⛔ EVERY BODY HERE IS INLINE AND DELIBERATELY NOT A CONTRACT FIXTURE. The
/// fixtures are gated in `ImplementedFixtures+SchedulingA.swift`, which proves the
/// DTO models the bytes EXACTLY; what this file proves is the other half — that
/// each field lands where the wire says and that the three kinds of absence on
/// these rows stay distinguishable. A fixture cannot show that, because it carries
/// one row per shape and the interesting cases are the pairs.
final class SchedulingAdminEventTypesTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - The event type row

    /// ⛔ THIRTY-THREE FIELDS, WHICH IS WHY THE POPULATED CASE IS ASSERTED AT ALL.
    /// Every key is spelled out in `CodingKeys` by hand, so a transposition
    /// (`buffer_before` onto `bufferAfterMinutes`) compiles, decodes and is wrong —
    /// the numbers are interchangeable to the type system and not to a booking.
    func testAFullyPopulatedEventTypeLandsEveryField() throws {
        let row = try decode(SchedulingEventType.self, Self.populatedEventType)
        XCTAssertEqual(row.id, "et_1")
        XCTAssertEqual(row.slug, "phone-consultation")
        XCTAssertEqual(row.name, "Phone consultation")
        XCTAssertEqual(row.description, "A 30 minute call.")
        XCTAssertEqual(row.durationMinutes, 30)
        XCTAssertEqual(row.slotIntervalMinutes, 15)
        XCTAssertEqual(row.locationType, "phone")
        XCTAssertEqual(row.locationValue, "+14165550134")
        XCTAssertEqual(row.routingMode, "round_robin")
        XCTAssertEqual(row.rrStrategy, "priority")
        // ⚠️ THE PAIR THAT CATCHES A TRANSPOSITION. Different values on purpose.
        XCTAssertEqual(row.bufferBeforeMinutes, 5)
        XCTAssertEqual(row.bufferAfterMinutes, 10)
        XCTAssertEqual(row.minNoticeMinutes, 120)
        XCTAssertEqual(row.maxFutureDays, 60)
        XCTAssertEqual(row.maxActiveBookings, 3)
        XCTAssertEqual(row.isActive, true)
        XCTAssertEqual(row.showTakenSlots, true)
        XCTAssertEqual(row.isPublic, false)
        XCTAssertEqual(row.createdAt, "2026-09-01T10:00:00Z")
        XCTAssertEqual(row.reminders, [1440, 60])
        XCTAssertEqual(row.archived, false)
        XCTAssertEqual(row.owned, true)
        XCTAssertEqual(row.ownerName, "Contract Member")
        XCTAssertEqual(row.ownerEmail, "member@distronode.test")
    }

    /// ⚠️ THE NINE TEMPLATE FIELDS, ASSERTED SEPARATELY BECAUSE THEY ARE NINE KEYS
    /// THAT DIFFER BY A PREFIX. `msg_` is the body and `subj_` is the subject line;
    /// swapping one pair renders a whole email in the subject and reads as a
    /// formatting bug rather than a mapping one.
    func testTheMessageAndSubjectTemplatesDoNotCross() throws {
        let row = try decode(SchedulingEventType.self, Self.populatedEventType)
        XCTAssertEqual(row.msgConfirmation, "msg-confirmation")
        XCTAssertEqual(row.msgCancellation, "msg-cancellation")
        XCTAssertEqual(row.msgReschedule, "msg-reschedule")
        XCTAssertEqual(row.msgReminder, "msg-reminder")
        XCTAssertEqual(row.msgGreeting, "msg-greeting")
        XCTAssertEqual(row.subjConfirmation, "subj-confirmation")
        XCTAssertEqual(row.subjCancellation, "subj-cancellation")
        XCTAssertEqual(row.subjReschedule, "subj-reschedule")
        XCTAssertEqual(row.subjReminder, "subj-reminder")
    }

    /// ⛔ THE OTHER NULL POLARITY, AND THE REASON THE ROW HAS SO MANY OPTIONALS.
    /// Eleven nullable columns arrive as EXPLICIT nulls (Go marshals a nil without
    /// `omitempty`) while twelve optional ones are absent keys. Swift spells both
    /// `nil`, which is exactly why the contract gate carries per-path null
    /// permission rather than a per-type waiver.
    func testTheNulledAndAbsentFieldsBothDecodeAsNil() throws {
        let row = try decode(SchedulingEventType.self, Self.sparseEventType)
        // Explicit nulls on the wire.
        XCTAssertNil(row.description)
        XCTAssertNil(row.locationValue)
        XCTAssertNil(row.msgConfirmation)
        XCTAssertNil(row.msgCancellation)
        XCTAssertNil(row.msgReschedule)
        XCTAssertNil(row.msgReminder)
        XCTAssertNil(row.msgGreeting)
        XCTAssertNil(row.subjConfirmation)
        XCTAssertNil(row.subjCancellation)
        XCTAssertNil(row.subjReschedule)
        XCTAssertNil(row.subjReminder)
        // ⛔ NULL, NOT `[]`. An empty array means every reminder was turned OFF;
        // null means none was ever configured, and the read side must keep them
        // apart even though this type cannot send the difference back.
        XCTAssertNil(row.reminders)
        // Absent keys.
        XCTAssertNil(row.slotIntervalMinutes)
        XCTAssertNil(row.routingMode)
        XCTAssertNil(row.rrStrategy)
        XCTAssertNil(row.bufferBeforeMinutes)
        XCTAssertNil(row.bufferAfterMinutes)
        XCTAssertNil(row.minNoticeMinutes)
        XCTAssertNil(row.maxFutureDays)
        XCTAssertNil(row.maxActiveBookings)
        XCTAssertNil(row.showTakenSlots)
        XCTAssertNil(row.owned)
        XCTAssertNil(row.ownerName)
        XCTAssertNil(row.ownerEmail)
        // Still required, and still there.
        XCTAssertEqual(row.id, "et_2")
        XCTAssertEqual(row.durationMinutes, 60)
        XCTAssertEqual(row.archived, true)
    }

    /// ⛔ AN EMPTY `reminders` ARRAY IS NOT A NULL, and the two are one keystroke
    /// apart in a fixture. `[]` is "the operator turned every reminder off"; the
    /// case above is "never configured".
    func testAnEmptyRemindersArrayIsNotTheSameAsNull() throws {
        let row = try decode(
            SchedulingEventType.self,
            #"{"id":"et_3","slug":"s","name":"n","duration_minutes":15,"reminders":[]}"#
        )
        XCTAssertEqual(row.reminders, [])
        XCTAssertNotNil(row.reminders)
    }

    /// ⛔ THE FOUR REQUIRED FIELDS ARE REQUIRED. A row missing `duration_minutes`
    /// is not a row with a sensible default; it is a contract break, and defaulting
    /// it would publish a booking window nobody chose.
    func testARowWithoutADurationIsRefused() {
        XCTAssertThrowsError(
            try decode(SchedulingEventType.self, #"{"id":"et","slug":"s","name":"n"}"#)
        )
    }

    /// ⛔ `price_cents` AND `currency` ARE NOT MODELLED AND MUST NOT BE. The catalog
    /// strips both from the response and refuses them on the way in, because a
    /// dashboard that rendered them would advertise paid bookings this platform
    /// cannot settle. ⚠️ The assertion here is that their arrival is IGNORED rather
    /// than fatal — an unknown key is not a decode failure in Swift, so this pins
    /// the behaviour a reader would otherwise have to infer.
    func testThePriceFieldsAreIgnoredRatherThanModelled() throws {
        let row = try decode(
            SchedulingEventType.self,
            #"""
            {"id":"et_4","slug":"s","name":"n","duration_minutes":15,
             "price_cents":5000,"currency":"CAD"}
            """#
        )
        XCTAssertEqual(row.id, "et_4")
    }

    // MARK: - Bodies

    private static let populatedEventType = #"""
    {"id":"et_1","slug":"phone-consultation","name":"Phone consultation",
     "description":"A 30 minute call.","duration_minutes":30,"slot_interval_minutes":15,
     "location_type":"phone","location_value":"+14165550134","routing_mode":"round_robin",
     "rr_strategy":"priority","buffer_before_minutes":5,"buffer_after_minutes":10,
     "min_notice_minutes":120,"max_future_days":60,"max_active_bookings":3,
     "is_active":true,"show_taken_slots":true,"is_public":false,
     "created_at":"2026-09-01T10:00:00Z","msg_confirmation":"msg-confirmation",
     "msg_cancellation":"msg-cancellation","msg_reschedule":"msg-reschedule",
     "msg_reminder":"msg-reminder","msg_greeting":"msg-greeting",
     "subj_confirmation":"subj-confirmation","subj_cancellation":"subj-cancellation",
     "subj_reschedule":"subj-reschedule","subj_reminder":"subj-reminder",
     "reminders":[1440,60],"archived":false,"owned":true,
     "owner_name":"Contract Member","owner_email":"member@distronode.test"}
    """#

    private static let sparseEventType = #"""
    {"id":"et_2","slug":"site-visit","name":"Site visit","description":null,
     "duration_minutes":60,"location_type":"in_person","location_value":null,
     "is_active":false,"is_public":false,"created_at":"2026-09-02T10:00:00Z",
     "msg_confirmation":null,"msg_cancellation":null,"msg_reschedule":null,
     "msg_reminder":null,"msg_greeting":null,"subj_confirmation":null,
     "subj_cancellation":null,"subj_reschedule":null,"subj_reminder":null,
     "reminders":null,"archived":true}
    """#
}
