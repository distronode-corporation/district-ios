import Foundation

// The row DTOs for the scheduling admin's `bookings.*` namespace.
//
// ⛔ IN `DistrictModel` RATHER THAN BESIDE THE REPOSITORY, for the reason stated
// at the top of `SchedulingOverrideCreated.swift`: `ContractFixtureTests` depends
// on `ContractGateSupport` and `DistrictModel` and nothing else, so a wire type
// declared anywhere else is a wire type `StrictDecodeVerifier` cannot pin.
//
// ⚠️ SNAKE_CASE ON THE WIRE. These pass THROUGH our RPC from a scheduler fork
// that is not ours, so every key is spelled out in `CodingKeys` rather than
// converted. ⛔ Do not reach for `.convertFromSnakeCase` on the shared decoder:
// `ApiClient` uses a plain `JSONDecoder` for every route in the client, and
// changing it would re-map the whole District surface to chase these fields.

/// One person on a booking.
///
/// ⛔ BOTH FIELDS ARE OPTIONAL AND THE SERVER SCHEMA IS WHY, not caution. The
/// catalog's attendee object marks `name` and `email` `.optional()` — an
/// attendee row from a booking page that asked for neither carries neither — so
/// a non-optional here would throw on a legitimate booking rather than render a
/// row with a blank.
public struct SchedulingBookingAttendee: Codable, Sendable {
    public let name: String?
    public let email: String?
}

/// A booking, as every `bookings.*` op that answers one reports it.
///
/// ⛔ NO `payment_*` AND NO `amount_paid_*`, AND THEIR ABSENCE IS A DECISION
/// TAKEN ON THE SERVER RATHER THAN AN OMISSION HERE. `bookingSchema` in
/// `admin-ops.ts` drops the fork's three payment fields deliberately, so they do
/// not cross the RPC at all and a client that modelled them would be modelling a
/// key it can never receive. ⚠️ The strict gate would not catch that on its own:
/// an unused Optional is an ABSENT key on re-encode, which round-trips cleanly.
/// The pin is the schema, and this note is the pointer to it.
///
/// ⛔ ONLY FIVE FIELDS ARE GUARANTEED, WHICH IS THE OPPOSITE OF HOW A BOOKING
/// READS. `id`, `start_at`, `end_at` and `status` are the whole of what the
/// schema requires; everything else — including the EVENT TYPE and the HOST — is
/// `.optional()`. Row 1 of `district-scheduling-bookings.json` is that shape on
/// purpose: a cancelled booking with four keys and nothing else, which is what a
/// list built from a sparse index answers. A screen must be able to draw it.
///
/// ⚠️ `cancellation_reason` IS ABSENT ON A CONFIRMED BOOKING rather than null,
/// so the Optional means "not cancelled, or cancelled without a reason" and the
/// two are not distinguishable here. `status` is the field that decides.
public struct SchedulingBooking: Codable, Sendable {
    public let id: String
    public let eventTypeId: String?
    public let eventTypeSlug: String?
    public let hostId: String?
    public let hostName: String?
    /// RFC3339. ⚠️ Kept as a `String` for the reason every timestamp in this
    /// package is: one `JSONDecoder` date strategy would have to be right for
    /// every timestamp on the District surface, and they do not all agree.
    public let startAt: String
    public let endAt: String
    /// `confirmed`, `cancelled` or `rescheduled` today. ⚠️ A `String` rather than
    /// an enum, unlike ``SchedulingTenantStatus``: this column belongs to the
    /// fork, is not CHECK-constrained on our side, and a status this client does
    /// not know is a label to show rather than a booking list to refuse.
    public let status: String
    public let cancellationReason: String?
    /// The phone number, address or meeting URL the booking happens at. ⚠️ ONE
    /// FIELD FOR EVERY LOCATION KIND, so it is not safe to treat as a URL.
    public let locationValue: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let attendees: [SchedulingBookingAttendee]?

    enum CodingKeys: String, CodingKey {
        case id
        case eventTypeId = "event_type_id"
        case eventTypeSlug = "event_type_slug"
        case hostId = "host_id"
        case hostName = "host_name"
        case startAt = "start_at"
        case endAt = "end_at"
        case status
        case cancellationReason = "cancellation_reason"
        case locationValue = "location_value"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case attendees
    }
}

/// The two totals `bookings.list` reports beside its page.
///
/// ⚠️ THESE ARE THE WHOLE COLLECTION'S COUNTS AND NOT THE PAGE'S. A page of 50
/// upcoming bookings still reports the tenancy's `past` total, which is what lets
/// a tab bar label both sides without a second request.
public struct SchedulingBookingCounts: Codable, Sendable {
    public let upcoming: Int
    public let past: Int
}

/// One page of `bookings.list`.
///
/// ⛔ READ THE ECHO, NOT YOUR REQUEST. `limit` and `offset` come back because the
/// far end CLAMPS `limit` silently — the catalog refuses anything over 200 before
/// the request leaves us, but the scheduler may still return fewer than it was
/// asked for — so a pager that advanced by the value it sent would skip rows.
/// ⚠️ All four are `.optional()` in the schema and every one of them is absent on
/// some real answer, so a pager has to survive their absence rather than assume
/// the echo is always there.
public struct SchedulingBookingPage: Codable, Sendable {
    public let items: [SchedulingBooking]
    public let total: Int?
    public let counts: SchedulingBookingCounts?
    public let limit: Int?
    public let offset: Int?
}

/// One answer a booker gave to one of the event type's questions.
///
/// ⛔ `value` IS NON-OPTIONAL AND AN UNANSWERED OPTIONAL QUESTION IS `""`, NOT A
/// MISSING KEY. Row 1 of `district-scheduling-booking-answers.json` is exactly
/// that, and it is why the empty string has to be told apart from "the question
/// was not asked" by the ROW's presence rather than by the value.
///
/// ⚠️ `type` IS THE QUESTION'S INPUT KIND (`select`, `text`, …) AND NOT THE
/// ANSWER'S. Whatever the kind, `value` arrives as a string — a multi-select
/// answer is pre-joined by the fork — so nothing here should branch on `type` to
/// decide how to DECODE. It decides how to LABEL.
public struct SchedulingBookingAnswer: Codable, Sendable {
    public let questionId: String
    public let label: String
    public let type: String
    public let value: String

    enum CodingKeys: String, CodingKey {
        case questionId = "question_id"
        case label
        case type
        case value
    }
}

/// The meeting notes for a booking, as `bookings.notes` reports them.
///
/// ⛔ A DISCRIMINATED SHAPE, AND `exists:false` CARRIES NO OTHER KEY AT ALL. That
/// is why the other three are Optional: they are absent on the ordinary answer
/// for a booking that has not happened yet, which is most bookings. A client that
/// typed `content` non-null would throw on every future booking it opened.
///
/// ⚠️ `status` IS THE GENERATION'S STATE, NOT THE BOOKING'S — `ready` when the
/// notes are final, `pending` while the notetaker is still working. It is the
/// field that says whether `content` is worth showing yet, and it is NOT the same
/// vocabulary as ``SchedulingBooking/status``.
public struct SchedulingBookingNotes: Codable, Sendable {
    public let exists: Bool
    public let content: String?
    public let status: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case exists
        case content
        case status
        case updatedAt = "updated_at"
    }
}

/// What `bookings.notes.regenerate` answers.
///
/// ⛔ A THIRD SHAPE, AND IT IS NOT ``SchedulingBookingNotes`` WITH A NIL
/// `updated_at`. The regenerate response has no `updated_at` KEY in its schema at
/// all, so sharing the type would model a key the op never sends — harmless at
/// runtime and a dropped/added-key report the moment anyone gates the fixture,
/// which is exactly what the two separate fixtures here are for.
///
/// ⚠️ `status` IS ORDINARILY `pending` HERE, because the op kicks the generation
/// off rather than waiting for it. `content` is the PREVIOUS text, still standing
/// until the new one lands; treating it as the new notes shows a stale answer
/// with no indication that it is one.
public struct SchedulingBookingNotesRegenerated: Codable, Sendable {
    public let exists: Bool
    public let content: String?
    public let status: String?
}

/// The transcript of a booking's call, as `bookings.transcript` reports it.
///
/// ⚠️ SAME DISCRIMINATED SHAPE AS THE NOTES: `exists:false` and nothing else.
/// ⛔ This is raw customer speech, so it belongs to the same class of data as the
/// call recordings — the repository deliberately keeps it out of error text (see
/// the ⛔ on `SchedulingAdminRepository.decode`), and anything logging a failure
/// around this type must do the same.
public struct SchedulingBookingTranscript: Codable, Sendable {
    public let exists: Bool
    public let text: String?
}
