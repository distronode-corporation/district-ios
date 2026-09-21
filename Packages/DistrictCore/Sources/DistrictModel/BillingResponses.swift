import Foundation

// ⛔ BILLING IS READ ONLY IN THIS CLIENT AND THAT IS NOT REVISITABLE — App Store
// Review Guideline 3.1.3(b). `POST /api/billing` exists and cancels
// subscriptions, changes plans, detaches cards and applies promo codes; none of
// it is modelled here, and no request DTO may appear in this file. ⛔ NOR MAY A
// URL FIELD BE SURFACED FOR A LATER SCREEN TO OPEN: a link-out to the Stripe
// portal is what turns a compliant status screen into a rejected one, so the
// hosted invoice links below are modelled ONLY because the strict gate compares
// key sets and an unmodelled key would fail it. If a request type ever lands
// here, that decision has been reversed and should have been discussed.
//
// ⛔ TWO ROUTES, TWO ENVELOPES, AND ONE OF THEM HAS NO `success` AT ALL. That is
// the single most important fact in this file. `GET
// /api/district/workspace/billing` answers the ordinary `{success, billing}`
// district envelope from OUR OWN columns and reaches no vendor;
// `GET /api/billing` answers a BARE OBJECT from Stripe. A repository that ran
// the second through ``ResponseEnvelope`` would reject every healthy response as
// contract drift, and one that skipped the check on the first would let a `{}`
// body decode into a confident empty plan.

/// `GET /api/district/workspace/billing?workspaceId=` — the plan, from our own
/// database.
///
/// ⚠️ ``billing`` IS OPTIONAL ONLY SO A MALFORMED `{}` BODY DOES NOT DECODE INTO
/// A CONFIDENT EMPTY PLAN. The server always sends it on a 200, so nil is
/// contract drift rather than "no plan": absence of a plan is representable on
/// the wire (`subscriptionStatus: "none"` beside a null tier), which is what
/// makes a missing object mean something else. ``BillingRepository`` turns nil
/// into a decode failure for exactly that reason — the same call
/// ``CallsRepository`` makes about a 2xx with no `call`, and the opposite one
/// ``UsageResponse`` makes, where the null genuinely IS the payload.
public struct WorkspaceBillingResponse: Codable, Sendable {
    public let success: Bool
    /// ⛔ nil is MALFORMED, never an empty plan. See the type doc.
    public let billing: WorkspaceBilling?
}

/// One workspace's plan state, from columns the Stripe webhooks wrote.
///
/// ⛔ ``overagePolicy`` AND ``overageCapExceeded`` MUST BE READ TOGETHER, AND THE
/// COMBINATION CHANGES WHAT IS TRUE OF THE PRODUCT. Under
/// ``overagePolicyAutoBill`` an exceeded cap is a billing note: calls continue
/// and the overage is charged. Under ``overagePolicyHardCap`` an exceeded cap
/// means **calls are being refused right now**, which is an outage the operator
/// is living through and has no other way to learn about from this app. Drawing
/// the flag without the policy states neither, which is why
/// ``callsAreBeingRefused`` exists and why a screen should branch on it rather
/// than on either field alone.
///
/// ⛔ ``subscriptionTier`` IS NULLABLE AND NULL IS NOT "Free". The column is
/// nullable and this route passes it through untouched — `GET /api/settings`
/// substitutes a capitalised "Free" and this one deliberately does not.
/// Inventing the word here would put a plan name on screen that no row contains.
///
/// ⚠️ ``subscriptionTier`` AND ``plan`` ARE THE SAME FACT IN TWO CASINGS, not two
/// facts. They are written together and the tier keeps the catalogue's mixed case
/// ("VoicePro", not "voicepro"), so a case-insensitive comparison is the only
/// safe one.
///
/// ⚠️ EXACTLY SIX KEYS. The route is a hand-written projection of a `select`, so
/// a column added to that select widens the response; the strict gate is what
/// turns that into a readable failure rather than a silently ignored key.
public struct WorkspaceBilling: Codable, Sendable {
    /// ⛔ Null means "no plan recorded", NOT "Free". See the type doc.
    public let subscriptionTier: String?
    /// Stripe's own status word, stored on our row: `active`, `past_due`,
    /// `canceled`, `none`. ⚠️ A PLAIN `String` rather than an enum, for the reason
    /// ``WorkspaceRole`` documents: the column is free text with no Prisma enum
    /// behind it, so a fifth value is a schema-level possibility and a throwing
    /// enum would take the whole response with it. The opposite call from
    /// ``SchedulingTenantStatus``, whose vocabulary is CHECK-constrained in SQL.
    public let subscriptionStatus: String
    /// ``subscriptionTier`` lowercased, written by the same code path.
    public let plan: String
    /// ⛔ Read WITH ``overageCapExceeded``. See the type doc.
    public let overagePolicy: String
    public let overageCapExceeded: Bool
    /// ⛔ nil MEANS "NOTHING METERED THIS MONTH YET" AND IT IS NOT ZERO. A screen
    /// that rendered it as a column of zeros would state, in the register of a
    /// bill, that a workspace sent nothing and called nobody — beside a cap that
    /// may be saying calls are being refused. The two statements contradict each
    /// other and only one of them was measured.
    ///
    /// ⚠️ ``UsageMonth`` REUSED RATHER THAN REDECLARED, and that is an assertion
    /// rather than a convenience: this route and `workspace/usage` both call
    /// `getUsage`, and the server's contract test asserts the two payloads are
    /// byte-identical. One DTO decoding both surfaces is what keeps that true.
    public let usage: UsageMonth?

    /// True when this workspace's calls are being REFUSED for overage right now.
    ///
    /// ⛔ THE ONE QUESTION THE TWO OVERAGE FIELDS EXIST TO ANSWER, expressed once
    /// so a screen cannot ask half of it. ⚠️ COMPUTED, so it is not encoded:
    /// synthesised `Codable` covers stored properties only, which is what keeps
    /// this from adding a key the server never sent and failing the strict gate.
    public var callsAreBeingRefused: Bool {
        overageCapExceeded && overagePolicy == Self.overagePolicyHardCap
    }

    /// ⛔ With an exceeded cap, this policy BLOCKS CALLS.
    public static let overagePolicyHardCap = "hard_cap"
    /// ⛔ With an exceeded cap, this policy BILLS the overage and calls continue.
    public static let overagePolicyAutoBill = "auto_bill"
}

/// Which of the three shapes `GET /api/billing` answered with.
///
/// ⛔ THREE STATES, NEVER AN ERROR, AND TWO OF THEM ARE ONE ABSENT KEY APART.
/// This exists because the difference is otherwise invisible: `unavailable` and
/// `noCustomer` carry the SAME six keys with the same empty arrays and the same
/// nulls, and they mean opposite things. "We could not ask Stripe" must never
/// render as a free or unstarted account, and "this account has no Stripe
/// customer" must never render as a fault. A client that branched on "are the
/// arrays empty" would call a Stripe outage a free account — the same "we could
/// not look" / "there is nothing" conflation that routes a paying customer to a
/// checkout page, except about their PLAN.
public enum BillingAvailability: Sendable, Equatable {
    /// Stripe answered and the account has a customer. The populated shape.
    case available
    /// The account has no Stripe linkage at all. ⛔ A LEGITIMATE STATE a screen
    /// may render as "no billing set up"; no Stripe call was made.
    case noCustomer
    /// Stripe could not be reached. ⛔ The screen must SAY SO and must not
    /// describe the account, because nothing about it was read.
    case unavailable
}

/// `GET /api/billing` — subscriptions and invoices, from Stripe.
///
/// ⛔ NO `success` KEY, ABSENT RATHER THAN FALSE, AND ``BillingRepository`` MUST
/// NOT RUN THIS THROUGH ``ResponseEnvelope``. Every other district route answers
/// `{success, …}`; this one answers the object bare, so the envelope guard would
/// reject every healthy response as contract drift and show every subscribed
/// customer copy about an app that does not understand the server. The
/// strictness that guard provides elsewhere is supplied here by three committed
/// fixtures instead.
///
/// ⛔ EVERY FIELD BUT THE TWO ARRAYS IS OPTIONAL, AND THE DEGRADED SHAPES ARE
/// WHY. Nine of the fourteen healthy keys are ABSENT — not null, absent — from
/// the two six-key bodies, so a required field on any of them would fail to
/// decode precisely when billing was already broken, turning a legible
/// "temporarily unavailable" into an illegible "the app does not understand this
/// response".
///
/// ⚠️ FIVE SUB-OBJECTS ARE OPAQUE ``WireJSON`` ON PURPOSE, WHICH IS A DELIBERATE
/// NARROWING RATHER THAN LAZINESS. ``paymentMethod``, ``paymentMethods``,
/// ``businessProfile``, ``taxIds`` and ``billingAddress`` are card details, a
/// legal business name, tax registration numbers and a postal address, and this
/// client renders NONE of them, because it offers no way to change any of them
/// (see the ⛔ at the top of this file). They are modelled only because the
/// strict gate would fail on an unmodelled key. Typing them out would invite a
/// screen to display them and would make a Stripe-side change to a card object
/// break a screen that never showed one. If one is ever needed, model THAT one.
public struct StripeBilling: Codable, Sendable {
    /// ⛔ `true` MEANS "WE COULD NOT ASK STRIPE", NEVER "THERE IS NO PLAN", and
    /// the key is ABSENT on both healthy and no-customer bodies rather than
    /// false. Branch on ``availability`` instead of reading this directly.
    public let billingUnavailable: Bool?
    /// ⚠️ EMPTY ON BOTH DEGRADED SHAPES, which is why an empty array is not
    /// evidence of anything on its own.
    public let subscriptions: [BillingSubscription]
    public let invoices: [BillingInvoice]
    /// The server caps the history at 10. ⚠️ `true` means what is shown is not
    /// all of it; nil means the question was not answered.
    public let invoicesHasMore: Bool?
    /// ⚠️ Opaque and never rendered. See the type doc.
    public let paymentMethod: WireJSON?
    /// ⚠️ Opaque and never rendered. See the type doc.
    public let paymentMethods: WireJSON?
    /// ⚠️ Opaque and never rendered. See the type doc.
    public let businessProfile: WireJSON?
    /// ⚠️ Opaque and never rendered. See the type doc.
    public let taxIds: WireJSON?
    /// ⚠️ Opaque and never rendered. See the type doc.
    public let billingAddress: WireJSON?
    /// ⛔ THE DISCRIMINATOR FOR ``BillingAvailability/noCustomer``: null with no
    /// `billingUnavailable` beside it is an account that has never had a Stripe
    /// customer, and no Stripe call was made to find that out.
    public let customerId: String?
    /// The workspace whose subscription this is — the server's ACTIVE workspace,
    /// index 0 of its own listing.
    ///
    /// ⚠️ IT CAN DISAGREE WITH THE WORKSPACE A SCREEN NAMES, and the server logs
    /// a warning when it does: if the active workspace carries no Stripe
    /// linkage, the route falls through to another workspace of the same user.
    /// ``WorkspaceBillingResponse`` is always about the workspace that was asked
    /// for, so a screen reading both can detect the mismatch.
    public let usageWorkspaceId: String?
    /// ⚠️ ALSO ON `workspace/billing`, AND THAT COPY IS THE ONE TO TRUST. Here it
    /// is best-effort (the route swallows a failed read into null) and absent
    /// entirely from the degraded shapes.
    public let overagePolicy: String?
    /// ⚠️ See ``overagePolicy``. Absent on the degraded shapes, so nil is
    /// "unknown" rather than "within plan".
    public let overageCapExceeded: Bool?
    /// The workspace's monthly overage SPENDING cap, in **CENTS**.
    ///
    /// ⛔ NULL AND 0 ARE DIFFERENT STATES. Null is "no ceiling set"; 0 would be a
    /// $0.00 ceiling, i.e. block everything. Defaulting a missing value to 0
    /// would tell a customer with no cap that they are capped at nothing.
    ///
    /// ⛔ AND ON A DEGRADED BODY THE DEFAULT MUST READ AS "UNKNOWN", NOT AS "NO
    /// CAP". The key is absent there, so rendering nil as "no spending cap set"
    /// while ``availability`` is ``BillingAvailability/unavailable`` states a
    /// fact about the customer's configuration that was never read.
    ///
    /// ⚠️ ON **THIS ROUTE ONLY**. Unlike the overage pair above there is no
    /// Stripe-independent copy to fall back on during a Stripe outage.
    public let overageSpendCapCents: Int?
    /// True when this month's overage spend has REACHED
    /// ``overageSpendCapCents`` and calls are being refused for that reason.
    ///
    /// ⛔ THE SECOND WAY A WORKSPACE LOSES ITS PHONE LINE, and it is not
    /// ``WorkspaceBilling/overageCapExceeded``. That one bites under `hard_cap`
    /// and is fixed by switching policy or upgrading; this one bites under
    /// `auto_bill` and is fixed by RAISING OR REMOVING THE CAP. Offering the
    /// wrong remedy sends the customer to a control that cannot unblock them.
    public let overageSpendCapExceeded: Bool?

    /// Which of the three shapes this is.
    ///
    /// ⛔ THE ONLY SANCTIONED WAY TO BRANCH, and the order matters: an
    /// unavailable body ALSO carries `customerId: null`, so reading the flag
    /// first is what keeps a Stripe outage from being reported as an account
    /// with no billing. ⚠️ Computed, so it adds no key on re-encode.
    public var availability: BillingAvailability {
        if billingUnavailable == true {
            return .unavailable
        }
        if customerId == nil {
            return .noCustomer
        }
        return .available
    }
}

/// One active subscription.
///
/// ⛔ ``amount`` IS IN **CENTS**, like every money field on this route. 24900 is
/// $249.00. Rendering the integer verbatim overstates a price by a factor of a
/// hundred, on the one screen where a wrong number becomes a support ticket.
///
/// ⛔ ``cancelAtPeriodEnd`` CHANGES WHAT ``currentPeriodEnd`` MEANS. False: the
/// plan RENEWS on that date. True: it ENDS on it. Drawing the same date under a
/// "renews" heading tells a customer who has already cancelled that they are
/// about to be billed again.
///
/// ⛔ ``includedMinutes``, ``overageRate`` AND ``discount`` ARE ABSENT KEYS, NOT
/// NULLS, when they do not apply — `JSON.stringify` drops an undefined value.
/// The server derives the first two by matching the price against its tier
/// catalogue, so a legacy or custom price yields neither and a usage meter has
/// nothing to measure against. Render the meter only when the allowance is
/// known.
///
/// ⚠️ ``currentPeriodEnd`` IS UNIX **SECONDS**, not milliseconds — multiply by
/// 1000 before it is a date. Treating it as millis dates every renewal to 1970.
public struct BillingSubscription: Codable, Sendable {
    /// Stripe's `sub_…`. The row's identity, so it is required rather than
    /// tolerated — a subscription with nothing to name it cannot be acted on.
    public let id: String
    /// Stripe's own status word. The plan status a screen headlines is
    /// ``WorkspaceBilling/subscriptionStatus``.
    public let status: String
    /// ⚠️ Optional because the route forwards Stripe's field through a cast
    /// rather than a guarantee. See the type doc for the units.
    public let currentPeriodEnd: Int?
    public let cancelAtPeriodEnd: Bool
    /// The catalogue name, or the literal "Subscription" when nothing matched.
    public let tierName: String
    /// ⛔ CENTS. ⚠️ Optional because the route writes `price?.unit_amount`, and
    /// both halves of that can be absent — an expanded price that did not
    /// resolve, and a Stripe price with no `unit_amount` (tiered or metered).
    public let amount: Int?
    /// ⛔ Absent, not null, when the price matched no tier. See the type doc.
    public let includedMinutes: Int?
    /// ⛔ Absent, not null, when the price matched no tier. See the type doc.
    public let overageRate: Double?
    /// ⛔ Absent, not null, when no coupon applies. See the type doc.
    public let discount: BillingDiscount?

    /// ⚠️ TWO SNAKE_CASE KEYS FROM STRIPE'S OWN VOCABULARY, PASSED THROUGH
    /// UNTOUCHED BY THE ROUTE. They are spelled out here rather than handled with
    /// a decoder key strategy, because a strategy would also rewrite `tierName`
    /// and `includedMinutes`, which the route names itself.
    enum CodingKeys: String, CodingKey {
        case id
        case status
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case tierName
        case amount
        case includedMinutes
        case overageRate
        case discount
    }
}

/// A coupon applied to a subscription.
///
/// ⚠️ EXACTLY ONE OF ``percentOff`` AND ``amountOff`` IS PRESENT, and the server
/// sends neither key when the corresponding Stripe field is null. ``amountOff``
/// is in CENTS like every other money field here.
public struct BillingDiscount: Codable, Sendable {
    /// The coupon's name, or its id when it has no name.
    public let couponName: String
    public let percentOff: Double?
    /// ⛔ CENTS.
    public let amountOff: Int?
}

/// One invoice.
///
/// ⛔ ``amountPaid``, ``total`` AND ``tax`` ARE ALL IN **CENTS**. ``tax`` is
/// summed server-side out of Stripe's `total_taxes`, so a zero here is a
/// MEASURED zero rather than an absence — the key is always present, which is
/// exactly what makes it safe to show.
///
/// ⛔ ``hostedInvoiceUrl`` AND ``invoicePdf`` ARE NULL UNTIL AN INVOICE IS
/// FINALISED, which makes the most ordinary row there is — this month's, before
/// it is paid — the one that would throw on a client that typed them non-null. A
/// row with no URL must render without an open action rather than with a dead
/// one. ⛔ AND NEITHER MAY BE OPENED AS A PURCHASE PATH: see the ⛔ at the top of
/// this file; they are modelled to satisfy the gate, not to be surfaced.
///
/// ⚠️ ``created`` IS UNIX **SECONDS**. Treating it as milliseconds dates every
/// invoice to January 1970.
public struct BillingInvoice: Codable, Sendable {
    /// Stripe's `in_…`. Required for the reason ``BillingSubscription/id`` is.
    public let id: String
    /// ⛔ CENTS. Zero on an unpaid row beside a non-zero ``total``.
    public let amountPaid: Int
    /// ⛔ CENTS.
    public let total: Int
    /// ⛔ CENTS, and a SUMMED zero rather than an absent one.
    public let tax: Int
    /// Stripe's word: `paid`, `open`, `draft`, `void`, `uncollectible`. Shown
    /// verbatim. ⚠️ Optional because Stripe types it nullable.
    public let status: String?
    /// ⚠️ UNIX SECONDS. See the type doc.
    public let created: Int
    /// ⛔ Null until the invoice is finalised. See the type doc.
    public let hostedInvoiceUrl: String?
    /// ⛔ Null until the invoice is finalised. See the type doc.
    public let invoicePdf: String?

    /// ⚠️ FOUR SNAKE_CASE KEYS, STRIPE'S OWN, PASSED THROUGH BY THE ROUTE. See
    /// ``BillingSubscription/CodingKeys`` for why they are spelled out.
    enum CodingKeys: String, CodingKey {
        case id
        case amountPaid = "amount_paid"
        case total
        case tax
        case status
        case created
        case hostedInvoiceUrl = "hosted_invoice_url"
        case invoicePdf = "invoice_pdf"
    }
}
