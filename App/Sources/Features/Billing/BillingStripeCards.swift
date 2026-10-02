import DistrictModel
import SwiftUI

// The cards built from STRIPE's answer, plus the two answers that arrive on a 200 and
// are not failures.
//
// ⛔ EVERY MONEY VALUE THAT REACHES THIS FILE IS IN **CENTS** and goes through
// `BillingFormat.money(cents:)`. There is no other conversion anywhere in the screen;
// adding a second one is how two surfaces start quoting different numbers for one
// invoice.
//
// ⛔ AND NOTHING HERE IS TAPPABLE. Android's invoice row hands `hosted_invoice_url` to
// the system browser (`onOpenInvoice`) and draws an "Open" button beside it; THAT IS
// DELIBERATELY NOT PORTED. App Store Review Guideline 3.1.3(b) forbids an in-app route to
// a purchase or to subscription management, and a link out to a Stripe-hosted invoice or
// portal is exactly what turns a compliant status screen into a rejected one. The URLs
// are modelled in `BillingInvoice` only because the strict contract gate compares key
// sets and an unmodelled key would fail it, which that DTO states as well. A change that
// "restores parity" here reverses a store-compliance decision rather than fixing an
// omission.
//
// ⚠️ A REGULAR COMMENT RATHER THAN A DOC ONE: see the note at the top of
// `BillingPlanCards.swift`.

/// Every active subscription, its price, and the date it turns over.
///
/// ⛔ "renews" VERSUS "ends" IS DECIDED BY `cancel_at_period_end`, AND GETTING IT
/// BACKWARDS TELLS A CUSTOMER WHO HAS ALREADY CANCELLED THAT THEY ARE ABOUT TO BE BILLED
/// AGAIN. Same date, opposite meaning.
///
/// ⚠️ AN EMPTY LIST IS A LEGITIMATE ANSWER on a customer that exists, and it is NOT the
/// same as ``BillingUnavailableCard`` or ``BillingNoCustomerCard``, which are separate
/// states entirely. See ``BillingStripeState``.
struct BillingSubscriptionsCard: View {
    let detail: StripeBilling

    var body: some View {
        DistrictCard(eyebrow: BillingCopy.subscriptionsTitle) {
            if detail.subscriptions.isEmpty {
                BillingNote(text: BillingCopy.subscriptionsEmpty)
            } else {
                ForEach(detail.subscriptions, id: \.id) { subscription in
                    BillingSubscriptionRow(subscription: subscription)
                }
            }
        }
    }
}

/// One subscription.
struct BillingSubscriptionRow: View {
    let subscription: BillingSubscription

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            HStack(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight) {
                Text(subscription.tierName)
                    .font(DistrictType.titleSmall)
                    .foregroundStyle(colors.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // ⛔ CENTS, AND AN ABSENT AMOUNT RENDERS NOTHING rather than "0.00", which
                // would quote a free plan to someone who is paying. The route writes
                // `price?.unit_amount` and both halves of that can be absent.
                if let amount = subscription.amount {
                    Text(BillingCopy.moneyMonthly(BillingFormat.money(cents: amount)))
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.foreground)
                }
            }
            // ⛔ THE FLAG CHOOSES THE SENTENCE, NOT THE DATE. See the ⛔ on the card.
            if let end = subscription.currentPeriodEnd {
                BillingNote(text: renewalText(end))
            }
            // ⚠️ EXACTLY ONE OF percentOff / amountOff ARRIVES, and the server sends
            // neither key when Stripe's field was null, so a coupon with neither still
            // renders, by name.
            if let discount = subscription.discount {
                Text(Self.discountText(discount))
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.success)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, DistrictSpacing.hairline)
    }

    private func renewalText(_ end: Int) -> String {
        let date = BillingFormat.date(unixSeconds: end)
        return subscription.cancelAtPeriodEnd ? BillingCopy.endsOn(date) : BillingCopy.renewsOn(date)
    }

    private static func discountText(_ discount: BillingDiscount) -> String {
        if let percent = discount.percentOff {
            return BillingCopy.discountPercent(discount.couponName, percent: AnalyticsFormat.amount(percent))
        }
        if let amount = discount.amountOff {
            return BillingCopy.discountAmount(discount.couponName, amount: BillingFormat.money(cents: amount))
        }
        return discount.couponName
    }
}

/// The monthly ceiling on overage spending, and whether it has already stopped calls.
///
/// ⛔ THE SECOND WAY A WORKSPACE LOSES ITS PHONE LINE, AND IT IS NOT THE OVERAGE CARD'S.
/// That one bites under `hard_cap` and is fixed by switching policy or upgrading; this
/// one bites under `auto_bill` and is fixed by RAISING OR REMOVING THE CAP. Offering the
/// wrong remedy sends a customer to a control that cannot unblock them.
///
/// ⛔ DRAWN ONLY FROM A STRIPE ANSWER THAT ARRIVED, WHICH IS WHY IT LIVES IN THIS FILE.
/// Both keys are absent on the two degraded bodies, so nil there means "unknown" rather
/// than "no cap" — and rendering "no monthly cap is set" beside an outage would state a
/// fact about the customer's configuration that was never read. Unlike the overage pair,
/// there is no Stripe-independent copy of these to fall back on.
///
/// ⚠️ NOT ON ANDROID'S SCREEN, WHICH MODELS BOTH FIELDS AND RENDERS NEITHER. Added here
/// because the blocked case is an outage the operator has no other way to learn about
/// from this app, which is the same argument that justifies the overage card.
struct BillingSpendCapCard: View {
    let detail: StripeBilling

    var body: some View {
        DistrictCard(eyebrow: BillingCopy.spendCapTitle) {
            BillingNote(text: capText)
            if detail.overageSpendCapExceeded == true {
                DistrictBadge(text: BillingCopy.spendCapBlocked, tone: .danger)
                BillingNote(text: BillingCopy.spendCapRemedy)
            }
        }
    }

    /// ⛔ NULL AND 0 ARE DIFFERENT STATES. Null is "no ceiling set"; 0 would be a $0.00
    /// ceiling, i.e. block everything. Defaulting a missing value to zero would tell a
    /// customer with no cap that they are capped at nothing.
    private var capText: String {
        guard let cents = detail.overageSpendCapCents else { return BillingCopy.spendCapNone }
        return BillingCopy.spendCapSet(BillingFormat.money(cents: cents))
    }
}

/// The invoice history.
///
/// ⛔ A ROW HAS NO OPEN ACTION, ON PURPOSE. See the ⛔ at the top of this file: the hosted
/// invoice URL is modelled and never surfaced.
///
/// ⚠️ `invoicesHasMore` IS SURFACED. The server caps the list at 10, so a client that
/// stayed silent would present a truncated history as a complete one. nil means the
/// question was not answered, which is not the same as "that is all of them", so only an
/// explicit `true` draws the line.
struct BillingInvoicesCard: View {
    let detail: StripeBilling

    var body: some View {
        DistrictCard(eyebrow: BillingCopy.invoicesTitle) {
            if detail.invoices.isEmpty {
                BillingNote(text: BillingCopy.invoicesEmpty)
            } else {
                ForEach(detail.invoices, id: \.id) { invoice in
                    BillingInvoiceRow(invoice: invoice)
                    DistrictRowDivider()
                }
            }
            if detail.invoicesHasMore == true {
                BillingNote(text: BillingCopy.invoicesTruncated)
            }
        }
    }
}

/// One invoice: when, how much, and what Stripe calls its state.
struct BillingInvoiceRow: View {
    let invoice: BillingInvoice

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            HStack(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight) {
                // ⚠️ UNIX SECONDS. The multiplication lives in ``BillingFormat/date(unixSeconds:)``.
                Text(BillingFormat.date(unixSeconds: invoice.created))
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // ⛔ CENTS, and an OPEN invoice shows what is OWED rather than the zero it
                // has been paid. See ``BillingFormat/invoiceAmountCents(_:)``.
                Text(BillingCopy.money(BillingFormat.money(cents: BillingFormat.invoiceAmountCents(invoice))))
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
            }
            HStack(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight) {
                if let status = invoice.status, !status.isEmpty {
                    DistrictBadge(text: status, tone: Self.tone(status))
                }
                // ⚠️ TAX IS SUMMED SERVER-SIDE, so a zero here is measured rather than
                // absent. Shown only when non-zero: an "incl. $0.00 tax" line is noise on
                // every untaxed invoice.
                if invoice.tax > 0 {
                    Text(BillingCopy.invoiceTax(BillingFormat.money(cents: invoice.tax)))
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.mutedForeground)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, DistrictSpacing.tight)
        .accessibilityElement(children: .combine)
    }

    /// ⚠️ STRIPE'S OWN WORDS, SHOWN VERBATIM IN THE BADGE. Anything unrecognised stays
    /// neutral rather than being painted a colour that would assert a meaning this client
    /// does not have.
    private static func tone(_ status: String) -> Tone {
        switch BillingFormat.normalisedStatus(status) {
        case BillingFormat.invoiceStatusPaid: .success
        case BillingFormat.invoiceStatusOpen, BillingFormat.invoiceStatusUncollectible: .warning
        default: .neutral
        }
    }
}

/// ⛔ THE CARD THAT MUST NEVER BE AN EMPTY INVOICE LIST. `billingUnavailable: true` means
/// we could not reach Stripe: the subscription and the invoices still exist, we simply
/// could not read them. Drawing an empty list instead would tell a paying customer they
/// have no plan, the same "we could not look" against "there is nothing" conflation that
/// can send one to a checkout page.
///
/// ⚠️ NO RETRY BUTTON HERE SPECIFICALLY. The plan card above it is correct and current and
/// the screen-level pull to refresh is still available; a retry attached to a vendor
/// outage invites a customer to tap repeatedly at something they cannot fix.
struct BillingUnavailableCard: View {
    var body: some View {
        DistrictCard(eyebrow: BillingCopy.unavailableTitle) {
            BillingNote(text: BillingCopy.unavailableBody)
        }
    }
}

/// ⛔ THE OTHER 200 THAT IS NOT A FAULT, AND IT IS ONE ABSENT KEY FROM THE ONE ABOVE.
/// A null `customerId` with no `billingUnavailable` beside it is an account that has never
/// had a Stripe customer, and no vendor call was made to find that out. Wording it as an
/// outage would invent a fault; wording the outage as this would tell a paying customer
/// their billing was never set up. ``StripeBilling/availability`` reads the flag first for
/// exactly that reason.
struct BillingNoCustomerCard: View {
    var body: some View {
        DistrictCard(eyebrow: BillingCopy.noCustomerTitle) {
            BillingNote(text: BillingCopy.noCustomerBody)
        }
    }
}
