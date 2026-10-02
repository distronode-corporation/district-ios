import DistrictModel
import Foundation
import SwiftUI

// The three cards built from OUR OWN database: the plan, how overage is handled, and
// this month's minutes.
//
// ⛔ NOT ONE OF THESE TOUCHES STRIPE, WHICH IS WHY THEY ARE GROUPED. Every value here
// comes from `GET /api/district/workspace/billing`, so this half of the screen renders
// correctly during a Stripe outage, and it is the half a customer needs then: which
// plan, whether it is in good standing, and whether an overage cap is blocking their
// calls right now. The vendor-backed cards live in `BillingStripeCards.swift`.
//
// ⛔ NOTHING HERE MUTATES ANYTHING AND NOTHING MAY. App Store Review Guideline 3.1.3(b),
// not a preference. See `BillingView`.
//
// ⚠️ A REGULAR COMMENT RATHER THAN A DOC ONE, because it documents the FILE and no
// declaration follows it directly. SwiftFormat's `docComments` rule rejects a `///` block
// that is not attached to an API declaration, so a file-level note has to be written this
// way or `swiftformat --lint` reds.

/// The headline: which plan, and whether it is in good standing.
///
/// ⛔ A NULL TIER IS NOT "Free". The column is nullable and the route passes it through
/// untouched, so the honest rendering is "no plan on this workspace" rather than a plan
/// name this client invented. `GET /api/settings` substitutes a capitalised "Free" for
/// its own callers and this route deliberately does not; mirroring that substitution here
/// would put a word on screen that no row contains.
struct BillingPlanCard: View {
    let plan: WorkspaceBilling

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        DistrictCard(eyebrow: BillingCopy.planTitle) {
            HStack(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight) {
                Text(plan.subscriptionTier ?? BillingCopy.planNone)
                    .font(DistrictType.metric)
                    .foregroundStyle(colors.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DistrictBadge(text: Self.label(plan.subscriptionStatus), tone: Self.tone(plan.subscriptionStatus))
            }
            // ⚠️ EXPLAINS THE BADGE RATHER THAN REPEATING IT. "Past due" is a Stripe word;
            // what a customer needs to know is what it means for their service.
            if let caption = Self.caption(plan.subscriptionStatus) {
                BillingNote(text: caption)
            }
        }
        // ⚠️ NO `.contain` HERE, UNLIKE THE SCREEN ROOTS, AND THE DIFFERENCE IS
        // DELIBERATE. This card holds no separately-addressed descendant, and a
        // smoke run wants to read the TIER off it, leaving the children merged
        // means the identifier resolves to an element whose label carries the plan
        // name, so one query answers both "is the card there" and "which plan".
        .accessibilityIdentifier(A11yID.Billing.plan)
    }

    /// ⚠️ THE WIRE VALUES, MAPPED IN ONE PLACE, and an unrecognised one falls through to
    /// the neutral label rather than to a guess. `subscriptionStatus` is free text
    /// server-side with no enum behind it, so a fifth value is a schema-level
    /// possibility: the same "unknown means no claim" rule ``WorkspaceRole/fromWire(_:)``
    /// applies to privileges.
    private static func label(_ status: String) -> String {
        switch BillingFormat.normalisedStatus(status) {
        case BillingFormat.subscriptionStatusActive: BillingCopy.statusActive
        case BillingFormat.subscriptionStatusPastDue: BillingCopy.statusPastDue
        case BillingFormat.subscriptionStatusCanceled: BillingCopy.statusCanceled
        default: BillingCopy.statusNone
        }
    }

    /// ⛔ `past_due` AND `canceled` ARE WARNINGS, NOT ERRORS. Neither is an app fault and
    /// neither is something the customer can fix by tapping, so a destructive tone would
    /// read as a failure of the app rather than as a state of the account. Warning is the
    /// tone that says "this needs attention somewhere else", which is what is true.
    private static func tone(_ status: String) -> Tone {
        switch BillingFormat.normalisedStatus(status) {
        case BillingFormat.subscriptionStatusActive: .success
        case BillingFormat.subscriptionStatusPastDue, BillingFormat.subscriptionStatusCanceled: .warning
        default: .neutral
        }
    }

    private static func caption(_ status: String) -> String? {
        switch BillingFormat.normalisedStatus(status) {
        case BillingFormat.subscriptionStatusPastDue: BillingCopy.statusPastDueCaption
        case BillingFormat.subscriptionStatusCanceled: BillingCopy.statusCanceledCaption
        default: nil
        }
    }
}

/// How the workspace handles going over its included minutes, and whether it already has.
///
/// ⛔ THE POLICY AND THE FLAG MUST BE READ TOGETHER, AND THE COMBINATION IS THE WHOLE
/// CARD. Under `auto_bill` an exceeded cap means the overage is being charged: a billing
/// note. Under `hard_cap` it means **calls are being refused right now**, an outage the
/// operator is living through with no other way to learn about it from this app.
/// Rendering the flag without the policy states neither fact; rendering the policy
/// without the flag states a rule rather than a condition.
///
/// ⚠️ THE BLOCKED BRANCH READS ``WorkspaceBilling/callsAreBeingRefused`` RATHER THAN
/// RE-DERIVING IT. That property exists so the question is asked once and cannot be asked
/// by halves.
struct BillingOverageCard: View {
    let plan: WorkspaceBilling

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var hardCap: Bool {
        plan.overagePolicy == WorkspaceBilling.overagePolicyHardCap
    }

    var body: some View {
        DistrictCard(eyebrow: BillingCopy.overageTitle) {
            Text(hardCap ? BillingCopy.overageHardCap : BillingCopy.overageAutoBill)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            // ⛔ TWO DIFFERENT SENTENCES FOR THE SAME FLAG. "Calls are being declined" and
            // "you are over your included minutes and the extra is being billed" are not
            // the same news, and the first is the reason this screen is worth having on a
            // phone at all.
            if plan.overageCapExceeded {
                DistrictBadge(text: exceededText, tone: plan.callsAreBeingRefused ? .danger : .warning)
            }
        }
    }

    private var exceededText: String {
        plan.callsAreBeingRefused ? BillingCopy.overageBlocked : BillingCopy.overageExceeded
    }
}

/// Call minutes used this month, against the plan's allowance when both are known.
///
/// ⛔ THREE DISTINCT STATES, AND COLLAPSING ANY TWO OF THEM STATES SOMETHING FALSE:
///
/// - **Nothing metered** (`usage: null`, or both minute metrics absent) is a sentence,
///   never a zero. A "0 minutes" beside an allowance asserts, with the authority of a
///   bill, that the workspace made no calls; the honest claim is that nothing has been
///   recorded yet.
/// - **Minutes but no allowance** is the number alone, with no bar. The allowance lives
///   on the STRIPE half, so this is what an outage looks like, and a bar drawn against an
///   unknown allowance would have to invent a denominator.
/// - **Both** is the bar, plus a label carrying the REAL numbers even when they exceed
///   the allowance. See ``BillingFormat/meterFraction(used:included:)``: the bar clamps
///   and the label does not.
struct BillingUsageMeterCard: View {
    let usage: UsageMonth?
    let included: Int?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        DistrictCard(eyebrow: BillingCopy.meterTitle) {
            if let used = BillingFormat.billableMinutes(usage) {
                metered(used)
            } else {
                BillingNote(text: BillingCopy.meterUnmetered)
            }
        }
    }

    /// ⚠️ THE MONTH LABEL IS SHOWN ONLY WHEN THERE WERE MINUTES TO LABEL. A billing month
    /// printed under "nothing recorded yet" reads as a period that was measured and came
    /// back empty, which is the claim this card exists to avoid making.
    @ViewBuilder
    private func metered(_ used: Double) -> some View {
        Text(usedText(used))
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let included {
            bar(BillingFormat.meterFraction(used: used, included: included))
        }
        if let month = usage?.month, !month.trimmingCharacters(in: .whitespaces).isEmpty {
            BillingNote(text: BillingCopy.meterMonth(month))
        }
    }

    private func usedText(_ used: Double) -> String {
        let amount = AnalyticsFormat.amount(used)
        guard let included else { return BillingCopy.meterUsed(amount) }
        return BillingCopy.meterUsedOf(amount, included: included)
    }

    /// ⚠️ A `GeometryReader` INSIDE A FIXED-HEIGHT FRAME, which is the one shape that
    /// makes a proportional width safe in a `VStack`, and the same one
    /// ``AnalyticsHistoryCard`` uses. A bare `GeometryReader` takes all the vertical space
    /// offered and would push everything after it off screen.
    private func bar(_ fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: DistrictRadius.badge)
                    .fill(colors.muted)
                RoundedRectangle(cornerRadius: DistrictRadius.badge)
                    .fill(colors.district)
                    .frame(width: proxy.size.width * CGFloat(fraction))
            }
        }
        .frame(height: 10)
        // ⚠️ THE BAR IS DECORATION AND THE LABEL ABOVE IT IS THE FACT. A clamped width
        // read aloud as a percentage would understate an overage the label states
        // correctly, so it is hidden from VoiceOver rather than described.
        .accessibilityHidden(true)
    }
}
