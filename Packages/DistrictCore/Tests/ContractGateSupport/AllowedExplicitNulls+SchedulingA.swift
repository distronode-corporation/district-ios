import Foundation

// The event-type and availability halves of the scheduling admin corpus, in a file
// of their own.
//
// ⛔ IN `ContractGateSupport` AND NOT IN `ContractFixtureTests`, WHICH IS NOT A
// FILING PREFERENCE. `StrictDecodeVerifier.verify` reads `allowedExplicitNulls`
// from inside this module; a group declared in the test target would be invisible
// to it, every null here would fail the gate, and the reason would not be anywhere
// near the file that looked correct.
//
// ⛔ AND THE `.merging(schedulingA)` IN `AllowedExplicitNulls+Union.swift` IS HALF
// OF THIS CHANGE. A group declared here and not chained there exempts nothing at
// all — the table is composed pairwise, and an unmerged group is simply never
// consulted, so its fixtures fail for a reason nobody would look for. The union
// traps on a duplicate key rather than picking a side, which is what makes adding
// a fourth and a fifth group safe.
//
// ⛔ THIRTY-FOUR PATHS ACROSS NINE OF TWELVE FIXTURES, ENUMERATED FROM THE FIXTURE
// BYTES RATHER THAN INFERRED FROM THE DTOs. The other three carry no null anywhere
// and must not be given an entry: `district-scheduling-hosts.json`,
// `-test-email.json` and `-override-range.json`. Their optionals are ABSENT keys,
// which a nil `Optional` already round-trips, so permission there would silence a
// null the server does not send today and would keep silencing it the day it
// starts to.
//
// ⚠️ THE COUNT IS ASSERTED BY `ContractManifest.expectedAllowedNullPaths`, never by
// this comment.

extension StrictDecodeVerifier {
    /// ⛔ TWENTY-FOUR OF THE THIRTY-FOUR ARE THE SAME TWELVE COLUMNS WRITTEN TWICE,
    /// and that repetition is the mechanism rather than a copy-paste.
    /// `district-scheduling-event-types.json`'s second row and
    /// `district-scheduling-event-type.json` are the same sparse event type served
    /// by the list op and the get op; if the two ever disagree, the entries fail
    /// separately and say which surface moved. Collapsing them behind a wildcard
    /// would make the number read as 12 and would also silence a row that does not
    /// exist yet.
    ///
    ///   description       `EventType.description`, nullable. The event type with
    ///                     no blurb is the ordinary one, not the edge.
    ///   location_value    Nullable AND polymorphic — it holds a URL, a phone
    ///                     number or an address depending on `location_type`, and
    ///                     nothing at all for the three location types the
    ///                     scheduler generates itself. `in_person` with no address
    ///                     yet is what row 1 is.
    ///   msg_*  (5)        The five body templates. A null is "use the scheduler's
    ///                     default", NOT "send an empty email", which is why the
    ///                     DTO keeps the Optional rather than defaulting to "".
    ///   subj_* (4)        The four subject lines, same reading.
    ///   reminders         Go `[]int` with no `omitempty`, so a nil slice marshals
    ///                     as `null`. ⛔ Null and `[]` are DIFFERENT: `[]` is every
    ///                     reminder turned off, null is never configured.
    ///
    /// ⚠️ THE FIRST ROW OF THE LIST CARRIES NO NULL AT ALL and has no entry. It is
    /// the fully-populated event type, and the pair is a near-complement on
    /// purpose — the gate is proving that a DTO which regressed any of these
    /// twelve Optionals to non-null fails on one row while still passing on the
    /// other.
    static let schedulingA: [String: Set<String>] = [
        "district-scheduling-event-types.json": [
            "$.data.items[1].description",
            "$.data.items[1].location_value",
            "$.data.items[1].msg_cancellation",
            "$.data.items[1].msg_confirmation",
            "$.data.items[1].msg_greeting",
            "$.data.items[1].msg_reminder",
            "$.data.items[1].msg_reschedule",
            "$.data.items[1].reminders",
            "$.data.items[1].subj_cancellation",
            "$.data.items[1].subj_confirmation",
            "$.data.items[1].subj_reminder",
            "$.data.items[1].subj_reschedule",
        ],
        "district-scheduling-event-type.json": [
            "$.data.description",
            "$.data.location_value",
            "$.data.msg_cancellation",
            "$.data.msg_confirmation",
            "$.data.msg_greeting",
            "$.data.msg_reminder",
            "$.data.msg_reschedule",
            "$.data.reminders",
            "$.data.subj_cancellation",
            "$.data.subj_confirmation",
            "$.data.subj_reminder",
            "$.data.subj_reschedule",
        ],
        // ── Booking questions ───────────────────────────────────────────────
        //
        //   options  `Question.options`, a nullable array. NULL ON EVERY
        //            NON-`select` QUESTION, which is most of them — a `text`
        //            question has nothing to offer. ⚠️ The row that is a `select`
        //            carries a real array and has no entry, which is the pair that
        //            proves the Optional in both directions.
        "district-scheduling-questions.json": [
            "$.data.items[1].options",
        ],
        "district-scheduling-question.json": [
            "$.data.options",
        ],
        // ── Slots ───────────────────────────────────────────────────────────
        //
        //   host_ids  Null on a `fixed` event type, where there is one host and the
        //             slot does not name them. ⛔ Reading that null as "nobody is
        //             available" would hide every slot on the commonest routing
        //             mode there is. ⚠️ TWO PATHS FROM TWO DIFFERENT ARRAYS: the
        //             offered window and the TAKEN one, which only appears at all
        //             when the event type opted into `show_taken_slots`.
        "district-scheduling-slots.json": [
            "$.data.slots[1].host_ids",
            "$.data.taken[0].host_ids",
        ],
        // ── Weekly availability rules ───────────────────────────────────────
        //
        //   event_type_id  ⛔ THE NULL IS THE LOAD-BEARING VALUE: it means the rule
        //                  applies to EVERY event type the member hosts, not that
        //                  the rule is unattached. It is `.nullable()` with no
        //                  `.optional()` in the catalog, so the key is always on
        //                  the wire and the null is always explicit. A screen that
        //                  filtered these out would hide the default working week,
        //                  which is the only rule most tenancies ever create.
        "district-scheduling-rules.json": [
            "$.data.items[1].event_type_id",
        ],
        "district-scheduling-rule.json": [
            "$.data.event_type_id",
        ],
        // ── Dated availability overrides ────────────────────────────────────
        //
        //   start_time  `Override.start_time`. Null on an ALL-DAY block, which is
        //   end_time    what `day_off` and `out_of_office` always are; only
        //               `custom_hours` carries a pair. Both columns are
        //               `.nullable()` and non-optional in the catalog, so the keys
        //               are always present.
        //
        // ⚠️ `group_id` IS **NOT** LISTED AND MUST NOT BE. It is ABSENT on a
        // standalone override rather than null, which is the shape a nil Optional
        // already round-trips — and it is the field that makes
        // `availability.overrides.deleteGroup` addressable, so a null nobody has
        // seen is exactly the thing this register should keep loud.
        "district-scheduling-overrides.json": [
            "$.data.items[1].end_time",
            "$.data.items[1].start_time",
        ],
        // ⚠️ THE CREATE ECHO IS THE ROW ARM OF A UNION, and its sibling
        // `district-scheduling-override-range.json` is the OTHER arm — a summary
        // with no `id` and no times at all, and therefore no entry here. The two
        // fixtures exist to keep those apart.
        "district-scheduling-override-created.json": [
            "$.data.end_time",
            "$.data.start_time",
        ],
    ]
}
