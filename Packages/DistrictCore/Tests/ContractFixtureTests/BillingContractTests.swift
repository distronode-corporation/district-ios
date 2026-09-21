import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the five billing bodies.
///
/// ⛔ THE STRICT GATE CANNOT TELL THE TWO DEGRADED BODIES APART, WHICH IS WHY
/// THIS FILE EXISTS. `district-billing-unavailable.json` and
/// `district-billing-no-customer.json` differ by ONE key, and `StrictDecodeVerifier`
/// compares shapes rather than values — so the fact that one means "Stripe is
/// down" and the other means "this account has no billing" is entirely
/// value-level, and only assertions like these hold it. Conflating them is how a
/// Stripe outage gets drawn as a free account.
final class BillingContractTests: XCTestCase {
    // MARK: - The workspace's own plan

    /// ⛔ SIX KEYS, NONE OF THEM FROM STRIPE. Every field is a column the Stripe
    /// webhooks wrote to our own database, which is what makes this screen render
    /// during a Stripe outage — the property the route's header forbids anyone
    /// removing, and the reason this fixture and `district-billing.json` are two
    /// fixtures rather than one.
    func testTheWorkspacePlanCarriesTheTierInBothCasingsAndAMeteredMonth() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-workspace-billing.json",
            as: WorkspaceBillingResponse.self
        )
        let billing = try XCTUnwrap(response.billing)

        XCTAssertTrue(response.success)
        // ⚠️ ONE FACT IN TWO CASINGS, not two facts. Only a case-insensitive
        // comparison is safe against either of them.
        XCTAssertEqual(billing.subscriptionTier, "VoicePro")
        XCTAssertEqual(billing.plan, "voicepro")
        XCTAssertEqual(billing.subscriptionStatus, "active")
        XCTAssertEqual(billing.overagePolicy, WorkspaceBilling.overagePolicyAutoBill)
        XCTAssertFalse(billing.overageCapExceeded)
        XCTAssertFalse(billing.callsAreBeingRefused, "within plan, and billing rather than blocking anyway")
        // ⛔ FRACTIONAL MINUTES REACH THE SCREEN THAT METERS THEM AGAINST AN
        // ALLOWANCE, so `Double` is not fussiness — an `Int` here fails to decode
        // outright, and rounding would round a bill.
        let usage = try XCTUnwrap(billing.usage)
        XCTAssertEqual(usage.callMinutesInbound, 1204.25)
        XCTAssertEqual(usage.month, "2026-08")
    }

    /// ⛔ THE BLOCKING COMBINATION, AND IT IS THE ONE FACT THE APP IS THE ONLY
    /// PLACE TO LEARN IT FROM. `hard_cap` with an exceeded cap means calls are
    /// being REFUSED right now; the same flag under `auto_bill` is a billing
    /// note. Reading either field alone states neither, which is what
    /// ``WorkspaceBilling/callsAreBeingRefused`` exists to stop.
    ///
    /// ⛔ AND `usage: null` IS NOT ZERO. A column of zeros here would assert, in
    /// the register of a bill, that nothing was used — beside a cap saying calls
    /// are refused. The two statements contradict each other and only one of them
    /// was measured. ⚠️ A null tier is not "Free" either: this route passes the
    /// column through untouched where `/api/settings` substitutes the word.
    func testACappedUnmeteredWorkspaceReportsRefusedCallsAndNullsRatherThanZeros() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-workspace-billing-null-usage.json",
            as: WorkspaceBillingResponse.self
        )
        let billing = try XCTUnwrap(response.billing)

        XCTAssertNil(billing.subscriptionTier, "⛔ null is not the word Free")
        XCTAssertEqual(billing.subscriptionStatus, "past_due")
        XCTAssertEqual(billing.overagePolicy, WorkspaceBilling.overagePolicyHardCap)
        XCTAssertTrue(billing.overageCapExceeded)
        XCTAssertTrue(billing.callsAreBeingRefused, "⛔ hard_cap plus an exceeded cap is an outage")
        XCTAssertNil(billing.usage, "⛔ nothing metered this month, which is not zero of everything")
    }

    /// ⚠️ THE FLAG AND THE POLICY ARE READ TOGETHER, AND THREE OF THE FOUR
    /// COMBINATIONS ARE NOT AN OUTAGE. Decoded from literal bytes because no
    /// fixture carries the `auto_bill` + exceeded pairing, which is the one a
    /// screen would most easily draw as a block.
    func testAnExceededCapUnderAutoBillIsABillingNoteRatherThanAnOutage() throws {
        let response = try decode(
            WorkspaceBillingResponse.self,
            from: #"""
            {"success":true,"billing":{"subscriptionTier":"VoicePro","subscriptionStatus":"active",
             "plan":"voicepro","overagePolicy":"auto_bill","overageCapExceeded":true,"usage":null}}
            """#
        )
        let billing = try XCTUnwrap(response.billing)

        XCTAssertTrue(billing.overageCapExceeded)
        XCTAssertFalse(billing.callsAreBeingRefused, "auto_bill bills the overage; the calls continue")
    }

    // MARK: - Stripe, and the two degraded bodies

    /// ⛔ NO `success` KEY, AND ITS ABSENCE IS THE ASSERTION. Every other district
    /// route affirms an envelope and this one answers the object bare, so a
    /// repository applying ``ResponseEnvelope`` here would reject every healthy
    /// response as contract drift. ⛔ AND NO `billingUnavailable` EITHER: its
    /// absence is what distinguishes this from the degraded shape, so a client
    /// must treat a missing key as false rather than requiring it.
    func testAHealthyStripeBodyIsAvailableAndCarriesNoEnvelopeAndNoFlag() throws {
        let billing = try StrictDecodeVerifier.verify(
            fixture: "district-billing.json",
            as: StripeBilling.self
        )

        XCTAssertEqual(billing.availability, .available)
        XCTAssertNil(billing.billingUnavailable, "absent, not false")
        XCTAssertEqual(billing.customerId, "cus_contract_1")
        XCTAssertEqual(billing.usageWorkspaceId, "ws-contract-test")
        XCTAssertEqual(billing.invoicesHasMore, true, "truncated history, and the client must say so")
        // ⛔ CENTS, AND NULL IS NOT 0. 5000 is $50.00; a 0 default would tell a
        // customer with no cap that they are capped at nothing.
        XCTAssertEqual(billing.overageSpendCapCents, 5000)
        XCTAssertEqual(billing.overageSpendCapExceeded, false)
    }

    /// ⛔ THE ROW WHERE FOUR OPTIONAL KEYS ARE ABSENT RATHER THAN NULL, and the
    /// row where the date means the opposite thing. `JSON.stringify` drops an
    /// undefined, so a legacy price that matched no tier sends no
    /// `includedMinutes`, no `overageRate` and no `discount` at all — and
    /// `cancel_at_period_end: true` makes `current_period_end` an END rather than
    /// a renewal, which under a "renews" heading tells a customer who cancelled
    /// that they are about to be billed again.
    func testTheLegacySubscriptionOmitsItsTierFieldsAndEndsRatherThanRenews() throws {
        let billing = try StrictDecodeVerifier.verify(
            fixture: "district-billing.json",
            as: StripeBilling.self
        )
        XCTAssertEqual(billing.subscriptions.count, 2)
        let pro = billing.subscriptions[0]
        let legacy = billing.subscriptions[1]

        // ⛔ CENTS. 24900 is $249.00, and the meter is drawn against the pair below.
        XCTAssertEqual(pro.amount, 24900)
        XCTAssertEqual(pro.includedMinutes, 1500)
        XCTAssertEqual(pro.overageRate, 0.16)
        XCTAssertEqual(pro.discount?.couponName, "Founding customer")
        XCTAssertEqual(pro.discount?.percentOff, 20)
        XCTAssertNil(pro.discount?.amountOff, "exactly one of the two is ever sent")
        XCTAssertFalse(pro.cancelAtPeriodEnd)

        XCTAssertNil(legacy.includedMinutes, "no tier matched, so there is no allowance to meter against")
        XCTAssertNil(legacy.overageRate)
        XCTAssertNil(legacy.discount)
        XCTAssertTrue(legacy.cancelAtPeriodEnd, "⛔ the date is an END, not a renewal")
        XCTAssertEqual(legacy.currentPeriodEnd, 1_757_514_600, "⚠️ UNIX SECONDS")
    }

    /// ⛔ THE MOST ORDINARY INVOICE THERE IS — this month's, before it is paid —
    /// IS THE ONE THAT WOULD THROW ON A CLIENT TYPING THE LINKS NON-NULL. Stripe
    /// omits both until an invoice is finalised. ⚠️ And a zero `tax` is a
    /// MEASURED zero summed out of `total_taxes`, not an absence, which is what
    /// makes it safe to show.
    func testTheUnpaidInvoiceHasNoLinksAndAMeasuredZeroTax() throws {
        let billing = try StrictDecodeVerifier.verify(
            fixture: "district-billing.json",
            as: StripeBilling.self
        )
        XCTAssertEqual(billing.invoices.count, 2)
        let paid = billing.invoices[0]
        let open = billing.invoices[1]

        XCTAssertEqual(paid.amountPaid, 24900)
        XCTAssertEqual(paid.tax, 3237, "⛔ CENTS, and a breakdown that only existed inside Stripe before")
        XCTAssertEqual(paid.created, 1_754_231_400, "⚠️ UNIX SECONDS, not milliseconds")
        XCTAssertNotNil(paid.hostedInvoiceUrl)

        XCTAssertEqual(open.amountPaid, 0)
        XCTAssertEqual(open.total, 1500, "a zero paid beside a non-zero total")
        XCTAssertEqual(open.tax, 0, "summed, not absent")
        XCTAssertNil(open.hostedInvoiceUrl, "⛔ render without an open action rather than with a dead one")
        XCTAssertNil(open.invoicePdf)
        XCTAssertEqual(open.status, "open")
    }

    /// ⛔ DEGRADED MODE, NOT FREE TIER, AND THE FLAG IS THE ONLY THING THAT SAYS
    /// SO. Nine of the fourteen healthy keys are ABSENT here — not null, absent —
    /// so a required field on any of them would fail to decode precisely when
    /// billing was already broken. ⚠️ The spending cap's nil on this path means
    /// "unknown", never "no cap": rendering it as "no spending cap set" states a
    /// fact about the customer's configuration during the one outage where it
    /// cannot be read.
    func testAStripeOutageIsAStateWhoseAbsentKeysMustNotBeReadAsAnswers() throws {
        let billing = try StrictDecodeVerifier.verify(
            fixture: "district-billing-unavailable.json",
            as: StripeBilling.self
        )

        XCTAssertEqual(billing.availability, .unavailable)
        XCTAssertEqual(billing.billingUnavailable, true)
        XCTAssertTrue(billing.subscriptions.isEmpty, "empty because nothing was read, not because there is none")
        XCTAssertTrue(billing.invoices.isEmpty)
        XCTAssertNil(billing.customerId)
        XCTAssertNil(billing.invoicesHasMore, "absent, so unknown")
        XCTAssertNil(billing.overagePolicy, "⚠️ trust `workspace/billing` for this pair during an outage")
        XCTAssertNil(billing.overageCapExceeded)
        XCTAssertNil(billing.overageSpendCapCents, "⛔ unknown, NEVER `no cap`")
        XCTAssertNil(billing.overageSpendCapExceeded)
    }

    /// ⛔ THE THIRD SHAPE, AND IT IS THE DEGRADED BODY **WITHOUT** THE FLAG. Byte
    /// for byte it is the fixture above minus `billingUnavailable`, and it means
    /// the OPPOSITE thing: this account genuinely has no Stripe customer, which a
    /// screen may legitimately render as "no billing set up". No Stripe call was
    /// made to find that out. A client branching on "are the arrays empty" would
    /// call an outage a free account — the conflation that routes a paying
    /// customer to a checkout page.
    func testAnAccountWithNoStripeCustomerIsTheSameBodyWithoutTheFlagAndTheOppositeMeaning() throws {
        let billing = try StrictDecodeVerifier.verify(
            fixture: "district-billing-no-customer.json",
            as: StripeBilling.self
        )

        XCTAssertEqual(billing.availability, .noCustomer)
        XCTAssertNil(billing.billingUnavailable, "⛔ the absent key IS the difference")
        XCTAssertNil(billing.customerId)
        XCTAssertTrue(billing.subscriptions.isEmpty)
        XCTAssertTrue(billing.invoices.isEmpty)
    }

    /// ⛔ THE ORDER OF THE TWO CHECKS IS LOAD-BEARING AND THIS IS WHAT PINS IT. An
    /// unavailable body ALSO carries `customerId: null`, so a discriminator that
    /// asked about the customer first would report every Stripe outage as an
    /// account with no billing. Decoded from literal bytes because no fixture
    /// carries the flag beside a real customer id.
    func testTheOutageFlagWinsOverTheCustomerIdWhicheverWayTheBodyIsBuilt() throws {
        let both = try decode(
            StripeBilling.self,
            from: #"""
            {"billingUnavailable":true,"subscriptions":[],"invoices":[],
             "paymentMethod":null,"billingAddress":null,"customerId":"cus_1"}
            """#
        )
        XCTAssertEqual(both.availability, .unavailable, "a known customer does not make an outage readable")

        let flagFalse = try decode(
            StripeBilling.self,
            from: #"""
            {"billingUnavailable":false,"subscriptions":[],"invoices":[],
             "paymentMethod":null,"billingAddress":null,"customerId":null}
            """#
        )
        XCTAssertEqual(flagFalse.availability, .noCustomer, "false is not true, and the account still has none")
    }
}
