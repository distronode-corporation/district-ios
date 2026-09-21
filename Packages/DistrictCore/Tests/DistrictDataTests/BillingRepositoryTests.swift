import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The billing screen's two calls.
///
/// ⛔ THE TWO HALVES USE DIFFERENT ENVELOPE RULES AND THAT IS WHAT THESE TESTS
/// ARE ABOUT. `workspace/billing` answers `{success, billing}` and MUST be
/// affirmed, because every field of `WorkspaceBilling` would otherwise decode
/// out of a `{}` body into a plan reading no tier, no status and — the dangerous
/// one — `overageCapExceeded: false`, which says "you are within your plan" and
/// is the opposite of the fact this screen exists to surface. `/api/billing`
/// sends no `success` key at all and must NOT be affirmed, because affirming an
/// absent flag rejects every healthy response.
///
/// ⛔ AND NOTHING HERE WRITES. There is no cancel, no plan change and no portal
/// URL, by App Store Review Guideline 3.1.3(b). A test that reached for one
/// would be testing a policy violation.
final class BillingRepositoryTests: XCTestCase {
    // MARK: - The workspace's own plan

    func testReadingTheWorkspacePlanGetsTheDistrictRouteWithTheWorkspaceInTheQuery() async {
        let transport = RepositoryTransport(json: BillingBodies.workspacePlan)

        let result = await BillingRepository(client: .repositoryTest(transport)).workspaceBilling(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.plan, "voicepro")
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/billing?workspaceId=ws_1"
        )
        // ⛔ A GET WITH NO BODY. Nothing about reading a plan is a write.
        XCTAssertTrue(transport.bodies.isEmpty)
    }

    /// ⛔ THE COMBINATION THAT MEANS CALLS ARE BEING REFUSED SURVIVES THE
    /// REPOSITORY. `hard_cap` plus an exceeded cap is an outage the operator is
    /// living through, and the app is the only place they can learn it from — so
    /// a layer that dropped either field would leave the screen unable to say so.
    func testACappedWorkspaceReachesTheCallerStillReportingRefusedCalls() async throws {
        let transport = RepositoryTransport(json: BillingBodies.workspaceCapped)

        let result = await BillingRepository(client: .repositoryTest(transport)).workspaceBilling(workspaceId: "ws_1")

        let billing = try XCTUnwrap(result.successOnly)
        XCTAssertTrue(billing.callsAreBeingRefused)
        XCTAssertNil(billing.usage, "⛔ nothing metered, which is not zero of everything")
        XCTAssertNil(billing.subscriptionTier, "⛔ null is not the word Free")
    }

    /// ⛔ A 200 CARRYING `success: false` IS NOT A PLAN. Every field of the DTO
    /// has a shape that would decode out of a thin body, and the reading a caller
    /// would act on is "within your plan" — so the envelope guard is the only
    /// thing between a refused read and a confident wrong number.
    func testABodyThatDoesNotAffirmSuccessIsADecodeFailureRatherThanAnEmptyPlan() async {
        let transport = RepositoryTransport(json: #"{"success":false,"billing":null}"#)

        let result = await BillingRepository(client: .repositoryTest(transport)).workspaceBilling(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("WorkspaceBillingResponse did not affirm success=true"))
        XCTAssertNil(result.successOnly)
    }

    /// ⛔ AN AFFIRMED 200 WITH NO `billing` OBJECT IS MALFORMED, NOT AN EMPTY
    /// PLAN. Absence of a plan is representable on the wire —
    /// `subscriptionStatus: "none"` beside a null tier — so a missing object can
    /// only mean drift, and reporting it as "no plan" would hide a server bug
    /// behind an ordinary empty state.
    func testAnAffirmedBodyWithNoBillingObjectIsReportedAsDrift() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await BillingRepository(client: .repositoryTest(transport)).workspaceBilling(workspaceId: "ws_1")

        XCTAssertEqual(
            result.failureOnly,
            .decoding("WorkspaceBillingResponse affirmed success but carried no billing")
        )
    }

    /// ⚠️ A SIGNED-OUT SESSION AND A VIEWER-LESS WORKSPACE ARE TRANSPORT-LEVEL
    /// REFUSALS AND PASS STRAIGHT THROUGH. Neither is a billing state, so neither
    /// may be turned into one.
    func testAuthorizationRefusalsPassThroughUntouched() async {
        let unauthorized = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let forbidden = RepositoryTransport(json: #"{"error":"Forbidden"}"#, status: 403)

        let first = await BillingRepository(client: .repositoryTest(unauthorized)).workspaceBilling(workspaceId: "ws_1")
        let second = await BillingRepository(client: .repositoryTest(forbidden)).workspaceBilling(workspaceId: "ws_1")

        XCTAssertEqual(first.failureOnly?.httpStatus, 401)
        XCTAssertEqual(second.failureOnly?.httpStatus, 403)
    }

    /// ⚠️ A 500 IS A TRANSIENT SERVER FAILURE AND NOT AN ACCOUNT WITH NO PLAN. A
    /// client that mapped it onto an empty plan would tell a paying customer they
    /// have none.
    func testAServerFailureIsAnErrorRatherThanAnAbsentPlan() async {
        let transport = RepositoryTransport(json: #"{"error":"Failed to load billing"}"#, status: 500)

        let result = await BillingRepository(client: .repositoryTest(transport)).workspaceBilling(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 500)
        XCTAssertNil(result.successOnly)
    }

    // MARK: - Stripe

    /// ⛔ NO `workspaceId` ANYWHERE ON THE REQUEST, AND THAT IS A SECURITY
    /// PROPERTY RATHER THAN A CONVENIENCE. The route resolves the caller's own
    /// Stripe customer from server-owned state; a parameter here would be an
    /// identity the caller supplied. The workspace comes BACK in the body.
    func testTheStripeReadSendsNoWorkspaceAndReadsTheOneTheServerNames() async {
        let transport = RepositoryTransport(json: BillingBodies.stripeHealthy)

        let result = await BillingRepository(client: .repositoryTest(transport)).stripeBilling()

        XCTAssertEqual(transport.requestedURLs.first, "https://www.distronode.com/api/billing")
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertTrue(transport.bodies.isEmpty)
        XCTAssertEqual(result.successOnly?.usageWorkspaceId, "ws-contract-test")
        XCTAssertEqual(result.successOnly?.availability, .available)
    }

    /// ⛔ THE BODY CARRIES NO `success` KEY AND THAT IS THE CONTRACT, NOT A THIN
    /// FIXTURE. Almost every district route answers `{success, …}` and this layer
    /// checks the flag by hand; this one does not send one, so a repository that
    /// affirmed an envelope would turn every healthy response — every working
    /// subscription — into a decode failure. Pinned explicitly because the
    /// mistake is a one-line copy from any neighbouring repository.
    func testAStripeBodyWithNoSuccessEnvelopeIsStillASuccess() async {
        let transport = RepositoryTransport(json: BillingBodies.stripeHealthy)

        let result = await BillingRepository(client: .repositoryTest(transport)).stripeBilling()

        XCTAssertNil(result.failureOnly, "there is no envelope flag to fail on")
        XCTAssertEqual(result.successOnly?.subscriptions.count, 1)
    }

    /// ⛔ A STRIPE OUTAGE IS A STATE ON A **200**, NEVER AN ``ApiError``.
    /// Promoting the flag to a failure would collapse it into the same generic
    /// error as an account with no billing and lose the only thing that tells
    /// them apart; demoting it to nothing would draw an outage as a free account.
    func testAStripeOutageArrivesAsASuccessCarryingTheUnavailableState() async throws {
        let transport = RepositoryTransport(json: BillingBodies.stripeUnavailable)

        let result = await BillingRepository(client: .repositoryTest(transport)).stripeBilling()

        XCTAssertNil(result.failureOnly, "⛔ a 200 carrying a state, not an error")
        let billing = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(billing.availability, .unavailable)
        XCTAssertNil(billing.overageSpendCapCents, "⛔ unknown during the outage, NEVER `no cap`")
    }

    /// ⛔ THE SAME BODY WITHOUT THE FLAG MEANS THE OPPOSITE, AND THE REPOSITORY
    /// MUST NOT FLATTEN THE TWO. This account genuinely has no Stripe customer,
    /// which is a legitimate state a screen may render as "no billing set up".
    func testAnAccountWithNoStripeCustomerIsADistinctStateRatherThanTheOutage() async {
        let transport = RepositoryTransport(json: BillingBodies.stripeNoCustomer)

        let result = await BillingRepository(client: .repositoryTest(transport)).stripeBilling()

        XCTAssertNil(result.failureOnly)
        XCTAssertEqual(result.successOnly?.availability, .noCustomer)
    }

    /// ⚠️ THE ROUTE IS `requireAuth`-GUARDED, so a signed-out session is a 401
    /// and not a billing state.
    func testASignedOutStripeReadIsA401RatherThanADegradedBody() async {
        let transport = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)

        let result = await BillingRepository(client: .repositoryTest(transport)).stripeBilling()

        XCTAssertEqual(result.failureOnly?.httpStatus, 401)
        XCTAssertNil(result.successOnly)
    }
}

/// Minimal, VALID bodies for the billing shapes.
///
/// ⚠️ NOT THE CONTRACT FIXTURES. `district-billing*.json` and
/// `district-workspace-billing*.json` pin the wire shape through the strict
/// gate; what lives here is the smallest body that satisfies the Swift type, so
/// these tests can be about envelopes, paths and outcomes rather than about
/// JSON. ⛔ The three Stripe bodies carry NO `success` key, because the route
/// sends none.
private enum BillingBodies {
    static let workspacePlan = #"""
    {"success":true,"billing":{"subscriptionTier":"VoicePro","subscriptionStatus":"active",
     "plan":"voicepro","overagePolicy":"auto_bill","overageCapExceeded":false,
     "usage":{"month":"2026-08"}}}
    """#

    static let workspaceCapped = #"""
    {"success":true,"billing":{"subscriptionTier":null,"subscriptionStatus":"past_due",
     "plan":"voicestarter","overagePolicy":"hard_cap","overageCapExceeded":true,"usage":null}}
    """#

    static let stripeHealthy = #"""
    {"subscriptions":[{"id":"sub_1","status":"active","current_period_end":1756909800,
     "cancel_at_period_end":false,"tierName":"District AI Voice Pro","amount":24900}],
     "invoices":[],"invoicesHasMore":false,"paymentMethod":null,"billingAddress":null,
     "customerId":"cus_1","usageWorkspaceId":"ws-contract-test","overagePolicy":"auto_bill",
     "overageCapExceeded":false,"overageSpendCapCents":5000,"overageSpendCapExceeded":false}
    """#

    /// ⛔ SIX KEYS, WHICH IS THE POINT: nine of the healthy body's fourteen are
    /// ABSENT here, so a required field on any of them would fail to decode
    /// precisely when billing was already broken.
    static let stripeUnavailable = #"""
    {"billingUnavailable":true,"subscriptions":[],"invoices":[],"paymentMethod":null,
     "billingAddress":null,"customerId":null}
    """#

    /// ⛔ THE SAME SIX MINUS THE FLAG, AND THE OPPOSITE MEANING.
    static let stripeNoCustomer = #"""
    {"subscriptions":[],"invoices":[],"paymentMethod":null,"billingAddress":null,"customerId":null}
    """#
}
