import Foundation

/// Every sentence the billing screen says.
///
/// ⚠️ ITS OWN FILE RATHER THAN AN EXTENSION AT THE BOTTOM OF A SCREEN, the same call
/// ``DialerCopy`` and ``WorkflowsCopy`` make: `swiftlint --strict` promotes the
/// `file_length` WARNING at 500 lines to an error, and the copy for a screen with six
/// cards and four degraded states is most of a file on its own.
///
/// ⛔ THERE IS NO "UPGRADE", NO "MANAGE BILLING" AND NO "OPEN INVOICE" STRING IN HERE,
/// AND THE ABSENCE IS THE POINT. App Store Review Guideline 3.1.3(b) keeps subscription
/// purchase and management out of the app entirely, so this screen states what is being
/// billed and states the limitation. ⛔ IT NAMES NO DESTINATION EITHER:
/// 3.1.1 anti-steering makes "on the web dashboard at distronode.com" the rejection just
/// as surely as a button would be, so every sentence here says what cannot be done in
/// this app and stops. `StoreCopyTests` fails the build if one names a place.
/// Android's screen hands a Stripe hosted invoice URL out to be opened
/// (`onOpenInvoice`, `billing_invoice_open`); that is the one place where matching
/// Android would fail review, so it is deliberately not ported. A string added here that
/// reads as a control is the rejection.
///
/// ⛔ THE COPY IS THE ANDROID CLIENT'S WHERE ANDROID HAS A STRING, so the two apps say
/// the same thing about the same bill. Three are load bearing:
/// "No plan on this workspace" rather than "Free", "Calls are being declined" rather than
/// a generic over-limit note, and the unavailable body rather than an empty invoice list.
///
/// ⚠️ ANDROID'S EM DASHES ARE COMMAS HERE. The repo's house style avoids em dashes, and
/// VoiceOver reads one as nothing at all, so a sentence hinging on one loses its hinge.
enum BillingCopy {
    static let title = "Billing"

    static let loading = "Loading billing…"

    static let retry = "Try again"

    // MARK: - The plan card

    static let planTitle = "Plan"

    /// ⛔ NOT "Free". ``WorkspaceBilling/subscriptionTier`` is nullable and this route
    /// passes null through untouched; `GET /api/settings` substitutes a capitalised
    /// "Free" and this one deliberately does not. Inventing the word here would put a
    /// plan name on screen that no database row contains.
    static let planNone = "No plan on this workspace"

    static let statusActive = "Active"

    static let statusPastDue = "Past due"

    static let statusCanceled = "Cancelled"

    /// ⚠️ THE FALLBACK FOR EVERY UNRECOGNISED WORD TOO, not only for the literal
    /// `none`. The column is free text with no enum behind it, so a fifth value is a
    /// schema-level possibility, and "No subscription" makes no claim this client
    /// cannot support.
    static let statusNone = "No subscription"

    /// ⚠️ EXPLAINS THE BADGE RATHER THAN REPEATING IT. "Past due" is a Stripe word; what
    /// a customer needs to know is whether their service is still running.
    static let statusPastDueCaption = "A payment did not go through. Service continues while it is retried."

    static let statusCanceledCaption = "This plan will not renew."

    // MARK: - The overage card

    static let overageTitle = "Going over your minutes"

    static let overageAutoBill = "Extra minutes beyond your plan are billed automatically."

    static let overageHardCap = "Calls stop once your included minutes run out."

    /// ⛔ TWO SENTENCES FOR ONE FLAG, AND THE DIFFERENCE IS AN OUTAGE. Under a hard cap
    /// an exceeded allowance means calls are being REFUSED right now, which the operator
    /// has no other way to learn from this app; under auto-bill it is a charge. See
    /// ``WorkspaceBilling/callsAreBeingRefused``.
    static let overageBlocked = "Calls are being declined, your included minutes are used up"

    static let overageExceeded = "Over your included minutes, the extra is being billed"

    // MARK: - The usage meter

    static let meterTitle = "Call minutes this month"

    /// ⛔ NOT "0 minutes". ``WorkspaceBilling/usage`` is null when the month has no
    /// metering rows at all, and a zero beside an allowance asserts, with the authority
    /// of a bill, that no calls were made.
    static let meterUnmetered = "No call minutes have been recorded this month yet."

    static func meterUsed(_ amount: String) -> String {
        "\(amount) minutes used"
    }

    /// ⚠️ THE REAL NUMBERS, EVEN PAST THE ALLOWANCE. The BAR clamps; this label must not.
    /// See ``BillingFormat/meterFraction(used:included:)``.
    static func meterUsedOf(_ amount: String, included: Int) -> String {
        "\(amount) of \(included) included minutes used"
    }

    static func meterMonth(_ month: String) -> String {
        "Billing month \(month)"
    }

    // MARK: - The spending cap

    static let spendCapTitle = "Overage spending cap"

    /// ⛔ THE SECOND WAY A WORKSPACE LOSES ITS PHONE LINE, and its remedy is not the
    /// overage card's. That one bites under `hard_cap` and is fixed by switching policy
    /// or upgrading; this one bites under `auto_bill` and is fixed by RAISING OR REMOVING
    /// THE CAP. Offering the wrong remedy sends the customer to a control that cannot
    /// unblock them. See ``StripeBilling/overageSpendCapExceeded``.
    static let spendCapBlocked = "Calls are being declined, this month's overage spending cap has been reached"

    static func spendCapSet(_ amount: String) -> String {
        "Overage beyond your plan is capped at $\(amount) a month."
    }

    /// ⛔ ONLY EVER SHOWN BESIDE A STRIPE ANSWER THAT ARRIVED. The key is absent on both
    /// degraded bodies, so saying this while Stripe was unreachable would state a fact
    /// about the customer's configuration that was never read.
    static let spendCapNone = "No monthly cap is set on overage spending."

    static let spendCapRemedy = "The cap cannot be raised or removed in this app."

    // MARK: - The Stripe half

    static let subscriptionsTitle = "Subscription"

    static let subscriptionsEmpty = "No subscription is attached to this account."

    /// ⚠️ THE "$" IS THIS CLIENT MIRRORING THE WEB CONSOLE. Nothing on `/api/billing`
    /// carries a currency, so the assumption lives here, in one place, rather than being
    /// concatenated beside every amount.
    static func money(_ amount: String) -> String {
        "$\(amount)"
    }

    static func moneyMonthly(_ amount: String) -> String {
        "$\(amount) / month"
    }

    /// ⛔ SAME DATE, OPPOSITE MEANING, chosen by `cancel_at_period_end`. Telling someone
    /// who has cancelled that their plan "renews" says they are about to be billed again.
    static func renewsOn(_ date: String) -> String {
        "Renews \(date)"
    }

    static func endsOn(_ date: String) -> String {
        "Ends \(date)"
    }

    static func discountPercent(_ coupon: String, percent: String) -> String {
        "\(coupon), \(percent)% off"
    }

    static func discountAmount(_ coupon: String, amount: String) -> String {
        "\(coupon), $\(amount) off"
    }

    static let invoicesTitle = "Invoices"

    static let invoicesEmpty = "No invoices yet."

    /// ⚠️ THE SERVER CAPS THE LIST AT 10. Staying silent would present a truncated
    /// history as a complete one.
    static let invoicesTruncated = "Showing your most recent invoices. Older invoices are not available in this app."

    static func invoiceTax(_ amount: String) -> String {
        "incl. $\(amount) tax"
    }

    /// ⚠️ THE STRIPE HALF CAN BE ABOUT A DIFFERENT TENANT. When the active workspace
    /// carries no Stripe linkage the route falls through to another workspace of the same
    /// user and says so in ``StripeBilling/usageWorkspaceId``. Drawing those rows under
    /// this workspace's heading without a word would attribute a stranger's invoices to
    /// the tenant on screen.
    static let otherWorkspace = "These subscription and invoice details belong to another workspace on this account."

    // MARK: - The three answers that are not failures

    /// ⛔ THE COPY THAT MUST NEVER BE AN EMPTY INVOICE LIST. `billingUnavailable` means we
    /// could not reach Stripe; the subscription and the invoices still exist. Rendering
    /// this as "no plan" tells a paying customer they have none.
    static let unavailableTitle = "Billing details unavailable"

    static let unavailableBody = "We could not reach our payment provider just now, so your subscription and "
        + "invoices are not shown. Your plan and your usage above are current, and nothing about your account "
        + "has changed."

    /// ⛔ A DIFFERENT ANSWER FROM THE ONE ABOVE, AND THE TWO BODIES DIFFER ON THE WIRE BY
    /// ONE ABSENT KEY. This account has never had a Stripe customer, so nothing failed and
    /// no vendor was called. Wording it as an outage would invent a fault; wording the
    /// outage as this would tell a paying customer their billing was never set up.
    static let noCustomerTitle = "No billing set up"

    static let noCustomerBody = "This account has no billing customer yet, so there is no subscription or "
        + "invoice history to show. Nothing has gone wrong."

    static let stripeFailed = "Could not load your subscription and invoices."

    // MARK: - The read-only caption

    /// ⛔ THE CAPTION THAT MAKES THE ABSENCE OF CONTROLS DELIBERATE, and it is a store
    /// requirement rather than a courtesy: a plan card with no upgrade button reads as a
    /// half-built screen unless it says the change cannot be made here.
    ///
    /// ⛔ IT NAMES NOWHERE, NOT EVEN distronode.com. A tappable route
    /// to a purchase flow is what Guideline 3.1.3(b) prohibits; naming the destination in
    /// prose is what 3.1.1 prohibits. Stating the limitation breaks neither.
    static let readOnly = "Plan changes, payment methods and cancellations are not available in this app. "
        + "This screen is read-only."

    /// ⚠️ A VIEWER CANNOT MAKE THE CHANGE ANYWHERE, so the sentence names who can rather
    /// than what to do. The same call the marketplace makes.
    static let readOnlyViewer = "This screen is read-only. Ask an agency or client member of this workspace "
        + "to change the plan."
}
