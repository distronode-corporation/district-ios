import DistrictModel
import DistrictNetwork
import Foundation

/// Billing: the plan we own, and the invoices Stripe owns.
///
/// ⛔ THE TWO READS ARE DELIBERATELY NOT COMBINED, AND THE REASON IS
/// AVAILABILITY RATHER THAN LATENCY. ``workspaceBilling(workspaceId:)`` reads
/// columns in OUR OWN database and reaches no vendor; ``stripeBilling()``
/// reaches Stripe and is therefore only as available as Stripe is. Folding them
/// into one `Result` would mean a Stripe outage blanking the tier, the status
/// and the overage cap — facts we hold locally and that a customer most needs
/// exactly when something is wrong with their billing. A caller runs them in
/// parallel and keeps two sub-states; this layer keeps each one honest on its
/// own.
///
/// ⛔ AND THE TWO HALVES USE DIFFERENT ENVELOPE RULES, WHICH IS THE THING TO READ
/// BEFORE EDITING EITHER METHOD. Almost every district route answers
/// `{success, …}` and ``ResponseEnvelope/affirm(_:_:_:)`` is what stops a `{}`
/// body decoding into a confident empty answer. **`GET /api/billing` has no
/// `success` key at all** — it returns the object bare — so affirming an
/// envelope there would reject every healthy response as contract drift, and
/// `district-billing.json` pins that absence so the difference cannot be argued
/// from memory.
///
/// ⛔ THERE ARE NO WRITES HERE AND THERE MUST NOT BE. `POST /api/billing`
/// cancels subscriptions, changes plans and detaches cards. Offering any of that
/// in-app breaches App Store Review Guideline 3.1.3(b), and so would surfacing a
/// portal URL for a screen to open. This is not the marketplace's read-only
/// decision, which was ours to revisit.
///
/// ⚠️ NO CACHING. Both answers are small, neither pages, and a stale plan or a
/// stale cap is exactly the kind of wrong number that becomes a support ticket.
public struct BillingRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// The workspace's plan, status, overage state and this month's usage.
    ///
    /// ⚠️ ENVELOPE FIRST, and it matters here as much as anywhere on this
    /// surface: a `{}` body would otherwise decode into a response whose
    /// `billing` is nil and whose `success` is the flag nobody checked. The
    /// dangerous reading is the overage one — "within your plan" is the opposite
    /// of the fact this screen exists to surface.
    ///
    /// ⛔ A 200 THAT AFFIRMS SUCCESS AND CARRIES NO `billing` OBJECT IS
    /// MALFORMED, NOT AN EMPTY PLAN, and is reported as a decode failure.
    /// Absence of a plan is representable — the server sends
    /// `subscriptionStatus: "none"` beside a null tier — so a missing object can
    /// only mean drift. The same distinction ``CallsRepository/detail(workspaceId:callId:)``
    /// draws, and the opposite call from ``AnalyticsRepository``'s usage read,
    /// where the null genuinely IS the payload.
    public func workspaceBilling(workspaceId: String) async -> Result<WorkspaceBilling, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.workspaceBilling(workspaceId: workspaceId),
            as: WorkspaceBillingResponse.self
        )
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("WorkspaceBillingResponse", response.success, response).flatMap { affirmed in
                guard let billing = affirmed.billing else {
                    return .failure(.decoding("WorkspaceBillingResponse affirmed success but carried no billing"))
                }
                return .success(billing)
            }
        }
    }

    /// Subscriptions and invoices, from Stripe.
    ///
    /// ⛔ NO ENVELOPE CHECK, AND ITS ABSENCE IS THE POINT. This route does not
    /// send `success` — not `false`, ABSENT — so ``ResponseEnvelope/affirm(_:_:_:)``
    /// would reject a perfectly good response every single time, and the screen
    /// would show contract-drift copy to every user with a working subscription.
    /// The strictness that guard provides elsewhere is supplied here by three
    /// committed fixtures decoded through the strict gate instead.
    ///
    /// ⛔ AND `billingUnavailable` IS CARRIED THROUGH AS A **STATE**, NEVER
    /// CONVERTED INTO A FAILURE. It arrives on a 200 with empty arrays, and the
    /// distinction it draws is the whole reason it exists: the SAME body without
    /// the flag means the account has no Stripe customer, which legitimately
    /// renders as "no billing set up". Promoting the flag to an ``ApiError``
    /// would collapse the two into one generic error and lose the only thing
    /// that tells them apart; demoting it to nothing would render a Stripe
    /// outage as a free account. Branch on
    /// ``StripeBilling/availability`` instead.
    ///
    /// ⛔ IT TAKES NO `workspaceId` AND COULD NOT. The route resolves the
    /// caller's OWN Stripe customer from server-owned state; the workspace it
    /// reported on comes BACK in ``StripeBilling/usageWorkspaceId``. A parameter
    /// here would be an identity the caller supplied.
    public func stripeBilling() async -> Result<StripeBilling, ApiError> {
        await client.send(DistrictEndpoints.stripeBilling(), as: StripeBilling.self)
    }
}
