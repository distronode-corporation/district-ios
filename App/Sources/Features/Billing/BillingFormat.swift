import DistrictModel
import Foundation

/// The billing screen's arithmetic, ported from Android's `BillingFormat.kt` and kept
/// out of the views so the interesting inputs stay readable on a tier with no tests.
///
/// ⛔ EVERY MONEY VALUE ON `/api/billing` IS IN **CENTS**, AND THAT IS THE FACT THIS
/// TYPE EXISTS TO CONTAIN. ``BillingSubscription/amount``, ``BillingInvoice/amountPaid``,
/// ``BillingInvoice/total``, ``BillingInvoice/tax`` and ``BillingDiscount/amountOff`` are
/// all Stripe minor units: 24900 is $249.00. There is exactly one conversion, here, so a
/// screen cannot render a raw integer and overstate a bill by a factor of a hundred.
///
/// ⛔ AND EVERY TIMESTAMP IS UNIX **SECONDS**, not milliseconds.
/// ``BillingSubscription/currentPeriodEnd`` and ``BillingInvoice/created`` both are.
/// Treating either as milliseconds dates the whole billing history to January 1970,
/// which reads as a rendering bug rather than as a unit mistake.
///
/// ⚠️ MINUTES ARE NOT FORMATTED HERE. They go through
/// ``AnalyticsFormat/amount(_:)``, which is the same helper the usage cards on the
/// Analytics screen use and the same one Android reaches for (`formatUsageAmount`). A
/// second quantity formatter is how two screens start quoting different figures for one
/// metered number.
enum BillingFormat {
    /// Cents as a plain decimal amount: 24900 becomes "249.00".
    ///
    /// ⛔ NO CURRENCY SYMBOL AND NO CURRENCY CODE, BECAUSE THE ROUTE PUBLISHES NEITHER.
    /// Nothing on `/api/billing` carries a currency, so the "$" is added by
    /// ``BillingCopy/money(_:)`` in one place rather than being baked in here.
    ///
    /// ⚠️ ALWAYS TWO DECIMALS, unlike ``AnalyticsFormat/amount(_:)``, which drops a
    /// trailing zero. A price of "249" beside a price of "249.99" reads as a different
    /// KIND of number: money is padded and quantities are not.
    ///
    /// ⚠️ BUILT BY INTERPOLATION RATHER THAN `String(format:)`, deliberately. Swift's
    /// interpolation of an `Int` is not localised, so the separator is always a "." —
    /// which is what the web console shows, and what a decimal comma beside an
    /// unlocalised "$" would quietly disagree with.
    ///
    /// ⛔ A NEGATIVE KEEPS ITS SIGN. Android drops it (it takes the absolute value of the
    /// remainder only), so a credited invoice renders there as a charge. A credit note
    /// is rare and the wrong direction is the expensive one.
    static func money(cents: Int) -> String {
        // ⚠️ DIVIDED AND REMAINDERED BEFORE `abs`, so `Int.min` cannot trap: `Int.min /
        // 100` is representable while `abs(Int.min)` is not.
        let units = abs(cents / 100)
        let fraction = abs(cents % 100)
        let padded = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        let text = "\(units).\(padded)"
        return cents < 0 ? "-\(text)" : text
    }

    /// A unix-SECONDS timestamp as a short local date.
    ///
    /// ⚠️ THE MULTIPLICATION LIVES HERE AND NOWHERE ELSE. See the ⛔ on the type.
    ///
    /// ⚠️ `formatted(date:time:)` RATHER THAN A `DateFormatter`, the same style
    /// ``WireDate`` uses: a `DateFormatter` is a non-`Sendable` class, so a stored
    /// static of one is a concurrency error under Swift 6 rather than a saving.
    static func date(unixSeconds: Int) -> String {
        let moment = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        return moment.formatted(date: .abbreviated, time: .omitted)
    }

    /// What an invoice row should show as its amount, in cents.
    ///
    /// ⛔ AN UNPAID INVOICE HAS `amount_paid: 0`, AND SHOWING THAT ZERO WOULD BE THE
    /// WRONG ANSWER TO THE QUESTION THE ROW IS ASKING. An open invoice is money OWED, so
    /// its total is the figure that matters; a paid one shows what was actually taken,
    /// which can differ from the total when a credit or a proration applied. Mirrors the
    /// web console and Android's `invoiceAmountCents`, so the three surfaces cannot quote
    /// different numbers for one invoice.
    static func invoiceAmountCents(_ invoice: BillingInvoice) -> Int {
        normalisedStatus(invoice.status) == invoiceStatusPaid ? invoice.amountPaid : invoice.total
    }

    /// The billable call minutes this month, or nil when the month has none.
    ///
    /// ⛔ NIL IS NOT ZERO, AND THE DISTINCTION IS THE WHOLE REASON THIS IS OPTIONAL. An
    /// absent metric has NO KEY in the usage object, so "we have not metered inbound
    /// minutes for this workspace" and "inbound minutes were measured at zero" are
    /// different facts. Summing absent-as-zero would draw a meter at 0% beside an
    /// allowance, which reads as "you have used none of your plan".
    ///
    /// ⚠️ ONE PRESENT AND ONE ABSENT SUMS THE PRESENT ONE, which is not the same
    /// compromise: absent genuinely contributed nothing to the meter, and refusing to
    /// draw it because one direction was never metered would discard a real number.
    ///
    /// ⛔ OUTBOUND **PLUS** INBOUND. The overage cron meters both against the plan's
    /// included minutes, so one direction alone would understate consumption against the
    /// exact allowance the customer is billed on.
    static func billableMinutes(_ usage: UsageMonth?) -> Double? {
        guard let usage else { return nil }
        return AnalyticsFormat.sumMetered(usage.callMinutesOutbound, usage.callMinutesInbound)
    }

    /// The plan's included call minutes, if any subscription publishes one.
    ///
    /// ⛔ THE ALLOWANCE LIVES ON THE **STRIPE** HALF AND THE USAGE ON THE **WORKSPACE**
    /// HALF, so a meter can only be drawn when both reads landed. That is why this takes
    /// the whole optional answer and returns nil rather than a zero: during a Stripe
    /// outage there is no allowance to measure against, and a meter drawn against zero
    /// would show every workspace at 100%.
    ///
    /// ⚠️ THE **LARGEST** ACROSS SUBSCRIPTIONS, not the sum and not the first.
    /// ``BillingSubscription/includedMinutes`` is derived per price from the tier
    /// catalogue, and a customer holding a plan plus a metered add-on has one real voice
    /// allowance; summing would inflate it and taking the first would depend on Stripe's
    /// list order. Absent on every row (a legacy or custom price) means no allowance is
    /// KNOWN, which is not the same as none existing, so the meter is simply not drawn.
    static func includedMinutes(_ stripe: StripeBilling?) -> Int? {
        stripe?.subscriptions.compactMap(\.includedMinutes).max()
    }

    /// How full the meter bar is drawn, in 0 ... 1.
    ///
    /// ⛔ CLAMPED FOR THE **BAR ONLY**, NEVER FOR THE LABEL. A workspace over its
    /// allowance is the case this screen matters most for, and a bar cannot draw past its
    /// own width, but the label beside it must state the real numbers because clamping
    /// the text would hide the overage that is about to be billed or is already blocking
    /// calls. See ``BillingCopy/meterUsedOf(_:included:)``.
    ///
    /// ⚠️ A ZERO OR NEGATIVE ALLOWANCE YIELDS 0 RATHER THAN DIVIDING, and a non-finite
    /// usage does too. Neither can arrive through ``includedMinutes(_:)``, and a division
    /// here would be an infinity that becomes a NaN width and draws as a rendering bug.
    static func meterFraction(used: Double, included: Int) -> Double {
        guard included > 0, used.isFinite, used > 0 else { return 0 }
        return min(used / Double(included), 1)
    }

    // MARK: - The server's own vocabularies

    /// ⚠️ LOWERCASED AND TRIMMED BEFORE ANY COMPARISON. Nothing normalises these columns
    /// on write, and `subscriptionTier` in the same database is verified mixed-case
    /// (`VoicePro`), so assuming lowercase is exactly the bug that makes a comparison
    /// silently never match. The same call ``Tone/forCallStatus(_:)`` makes.
    static func normalisedStatus(_ status: String?) -> String {
        status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    /// ⚠️ THE ONE STATUS THAT MEANS "THIS MONEY HAS BEEN TAKEN". Everything else is owed
    /// or void.
    static let invoiceStatusPaid = "paid"

    /// ⚠️ Owed, and therefore worth a warning tone.
    static let invoiceStatusOpen = "open"

    static let invoiceStatusUncollectible = "uncollectible"

    static let subscriptionStatusActive = "active"

    static let subscriptionStatusPastDue = "past_due"

    /// ⚠️ STRIPE'S SPELLING, ONE `L`. The badge says "Cancelled"; the wire says this.
    static let subscriptionStatusCanceled = "canceled"
}
