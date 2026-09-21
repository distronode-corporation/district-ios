import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// The Stripe half of ``BillingContent``.
///
/// ⛔ **FOUR** STATES, NOT TWO, AND THREE OF THEM ARRIVE ON A 200. `GET /api/billing`
/// answers success in every one of these cases and the last two differ on the wire by a
/// single absent key:
///
/// - ``ready(_:)`` — a real customer, with subscriptions and invoices that may
///   legitimately be empty.
/// - ``noCustomer`` — this account has never had a Stripe customer. Nothing failed and no
///   vendor was called.
/// - ``unavailable`` — `billingUnavailable: true`. **Stripe could not be reached.**
/// - ``failed(_:)`` — a genuine transport or contract failure: an unreachable origin, a
///   dead session, a shape this build cannot parse.
///
/// ⛔ COLLAPSING `noCustomer` INTO `unavailable` EITHER WAY IS THE EXPENSIVE MISTAKE. One
/// direction tells a subscribed customer they have no plan during a vendor outage; the
/// other tells an unstarted account that billing is broken. It is the same "we could not
/// look" against "there is nothing" conflation that can send a paying customer to a
/// checkout page, except about their PLAN.
///
/// ⚠️ A DELIBERATE DIVERGENCE FROM ANDROID, WHICH HAS THREE. There `noCustomer` renders
/// as `Ready` with empty lists and the words "No subscription is attached to this
/// account", because its DTO cannot tell the two apart from the arrays alone. This
/// client's ``StripeBilling/availability`` decides it once, in the model layer, so a card
/// cannot forget to.
enum BillingStripeState {
    case ready(StripeBilling)
    case noCustomer
    case unavailable
    case failed(FailureText)
}

/// Everything the screen draws once the plan read has answered.
///
/// ⚠️ ``refreshing`` MEANS A RELOAD IS IN FLIGHT OVER FIGURES ALREADY ON SCREEN. Blanking
/// a plan card to re-fetch the same plan would flash the screen for nothing.
struct BillingContent {
    let plan: WorkspaceBilling
    let stripe: BillingStripeState
    let refreshing: Bool
}

/// The three top-level states.
///
/// ⛔ ``failed(_:)`` MEANS THE **WORKSPACE PLAN** READ FAILED, NOT THAT BOTH DID, and that
/// is a deliberate asymmetry from ``AnalyticsState`` where the whole-screen failure needs
/// every read to fail. Two reasons, and the second is the load-bearing one:
///
/// 1. Without a tier and a status there is no headline for this screen. An invoice list
///    under no plan is a receipt drawer, not a billing page.
/// 2. The Stripe read **cannot be relied on to report a failure at all.** Its outage
///    shape is a 200 carrying `billingUnavailable`, so an "only fail when both fail" rule
///    would keep a screen alive on a plan read that genuinely failed, beside a Stripe
///    section that was merely unavailable, with nothing true on it.
enum BillingState {
    case loading
    case content(BillingContent)
    case failed(FailureText)
}

/// Drives the Billing screen: two independent reads, one workspace, no writes.
///
/// ⛔ THIS MODEL HAS NO MUTATION AND MUST NOT GROW ONE. No cancel, no plan change, no
/// payment method, and no URL handed out for a browser to open. `POST /api/billing` does
/// all of that and is not modelled anywhere in this client; App Store Review Guideline
/// 3.1.3(b) is why, and it is not a product preference. See ``BillingRepository``.
///
/// ⛔ THE TWO READS RUN CONCURRENTLY, AND HERE THAT IS AVAILABILITY RATHER THAN LATENCY.
/// The plan comes from OUR OWN columns and reaches no vendor; the Stripe read is only as
/// available as Stripe is. In the obvious sequential shape a failing Stripe call would
/// stop the plan read being ISSUED at all, and the plan read is precisely the one that
/// works when Stripe does not: the tier, the status, and whether an overage cap is
/// blocking calls right now. `async let` makes "either half can be late or absent without
/// touching the other" structural rather than something each branch has to remember.
///
/// ⛔ AND BOTH LAND BEFORE CONTENT IS PUBLISHED, for the reason ``AnalyticsModel``
/// documents: emitting the first arrival would let a reader see an empty invoice area
/// beside a populated plan card and read the emptiness as "no invoices" rather than as
/// "still loading".
///
/// ⚠️ `@Observable` AND `@MainActor`, NOT `ObservableObject`. iOS 17 is the floor.
@MainActor
@Observable
final class BillingModel {
    private(set) var state: BillingState = .loading

    /// Whether this member could change the plan if they were on the web.
    ///
    /// ⛔ IT DECIDES WORDING AND NOTHING ELSE, because there is nothing on this screen to
    /// mutate. A viewer cannot make the change on the web dashboard either, so pointing
    /// them at it would be useless advice; they are told who can. The same call the
    /// marketplace makes, and the reason ``Route/billing(workspaceId:role:)`` carries a
    /// role at all.
    ///
    /// ⚠️ `allowsMutation` ON THE OPTIONAL RATHER THAN `role != .viewer`. A role the wire
    /// did not parse is nil, and nil must fail CLOSED to the narrower sentence rather
    /// than promoting an unknown member to someone who can change the plan.
    let canManage: Bool

    private let container: AppContainer
    private let workspaceId: String

    /// ⚠️ TAKES THE CONTAINER, NEVER A REPOSITORY. Every repository is a `let` on the
    /// container built from the one ``ApiClient``; one constructed here would reach a
    /// second ``TokenRefreshCoordinator``.
    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.container = container
        self.workspaceId = workspaceId
        canManage = WorkspaceRole.allowsMutation(role)
    }

    /// Read both halves.
    ///
    /// ⚠️ NOT GUARDED AGAINST A CONCURRENT CALL, unlike anything that spends money. Both
    /// are idempotent GETs and the Stripe half is a read of the caller's own customer
    /// rather than a write, so a double trigger costs one wasted round trip and a
    /// duplicated state write of the same value.
    func load(refreshing: Bool = false) async {
        state = Self.pending(from: state, refreshing: refreshing)

        // ⚠️ HOISTED TO LOCALS BEFORE THE `async let`, DELIBERATELY. The initialiser of an
        // `async let` runs concurrently, so anything it captures has to be `Sendable`, and
        // `self` is a `@MainActor` class that is not. A repository is a `Sendable` struct
        // wrapping the shared client, so copying it out first is both correct and free.
        let repository = container.billing
        let workspace = workspaceId

        async let plan = repository.workspaceBilling(workspaceId: workspace)
        // ⛔ NO `workspaceId`, AND IT COULD NOT TAKE ONE. The route resolves the caller's
        // OWN Stripe customer from server-owned state; the workspace it reported on comes
        // BACK in `usageWorkspaceId`. See ``BillingRepository/stripeBilling()``.
        async let stripe = repository.stripeBilling()

        state = await Self.publish(plan: plan, stripe: stripe)
    }

    /// Whether the Stripe half is describing a different tenant from the one on screen.
    ///
    /// ⚠️ THE MISMATCH IS DETECTABLE ONLY BECAUSE BOTH HALVES ARE HELD. The plan is always
    /// about the workspace that was asked for; the Stripe answer is about whichever
    /// workspace of this user carried the linkage. The server logs a warning when they
    /// disagree, and this is the client half of that.
    ///
    /// ⚠️ A nil `usageWorkspaceId` IS NOT A MISMATCH. It is absent on both degraded
    /// bodies, and "unknown" must not read as "someone else's".
    func namesAnotherWorkspace(_ stripe: StripeBilling) -> Bool {
        guard let reported = stripe.usageWorkspaceId else { return false }
        return reported != workspaceId
    }

    /// ⚠️ KEEPS THE FIGURES ON SCREEN FOR A RELOAD and shows ``BillingState/loading`` only
    /// when there is nothing to keep.
    private static func pending(from current: BillingState, refreshing: Bool) -> BillingState {
        guard refreshing, case let .content(content) = current else { return .loading }
        return .content(
            BillingContent(plan: content.plan, stripe: content.stripe, refreshing: true)
        )
    }

    /// ⛔ `billingUnavailable` AND A MISSING CUSTOMER ARE MAPPED TO STATES HERE RATHER
    /// THAN LEFT TO THE SCREEN. They are the two branches that must never be rendered as a
    /// free or unstarted account, and putting the decision in the state machine means a
    /// card cannot forget to make it. ``StripeBilling/availability`` is the only
    /// sanctioned way to ask, and it reads the flag BEFORE the customer id, because an
    /// unavailable body also carries `customerId: null`.
    private static func publish(
        plan: Result<WorkspaceBilling, ApiError>,
        stripe: Result<StripeBilling, ApiError>
    ) -> BillingState {
        // ⚠️ NAMED `stripeSection` RATHER THAN `section`, so the initialiser can call
        // ``stripeSection(for:)`` without the constant being declared shadowing the
        // function inside its own initialiser expression.
        let stripeSection: BillingStripeState = switch stripe {
        case let .success(detail): Self.stripeSection(for: detail)
        case let .failure(error): .failed(FailureText.from(error))
        }

        switch plan {
        case let .success(billing):
            return .content(BillingContent(plan: billing, stripe: stripeSection, refreshing: false))
        case let .failure(error):
            return .failed(FailureText.from(error))
        }
    }

    private static func stripeSection(for detail: StripeBilling) -> BillingStripeState {
        switch detail.availability {
        case .available: .ready(detail)
        case .noCustomer: .noCustomer
        case .unavailable: .unavailable
        }
    }
}
