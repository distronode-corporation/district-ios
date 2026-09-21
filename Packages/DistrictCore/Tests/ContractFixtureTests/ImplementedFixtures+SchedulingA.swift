import DistrictModel
import Foundation

// The scheduling admin's EVENT TYPE and AVAILABILITY payloads.
//
// ⛔ SPLIT OUT BECAUSE `ImplementedFixtures.swift` IS AT ITS 500-LINE CEILING, the
// same reason `+MessageThread.swift` and `+SchedulingAdmin.swift`
// were. SwiftLint's `file_length` warning is an ERROR under `--strict`, so a line
// added inline reds the LINT job rather than the gate — a failure a long way from
// the change that caused it.

extension ImplementedFixtures {
    // MARK: - Event types, and the availability they are booked against

    /// ⛔ TWELVE FIXTURES, AND EVERY ONE OF THEM IS WRAPPED IN
    /// ``SchedulingAdminSuccess`` RATHER THAN GATED AGAINST THE ROW DIRECTLY. The
    /// route answers `{ok, data}` for all 75 ops; a fixture gated against
    /// `SchedulingEventType` alone would fail on two unknown keys at the top level,
    /// and "fixing" that by unwrapping the fixture would retire the one assertion
    /// that the envelope's `ok` flag is still on the wire. The envelope group's
    /// `district-scheduling-no-content.json` makes the same point from the other
    /// end.
    ///
    /// ⛔ THE LIST OPS GO THROUGH `SchedulingItems`, WHICH IS NOT THE UNIVERSAL LIST
    /// ENVELOPE ON THIS SURFACE. The catalog's `items(T)` helper wraps eight reads;
    /// `recordings.list` and `recordings.consent` declare their key by hand and are
    /// not this group's. `eventTypes.slots` is a third shape again — three keys of
    /// its own, none of them `items` — which is why ``SchedulingSlots`` exists
    /// rather than a fourth reuse.
    ///
    /// ⛔ THE TWO OVERRIDE-CREATE FIXTURES ARE THE TWO ARMS OF ONE UNION AND ARE
    /// PINNED SEPARATELY ON PURPOSE. `-override-created.json` is a row;
    /// `-override-range.json` is `{group_id, reason, start, end, days}` with no `id`
    /// at all, and `start`/`end` there are DATES rather than the `HH:MM` times the
    /// row carries. ``SchedulingOverrideCreated`` disambiguates on `id`, not on
    /// `group_id` — a row created as part of a range CARRIES a group id — and the
    /// gate re-encodes, so an `encode(to:)` that wrapped either arm in a
    /// discriminator would fail here and nowhere else.
    ///
    /// ⚠️ `-overrides.json` AND `-override-created.json` DECODE THE SAME ROW TYPE
    /// AND ARE STILL BOTH LISTED. The list op and the create op are different ops
    /// with different envelopes (`items` versus a bare row), and the day either
    /// grows a key, only one of them should fail.
    ///
    /// ⛔ NINE OF THE TWELVE CARRY EXPLICIT NULLS, through 34 exact paths in
    /// `AllowedExplicitNulls+SchedulingA.swift`. The three that do not —
    /// `-hosts.json`, `-test-email.json`, `-override-range.json` — must NOT be
    /// given an entry: their optionals are absent keys, which a nil `Optional`
    /// already round-trips.
    static var schedulingA: [ImplementedFixture] {
        eventTypeFixtures + availabilityFixtures
    }

    /// ⚠️ THE LIST AND THE GET ARE THE SAME ROW TYPE FROM TWO OPS, and the pair is
    /// a near-complement: the list's first row is fully populated, its second and
    /// the get's single row null the same twelve columns. A DTO that regressed any
    /// of those Optionals to non-null fails on one and passes on the other, which
    /// is what makes the failure legible.
    private static var eventTypeFixtures: [ImplementedFixture] {
        [
            gate(
                "district-scheduling-event-types.json",
                SchedulingAdminSuccess<SchedulingItems<SchedulingEventType>>.self
            ),
            gate("district-scheduling-event-type.json", SchedulingAdminSuccess<SchedulingEventType>.self),
            gate(
                "district-scheduling-hosts.json",
                SchedulingAdminSuccess<SchedulingItems<SchedulingHost>>.self
            ),
            // ⚠️ THE ONLY TWO-FIELD PAYLOAD IN THE FAMILY, and it is gated rather
            // than skipped because `sent` is a Bool the fork could plausibly start
            // spelling as a status string.
            gate("district-scheduling-test-email.json", SchedulingAdminSuccess<SchedulingTestEmailResult>.self),
            gate(
                "district-scheduling-questions.json",
                SchedulingAdminSuccess<SchedulingItems<SchedulingQuestion>>.self
            ),
            gate("district-scheduling-question.json", SchedulingAdminSuccess<SchedulingQuestion>.self),
            gate("district-scheduling-slots.json", SchedulingAdminSuccess<SchedulingSlots>.self),
        ]
    }

    /// ⚠️ FIVE FIXTURES, FOUR OPS. `-overrides.json` and `-override-created.json`
    /// share ``SchedulingAvailabilityOverride``; the fifth is the other arm of the
    /// create union.
    private static var availabilityFixtures: [ImplementedFixture] {
        [
            gate(
                "district-scheduling-rules.json",
                SchedulingAdminSuccess<SchedulingItems<SchedulingAvailabilityRule>>.self
            ),
            gate("district-scheduling-rule.json", SchedulingAdminSuccess<SchedulingAvailabilityRule>.self),
            gate(
                "district-scheduling-overrides.json",
                SchedulingAdminSuccess<SchedulingItems<SchedulingAvailabilityOverride>>.self
            ),
            gate(
                "district-scheduling-override-created.json",
                SchedulingAdminSuccess<SchedulingOverrideCreated>.self
            ),
            gate("district-scheduling-override-range.json", SchedulingAdminSuccess<SchedulingOverrideCreated>.self),
        ]
    }
}
