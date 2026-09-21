import DistrictModel
import DistrictNetwork
import Foundation

/// The `bookings.*` namespace, typed.
///
/// ⛔ THESE WRAPPERS ADD EXACTLY TWO THINGS AND MUST NOT GROW A THIRD: the op
/// NAME and the response TYPE. `SchedulingAdminRepository.perform` is generic
/// because the server owns the catalog — the scheduler path, the HTTP verb and
/// the params schema all live in `admin-ops.ts` — and the one thing a caller
/// cannot get wrong from Swift is which type an op answers, because that pairing
/// crosses the wire as nothing at all. A mismatched type is a runtime
/// `SchedulingAdminError.decoding`, not a compile error, so pairing them ONCE
/// here is what makes it a compile error everywhere else.
///
/// ⛔ AND NOTHING HERE VALIDATES `params`. The catalog's zod schema is the only
/// validator and it runs server-side; a second, laxer copy on this side would
/// refuse bodies the server accepts or accept bodies it rejects. Every parameter
/// below is passed through verbatim, PATH KEYS INCLUDED — `bookings.cancel` sends
/// `id` in the body even though the server puts it in the path, because the
/// server validates the body BEFORE stripping it and a helpfully-removed `id` is
/// a 400 naming the field.
///
/// ⚠️ THE OPTIONAL FILTERS ARE DROPPED WHEN NIL RATHER THAN SENT AS NULL.
/// `JSONValue.object(_:)` does that by construction; the catalog's filters are
/// `.optional()` and an explicit null would fail validation rather than mean "no
/// filter".
public extension SchedulingAdminRepository {
    /// `bookings.list` — one page of the tenancy's bookings.
    ///
    /// ⚠️ `eventTypeSlug` IS A SLUG AND NOT AN ID, and an unknown one is an empty
    /// 200 rather than a 404, so an empty page is not evidence the filter was
    /// understood.
    ///
    /// - Parameter allHosts: sends the catalog's `scope: "all"`. ⛔ HONOURED ONLY
    ///   FOR A SCHEDULER ADMIN AND SILENTLY IGNORED OTHERWISE, so a screen must
    ///   not present the result as the whole tenancy's bookings on the strength of
    ///   having asked. `false` omits the key entirely, which is what the catalog's
    ///   `z.literal("all")` requires — there is no other legal value.
    /// - Parameter limit: refused above 200 by the catalog before the request
    ///   leaves us, and clamped silently at the far end besides. Read
    ///   ``SchedulingBookingPage/limit`` back rather than assuming this value held.
    func bookings(
        workspaceId: String,
        status: String? = nil,
        when: String? = nil,
        from: String? = nil,
        to: String? = nil,
        eventTypeSlug: String? = nil,
        host: String? = nil,
        team: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        allHosts: Bool = false,
        order: String? = nil
    ) async throws -> SchedulingBookingPage {
        try await perform(
            .bookingsList,
            workspaceId: workspaceId,
            params: .object([
                ("status", .optional(status)),
                ("when", .optional(when)),
                ("from", .optional(from)),
                ("to", .optional(to)),
                ("event_type", .optional(eventTypeSlug)),
                ("host", .optional(host)),
                ("team", .optional(team)),
                ("limit", limit.map(JSONValue.integer)),
                ("offset", offset.map(JSONValue.integer)),
                ("scope", allHosts ? .string("all") : nil),
                ("order", .optional(order)),
            ]),
            as: SchedulingBookingPage.self
        )
    }

    /// `bookings.answers` — what the booker typed into the event type's questions.
    func bookingAnswers(workspaceId: String, bookingId: String) async throws -> [SchedulingBookingAnswer] {
        try await perform(
            .bookingsAnswers,
            workspaceId: workspaceId,
            params: .object([("id", .string(bookingId))]),
            as: SchedulingItems<SchedulingBookingAnswer>.self
        ).items
    }

    /// `bookings.cancel` — cancel a booking, and get the cancelled row back.
    ///
    /// ⚠️ THE ANSWER IS THE BOOKING, NOT AN ACKNOWLEDGEMENT, so the caller should
    /// replace its row from the response rather than mutating its own copy's
    /// status — `updated_at` and `cancellation_reason` both move, and the far end
    /// may normalise the reason it was sent.
    func cancelBooking(
        workspaceId: String,
        bookingId: String,
        reason: String? = nil
    ) async throws -> SchedulingBooking {
        try await perform(
            .bookingsCancel,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(bookingId)),
                ("reason", .optional(reason)),
            ]),
            as: SchedulingBooking.self
        )
    }

    /// `bookings.reschedule` — move a booking to a new start.
    ///
    /// ⛔ NO END TIME, AND SENDING ONE IS NOT AN OPTION THE SCHEMA OFFERS. The far
    /// end recomputes the end from the event type's duration, which is what keeps
    /// a rescheduled booking consistent with the event type it belongs to.
    /// ⚠️ A `slot_taken` failure arrives as a **200** carrying `{ok:false}` — see
    /// ``SchedulingAdminFailureCode/slotTaken`` — because the request was
    /// perfectly valid and it is the SCHEDULER that refused.
    func rescheduleBooking(
        workspaceId: String,
        bookingId: String,
        startAt: String
    ) async throws -> SchedulingBooking {
        try await perform(
            .bookingsReschedule,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(bookingId)),
                ("start_at", .string(startAt)),
            ]),
            as: SchedulingBooking.self
        )
    }

    /// `bookings.reassign` — hand a booking to a different host.
    ///
    /// ⚠️ `hostId` IS A SCHEDULER USER'S ID (``SchedulingUser/id``), not a
    /// Distronode member id. The two populations are different; see the note at the
    /// top of `SchedulingAdminTeam.swift`.
    func reassignBooking(
        workspaceId: String,
        bookingId: String,
        hostId: String
    ) async throws -> SchedulingBooking {
        try await perform(
            .bookingsReassign,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(bookingId)),
                ("host_id", .string(hostId)),
            ]),
            as: SchedulingBooking.self
        )
    }

    /// `bookings.notes` — the meeting notes, if any have been generated.
    ///
    /// ⚠️ `exists:false` IS AN ORDINARY 200 AND NOT AN ERROR. Most bookings have
    /// no notes, and the discriminated shape is why
    /// ``SchedulingBookingNotes/content`` is Optional.
    func bookingNotes(workspaceId: String, bookingId: String) async throws -> SchedulingBookingNotes {
        try await perform(
            .bookingsNotes,
            workspaceId: workspaceId,
            params: .object([("id", .string(bookingId))]),
            as: SchedulingBookingNotes.self
        )
    }

    /// `bookings.notes.regenerate` — ask for the notes to be written again.
    ///
    /// ⛔ ITS ANSWER IS A THIRD SHAPE AND CARRIES NO `updated_at`, which is why it
    /// does not share ``SchedulingBookingNotes``. ⚠️ It returns as soon as the work
    /// is QUEUED — `status` is ordinarily `pending` and `content` is still the
    /// previous text — so a screen that rendered it as the new notes would show a
    /// stale answer with nothing marking it stale.
    func regenerateBookingNotes(
        workspaceId: String,
        bookingId: String
    ) async throws -> SchedulingBookingNotesRegenerated {
        try await perform(
            .bookingsNotesRegenerate,
            workspaceId: workspaceId,
            params: .object([("id", .string(bookingId))]),
            as: SchedulingBookingNotesRegenerated.self
        )
    }

    /// `bookings.transcript` — the call's transcript, if one was captured.
    ///
    /// ⛔ RAW CUSTOMER SPEECH. It must never reach an error string, a log line or
    /// an analytics event; the repository's decode failure deliberately reports a
    /// byte count and the op name and nothing else, for exactly this response.
    func bookingTranscript(workspaceId: String, bookingId: String) async throws -> SchedulingBookingTranscript {
        try await perform(
            .bookingsTranscript,
            workspaceId: workspaceId,
            params: .object([("id", .string(bookingId))]),
            as: SchedulingBookingTranscript.self
        )
    }
}
