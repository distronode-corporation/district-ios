import DistrictModel
import Foundation

// The scheduling admin's BOOKINGS, CALENDAR and TEAM row DTOs, in a file of its own.
//
// ⛔ SPLIT OUT BECAUSE `ImplementedFixtures.swift` IS AT ITS 500-LINE CEILING, the
// same reason `+MessageThread.swift` and `+SchedulingAdmin.swift`
// were. SwiftLint's `file_length` warning is an ERROR under `--strict`, so a line
// added inline reds the LINT job rather than the gate — a failure a long way from
// the change that caused it.

extension ImplementedFixtures {
    // MARK: - Bookings, calendars and the tenancy's people

    /// ⛔ SIXTEEN FIXTURES, AND EVERY ONE OF THEM IS GATED THROUGH
    /// ``SchedulingAdminSuccess`` RATHER THAN AGAINST THE ROW TYPE DIRECTLY. The
    /// bytes on disk are the whole RPC envelope, `{ok, data}`, because that is what
    /// `POST /api/district/scheduling/admin` puts on the wire — and the gate
    /// compares KEY SETS, so a fixture gated against the row alone would be
    /// reported as two dropped keys before it ever looked at the row. The four
    /// envelope fixtures in `+SchedulingAdmin` prove the wrapper; these sixteen are
    /// payloads carried inside it.
    ///
    /// ⛔ THREE ENVELOPE CONVENTIONS ARE VISIBLE IN THIS LIST AND THE TYPES ARE
    /// WHERE THEY ARE PINNED. `bookings.answers`, `users.upcomingBookings` and
    /// `teams.list` answer `{items:[…]}` (``SchedulingItems``);
    /// `calendar.connections.calendars.get` answers `{calendars:[…]}`, a container
    /// with a different key (``SchedulingCalendarSelections``); and `users.list`
    /// answers a **bare array**, which is why its payload type is `[SchedulingUser]`
    /// with no container at all. Guessing any one of them from the op's shape gets
    /// it wrong a third of the time.
    ///
    /// ⛔ `bookings.list` LOOKS LIKE THE FIRST CONVENTION AND IS NOT. It carries
    /// `items` and also `total`, `counts`, `limit` and `offset`, so
    /// ``SchedulingItems`` would drop four keys; ``SchedulingBookingPage`` is its
    /// own type for that reason and not for tidiness.
    ///
    /// ⚠️ THE TWO NOTES FIXTURES AND THE TWO TEAM FIXTURES ARE EACH A PAIR THAT
    /// MUST STAY SEPARATE. `-booking-notes.json` and `-booking-notes-regenerated.json`
    /// are structurally different bodies from two ops — the regenerate response has
    /// no `updated_at` KEY in its schema at all — so sharing a type would model a
    /// key one op never sends. `-teams.json` and `-team.json` are the SAME team seen
    /// through `teams.list` and `teams.get`, and pinning both is what makes either
    /// read failing visible on its own.
    ///
    /// ⛔ `district-scheduling-ok.json` IS BYTE-IDENTICAL TO
    /// `district-scheduling-no-content.json` — both are `{"ok":true,"data":{"ok":true}}`,
    /// which is easy to get wrong from the names alone (it is NOT a bare
    /// `{"ok":true}`). It is gated against the same
    /// ``SchedulingNoContent``, and the duplication is worth keeping: they reach the
    /// client by different routes (`teams.delete` and `teams.members.remove` answer
    /// a real 200 `{ok:true}`; the catalog's `NO_CONTENT` REWRITES a 204 into the
    /// same object), so the day either source changes shape, the fixture belonging
    /// to it fails alone.
    ///
    /// ⚠️ THREE OF THE SIXTEEN CARRY AN EXPLICIT NULL and are gated anyway, through
    /// exact `allowedExplicitNulls` paths in `AllowedExplicitNulls+SchedulingB.swift`
    /// — `$.data[1].teams` on the users list, and `members` on both team bodies. The
    /// other thirteen carry none, checked against the fixture BYTES rather than
    /// inferred from the DTOs: every optional on them is an ABSENT key, which a nil
    /// Optional already round-trips.
    static var schedulingB: [ImplementedFixture] {
        bookingFixtures + calendarFixtures + teamFixtures
    }

    /// ⚠️ ROW 1 OF THE LIST IS THE POINT OF THE LIST. It is a cancelled booking
    /// carrying four keys and nothing else — no event type, no host, no attendees —
    /// because only `id`, `start_at`, `end_at` and `status` are required by
    /// `bookingSchema`. A DTO that typed the event type or the host non-optional
    /// passes every other fixture here and fails on that row.
    private static var bookingFixtures: [ImplementedFixture] {
        [
            gate("district-scheduling-bookings.json", SchedulingAdminSuccess<SchedulingBookingPage>.self),
            gate("district-scheduling-booking.json", SchedulingAdminSuccess<SchedulingBooking>.self),
            gate(
                "district-scheduling-booking-answers.json",
                SchedulingAdminSuccess<SchedulingItems<SchedulingBookingAnswer>>.self
            ),
            gate("district-scheduling-booking-notes.json", SchedulingAdminSuccess<SchedulingBookingNotes>.self),
            gate(
                "district-scheduling-booking-notes-regenerated.json",
                SchedulingAdminSuccess<SchedulingBookingNotesRegenerated>.self
            ),
            gate(
                "district-scheduling-booking-transcript.json",
                SchedulingAdminSuccess<SchedulingBookingTranscript>.self
            ),
        ]
    }

    /// ⚠️ ROW 1 OF `-calendars.json` IS A SUBSCRIPTION CALENDAR WITH TWO KEYS —
    /// `id` and `name` — and every Google account has one. All four flags on
    /// ``SchedulingCalendarSelection`` are Optional because of that row.
    private static var calendarFixtures: [ImplementedFixture] {
        [
            gate("district-scheduling-calendar-status.json", SchedulingAdminSuccess<SchedulingCalendarStatus>.self),
            gate("district-scheduling-caldav-connect.json", SchedulingAdminSuccess<SchedulingCaldavConnection>.self),
            gate("district-scheduling-calendars.json", SchedulingAdminSuccess<SchedulingCalendarSelections>.self),
            gate("district-scheduling-zoom-status.json", SchedulingAdminSuccess<SchedulingZoomStatus>.self),
        ]
    }

    /// ⚠️ THE USERS FIXTURE HOLDS BOTH ARCHIVE BRANCHES: row 0 is active and
    /// carries neither `archived_at` nor `archived_by_name` (ABSENT, not null), row
    /// 1 is archived and carries both. A DTO regressed to non-null on either fails
    /// here rather than on a phone.
    private static var teamFixtures: [ImplementedFixture] {
        [
            gate("district-scheduling-users.json", SchedulingAdminSuccess<[SchedulingUser]>.self),
            gate("district-scheduling-user-archive.json", SchedulingAdminSuccess<SchedulingUserArchived>.self),
            gate(
                "district-scheduling-user-upcoming.json",
                SchedulingAdminSuccess<SchedulingItems<SchedulingUpcomingBooking>>.self
            ),
            gate("district-scheduling-teams.json", SchedulingAdminSuccess<SchedulingItems<SchedulingTeam>>.self),
            gate("district-scheduling-team.json", SchedulingAdminSuccess<SchedulingTeam>.self),
            gate("district-scheduling-ok.json", SchedulingAdminSuccess<SchedulingNoContent>.self),
        ]
    }
}
