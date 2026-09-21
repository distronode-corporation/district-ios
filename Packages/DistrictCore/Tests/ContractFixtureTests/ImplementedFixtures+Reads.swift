import ContractGateSupport
import DistrictModel
import Foundation

/// The three read surfaces the billing, numbers and meetings batch gated.
///
/// ⛔ A SEPARATE FILE BECAUSE `ImplementedFixtures.swift` HIT SwiftLint'S 500-LINE
/// `file_length` CEILING, WHICH IS AN ERROR UNDER `--strict` RATHER THAN A
/// WARNING. Nothing about the register changed: `ImplementedFixtures.all`
/// concatenates these three groups with the fifteen over there,
/// `ContractFixtureTests` still requires every fixture on disk to be in exactly
/// one of the two lists, and the counted summary still counts all of them. This
/// is not a second register and must never become one.
///
/// ⚠️ `gate(_:_:)` HAD TO STOP BEING `private` FOR THIS TO COMPILE — a `private`
/// helper is FILE-private, so an extension in another file cannot call it. That
/// is the one visibility change the split cost.
///
/// ⚠️ A NEW GROUP BELONGS HERE RATHER THAN IN THE ORIGINAL FILE, which now sits a
/// handful of lines under the ceiling and will cross it again on the next batch.
extension ImplementedFixtures {
    // MARK: - Billing

    /// ⛔ FIVE FIXTURES, TWO ROUTES, THREE TYPES, AND THE ARITHMETIC IS THE
    /// POINT. `workspace/billing` has two bodies because a capped, unmetered
    /// workspace nulls two of its six keys; `/api/billing` has THREE because
    /// Stripe can be unreachable and an account can have no customer, and those
    /// two bodies are byte-identical apart from one ABSENT key. Five bodies, two
    /// endpoints — the widest fixture-to-endpoint gap in the corpus.
    ///
    /// ⛔ THE TWO DEGRADED BODIES ARE GATED SEPARATELY AGAINST THE SAME TYPE, AND
    /// THAT IS THE ASSERTION RATHER THAN A CONVENIENCE. The strict gate compares
    /// SHAPE, so it cannot tell them apart at all; what each gating proves is that
    /// ``StripeBilling`` decodes a body where nine of the fourteen healthy keys
    /// are missing — which is the moment a required field would fail, i.e.
    /// precisely when billing is already broken. The difference in MEANING is
    /// value-level and is asserted in `BillingContractTests`.
    ///
    /// ⛔ AND NOTHING HERE IS AN `ApiErrorEnvelope`. All three `/api/billing`
    /// bodies arrive on a **200** and all three are ANSWERS: modelling the
    /// degraded pair as an error envelope would be modelling a state as a
    /// failure, which is the confusion ``BillingAvailability`` exists to prevent.
    ///
    /// ⚠️ `district-workspace-billing.json`'s `usage` block is gated here through
    /// ``WorkspaceBillingResponse`` and separately through ``UsageResponse`` in
    /// the metered-usage group, because both routes call `getUsage` and the
    /// server asserts the payloads byte-identical. One ``UsageMonth`` decoding
    /// both surfaces is what keeps that true, and a divergence reds both groups.
    static var billing: [ImplementedFixture] {
        [
            gate("district-workspace-billing.json", WorkspaceBillingResponse.self),
            gate("district-workspace-billing-null-usage.json", WorkspaceBillingResponse.self),
            gate("district-billing.json", StripeBilling.self),
            gate("district-billing-unavailable.json", StripeBilling.self),
            gate("district-billing-no-customer.json", StripeBilling.self),
        ]
    }

    // MARK: - The phone-number marketplace

    /// ⛔ THREE FIXTURES AND NOT ONE NULL BETWEEN THEM, WHICH IS THE THING TO
    /// NOTICE HERE. Every optional field on this surface is an ABSENT KEY: a
    /// search result whose pricing lookup was swallowed by a bare catch, a
    /// toll-free row with no locality, a managed line with no webhook of ours to
    /// report. `JSON.stringify` drops an undefined rather than writing null, so
    /// these three need no `allowedExplicitNulls` entry and giving them one would
    /// be permitting a shape the server does not send.
    ///
    /// ⛔ THE OWNED PAIR IS THE DANGEROUS-MIDDLE PAIR, AND NEITHER FIXTURE MEANS
    /// ANYTHING WITHOUT THE OTHER. `partial` and `failedProviders` are ABSENT on
    /// a clean list and present on the degraded one, so the clean fixture proves
    /// the Optionals do not invent the keys back on re-encode and the partial one
    /// proves they decode at all. With only one of them a decoder could not tell
    /// the two states apart — and the state it would get wrong is a 200 carrying
    /// a SHORT list that draws exactly like a complete one.
    ///
    /// ⚠️ THE SEARCH FIXTURE'S SECOND ROW IS THE WHOLE REASON IT HAS TWO. Row 1
    /// omits `monthlyPrice`, `locality`, `region`, `setupPrice` and `currency`
    /// together, which is what an account without Pricing API access sees on
    /// every search.
    static var numbers: [ImplementedFixture] {
        [
            gate("district-numbers-search.json", NumberSearchResponse.self),
            gate("district-provider-numbers.json", OwnedNumbersResponse.self),
            gate("district-provider-numbers-partial.json", OwnedNumbersResponse.self),
        ]
    }

    // MARK: - Meetings the Companion wrote up

    /// ⛔ TWO FIXTURES, TWO TYPES, AND THEY ARE NOT SUBSETS OF ONE ANOTHER IN
    /// EITHER DIRECTION — which is exactly what gating both is for. The list
    /// RENAMES as it projects (`summary` becomes `summaryPreview` truncated to
    /// 220, `participants` becomes the integer `participantCount`), and the
    /// detail is the raw row and carries neither of those names while adding four
    /// the list never sends. A single type over both would have to make ten
    /// fields Optional and would decode either payload into a half-empty record.
    ///
    /// ⛔ NEITHER CARRIES AN ENVELOPE AND THEY DO NOT EVEN SHARE A TOP-LEVEL
    /// SHAPE: the list is a bare ARRAY, gated as `[MeetingSummary]`, and the
    /// detail is a bare OBJECT. That is why `meetings` is on
    /// ``BareArrayEndpoints`` and `meetingDetail` deliberately is not.
    ///
    /// ⚠️ THIS GROUP IS NOT `ImplementedFixtures.meetings`, WHICH IS A NAMING
    /// ACCIDENT OF THE CORPUS RATHER THAN A DUPLICATE. That one holds the two ROOM
    /// TOKEN bodies and some bare acknowledgements — joining a room — while these
    /// two are the archive of meetings that already happened.
    static var meetingRecords: [ImplementedFixture] {
        [
            gate("district-meetings.json", [MeetingSummary].self),
            gate("district-meeting-detail.json", MeetingDetail.self),
        ]
    }
}
