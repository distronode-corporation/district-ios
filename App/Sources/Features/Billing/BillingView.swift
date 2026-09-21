import DistrictModel
import SwiftUI

/// Billing: what this workspace is on, what it is using, and what has been invoiced.
///
/// ⛔ READ ONLY, AND THAT IS NOT A DECISION THIS PROJECT MAY REVISIT. App Store Review
/// Guideline 3.1.3(b) is why there is no upgrade button, no plan picker, no cancel, no
/// promo field, no card editor and ⛔ **no link out to the Stripe portal or to a hosted
/// invoice** anywhere in this file or its siblings. Android's screen does hand a hosted
/// invoice URL to a browser; that is the one place where matching Android would fail
/// review, so it is deliberately not ported. See the ⛔ at the top of
/// `BillingStripeCards.swift`.
///
/// ⛔ THE CAPTION AT THE FOOT IS LOAD BEARING RATHER THAN DECORATIVE. A plan card with no
/// controls reads as a half-built screen unless it says the change cannot be made here.
/// ⛔ AND IT NAMES NOWHERE ELSE. Guideline 3.1.1's anti-steering clause covers the
/// signpost as well as the link, so the caption states the limitation and stops.
///
/// ⛔ THE PLAN HALF AND THE STRIPE HALF HAVE SEPARATE FAILURE STATES, AND THE SPLIT IS NOT
/// COSMETIC. The plan comes from our own database and the invoices come from Stripe, so
/// the common failure is one-sided by construction, and when Stripe is the half that is
/// down the surviving half is exactly what the customer needs: the tier, the status, and
/// whether an overage cap is blocking calls right now.
///
/// ⛔ A STRIPE OUTAGE RENDERS AS "TEMPORARILY UNAVAILABLE" AND AN ACCOUNT WITH NO CUSTOMER
/// RENDERS AS "NO BILLING SET UP", NEVER AS EACH OTHER AND NEVER AS AN EMPTY LIST. Both
/// arrive as a 200 with the same six keys and the same empty arrays; the only difference
/// is one flag. See ``BillingStripeState``.
///
/// ⚠️ THE CARDS LIVE IN TWO SIBLING FILES, SPLIT BY DATA SOURCE, which is also the failure
/// boundary: `BillingPlanCards.swift` holds the three built from our own columns and
/// `BillingStripeCards.swift` the ones built from the vendor's answer. This file owns the
/// shell: the scroll view, the three top-level states and the read-only caption.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and registers
/// `navigationDestination(for: Route.self)` on it exactly once.
struct BillingView: View {
    @State private var model: BillingModel

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        // ⚠️ `State(initialValue:)` in `init`, as every other model-owning screen does:
        // SwiftUI keeps the value for the lifetime of this view's identity, so the model
        // is not rebuilt on every re-render.
        _model = State(
            initialValue: BillingModel(container: container, workspaceId: workspaceId, role: role)
        )
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            content
                .padding(.bottom, DistrictSpacing.header)
        }
        // ⚠️ ON THE SCROLL VIEW RATHER THAN INSIDE A CONTENT BRANCH, so a failed read can
        // be pulled to retry rather than only through its button, and so the Stripe half
        // can be re-read without a control attached to a vendor outage.
        .districtRefreshable { await model.load(refreshing: true) }
        .task { await model.load() }
        .navigationTitle(BillingCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        // ⛔ `.contain` FIRST, or the plan and status cards inherit this identifier
        // and `A11yID.Billing.plan` never resolves. See SignInView's note.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Billing.root)
    }

    // ── States ───────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            LoadingView(message: BillingCopy.loading)
        case let .failed(failure):
            // ⛔ REACHED WHEN THE PLAN READ FAILED, NOT WHEN BOTH HALVES DID. Without a
            // tier and a status there is no headline for this screen, and the Stripe half
            // cannot be relied on to report a failure at all because its outage arrives as
            // a 200. See ``BillingState``.
            FailureView(failure: failure, onRetry: retry)
        case let .content(loaded):
            // ⚠️ THE ARGUMENT AND THE BUILDER ARE DELIBERATELY NOT THE SAME WORD.
            // `self.loaded(loaded)` would read fine and `--self remove` in `.swiftformat`
            // would then strip the `self.`, leaving a call that no longer resolves.
            stack(loaded)
        }
    }

    private func stack(_ content: BillingContent) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.section) {
            refreshingIndicator(content.refreshing)
            BillingPlanCard(plan: content.plan)
            BillingOverageCard(plan: content.plan)
            BillingUsageMeterCard(usage: content.plan.usage, included: allowance(content.stripe))
            stripeSection(content.stripe)
            caption
        }
        .padding(.horizontal, DistrictSpacing.gutter)
        .padding(.top, DistrictSpacing.gutter)
        .districtReadableWidth()
    }

    /// ⛔ THE ALLOWANCE EXISTS ONLY ON A STRIPE ANSWER THAT ARRIVED. During an outage
    /// there is nothing to measure against, so the meter is drawn without a bar rather
    /// than against an invented denominator. See ``BillingFormat/includedMinutes(_:)``.
    private func allowance(_ stripe: BillingStripeState) -> Int? {
        guard case let .ready(detail) = stripe else { return nil }
        return BillingFormat.includedMinutes(detail)
    }

    /// ⚠️ AN INDICATOR OF ITS OWN DURING A PULL TO REFRESH IS A SECOND SPINNER, AND IT IS
    /// ACCEPTED HERE FOR THE SAME REASON ``AnalyticsView`` ACCEPTS IT: a reload can also
    /// be triggered by a retry inside a card, which has no gesture and no system
    /// indicator, so without this the screen would look dead while two reads ran.
    @ViewBuilder
    private func refreshingIndicator(_ refreshing: Bool) -> some View {
        if refreshing {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    // ── The Stripe half ──────────────────────────────────────────────────────

    /// ⛔ FOUR ARMS, AND THE MIDDLE TWO ARE THE POINT. "We could not reach Stripe" and
    /// "this account has no Stripe customer" are one absent key apart on the wire and mean
    /// opposite things; neither may be rendered as the other and neither may be rendered
    /// as an empty list. See ``BillingStripeState``.
    @ViewBuilder
    private func stripeSection(_ stripe: BillingStripeState) -> some View {
        switch stripe {
        case let .ready(detail):
            // ⚠️ THE MISMATCH NOTICE COMES FIRST, because everything under it is about
            // whichever workspace this answer names.
            if model.namesAnotherWorkspace(detail) {
                BillingNote(text: BillingCopy.otherWorkspace)
            }
            BillingSubscriptionsCard(detail: detail)
            BillingSpendCapCard(detail: detail)
            BillingInvoicesCard(detail: detail)
        case .noCustomer:
            BillingNoCustomerCard()
        case .unavailable:
            BillingUnavailableCard()
        case let .failed(failure):
            // ⛔ FAIL-SOFT, INSIDE ITS OWN CARD. The plan card above it came from a
            // different server and is still correct.
            BillingCardFailure(title: BillingCopy.stripeFailed, failure: failure, onRetry: reload)
        }
    }

    // ── The read-only caption ────────────────────────────────────────────────

    /// ⛔ PROSE, NOT A LINK, AND NOT A BUTTON. See the ⛔ at the top of this type.
    ///
    /// ⚠️ WORDED PER ROLE, because a viewer cannot make the change anywhere else either:
    /// pointing them somewhere would be advice to a surface that will also refuse them, on
    /// top of being steering. The role decides nothing else on this screen, since there is
    /// nothing here to mutate.
    private var caption: some View {
        Text(model.canManage ? BillingCopy.readOnly : BillingCopy.readOnlyViewer)
            .font(DistrictType.caption)
            .foregroundStyle(colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── Loading ──────────────────────────────────────────────────────────────

    /// ⚠️ A COLD LOAD, FROM THE WHOLE-SCREEN FAILURE ONLY. That state has nothing worth
    /// preserving, and asking to keep content that is not there would leave the spinner
    /// off while the request ran.
    private func retry() {
        Task { await model.load() }
    }

    /// ⛔ A REFRESH RATHER THAN A COLD LOAD, AND THE DIFFERENCE IS THE WHOLE POINT OF A
    /// CARD-LEVEL RETRY. Both reads are re-issued either way, but a cold load would blank
    /// the plan card while it ran, and the plan card is the half that was still correct
    /// when the Stripe half failed. Discarding a correct answer to re-ask for a failed one
    /// is the mistake this screen is built to avoid.
    private func reload() {
        Task { await model.load(refreshing: true) }
    }
}
