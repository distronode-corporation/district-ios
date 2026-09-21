import DistrictModel
import Foundation
import SwiftUI

/// The phone-number surface: what the workspace has, what a carrier has for sale, the
/// regulatory paperwork, and the carrier account underneath it all.
///
/// ⛔ RELEASING AND RECONFIGURING ARE HERE, on the ``MarketplaceTab/carrier`` and
/// per-number surfaces, behind confirmations that name the consequence.
///
/// ⛔ **BUYING IS ABSENT.** A purchase charges a setup fee AND opens a recurring monthly
/// charge for a service consumed inside the app, which is App Store Review Guideline
/// **3.1.1**: an in-app purchase or it is not offered at all. There is no control, no
/// ``EndpointID`` case, no ``DistrictPaths`` constant and no repository method, and
/// ``ApiRequestDescriptor``'s initialiser is internal — so the route is unconstructible
/// rather than merely undrawn. `NumberSurfaceTests` asserts that against the whole
/// expressible surface.
///
/// ⛔ NOTHING ON THIS SCREEN LEAVES IT, AND GUIDELINE 3.1.3(b) DOES NOT LICENSE A LINK OUT.
/// 3.1.3(b) is the MULTIPLATFORM SERVICES exception: it lets an app that runs on more than
/// one platform give a user ACCESS to content, subscriptions and features they acquired
/// elsewhere. It licenses nothing about pointing at the place they acquire them. 3.1.3's
/// own terms are the other half and they are a prohibition rather than a permission: an
/// app in that section may not use buttons, external links or other calls to action
/// directing customers to a purchasing mechanism other than in-app purchase.
/// ⛔ 3.1.1 CARRIES THE SAME PROHIBITION ON STEERING, AND PROSE IS NOT THE SAFE HALF.
/// Its anti-steering clause forbids the SIGNPOST, so ``MarketplaceCopy/purchaseElsewhere``
/// and every other sentence in the app names no destination. `StoreCopyTests` is the
/// gate that keeps it out.
///
/// ⛔ SO NOTHING IS NAMED AND NOTHING IS LINKED, WHICH IS TRUE OF THE WHOLE APP.
/// ``ShellView/lapsed(inactiveCount:)`` states the subscription is not active and stops;
/// ``BillingCopy/readOnly`` says the change is not available in this app; ``SchedulingCopy``'s
/// `notEligible` states the refusal and offers nothing; ``MarketplaceCopy/readOnly`` is
/// this screen's sentence. ``ShellView``'s own browser hand-off is a different thing: it
/// hands BACK a claimed URL the app cannot draw rather than pointing at a purchase.
///
/// ⛔ THE TWO MARKETPLACE READS STILL ADMIT `viewer` AND ARE NOT ROLE-GATED; THE PROVISIONING
/// TABS ARE A DIFFERENT ANSWER. Ten of the sixteen provisioning routes exclude `viewer`
/// server-side, so those controls are withheld and the viewer is told who can — a viewer must
/// not see a dead control, and must not be walked into a 403 on entry either. On the two READ
/// tabs the role still decides only the caption's wording. See the ⚠️ on
/// ``Route/marketplace(workspaceId:role:)`` and ``MarketplaceModel/canChangeNumbers``.
///
/// ⚠️ THE ROWS AND THE FORM LIVE IN `MarketplaceCards.swift`, the provisioning surfaces in
/// `RegistrationsSection.swift`, `CarrierSection.swift`, `ComplianceSection.swift` and
/// `NumberActionsSheet.swift`. This file owns the shell: the four segments, the dispatch into
/// each tab, the two sheets and the caption. Same split ``AnalyticsView`` uses, and for the
/// same `file_length` ceiling.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and
/// registers `navigationDestination(for: Route.self)` on it exactly once. ⛔ Which is also why
/// the per-number actions are a SHEET rather than a route: a destination holding an
/// irreversible release would be restored from a `NavigationPath` after process death
/// against a number that may no longer exist.
struct MarketplaceView: View {
    @State private var model: MarketplaceModel

    @State private var provisioning: NumberProvisioningModel

    /// Which owned number's actions are open, if any.
    ///
    /// ⛔ A SHEET RATHER THAN A `Route` CASE. This is a modal decision rather than a
    /// place, and a destination restored from a `NavigationPath` after process death
    /// would re-render a screen whose controls include an irreversible release, against
    /// a number that may no longer exist.
    @State private var openNumber: SelectedNumber?

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        // ⚠️ `State(initialValue:)` in `init`, as every other model-owning screen
        // does: building it in `body` would be a new model, and a new read, on every
        // redraw.
        _model = State(
            initialValue: MarketplaceModel(container: container, workspaceId: workspaceId, role: role)
        )
        _provisioning = State(
            initialValue: NumberProvisioningModel(container: container, workspaceId: workspaceId, role: role)
        )
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                segments
                tabContent
                readOnlyCaption
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        // ⛔ `.contain` BEFORE THE IDENTIFIER. Applied alone to a container it
        // propagates and overwrites every descendant's; measured on the sign-in screen.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Marketplace.root)
        .navigationTitle(MarketplaceCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        // ⛔ ONE TASK, AND IT IS THE OWNED LIST ONLY. See the ⛔ on
        // ``MarketplaceModel`` for why a search is never fired on entry — and the ⛔ there for
        // why the two provisioning reads are not fired here either: the filing list spends a
        // carrier call per in-review bundle, so it loads when its own tab is opened.
        .task { await model.loadOwned() }
        // ⛔ ONE SHEET PER DECISION, AND THE CONFIRMATION SHEET IS PRESENTED FROM THE MODEL'S
        // OWN STATE rather than from a local flag. That is what makes ``NumberProvisioningModel``
        // the only thing that can open a confirmation, and therefore what lets it REFUSE to open
        // one whose write is unarmed after a failed irreversible attempt.
        .sheet(item: $openNumber) { selection in
            NumberActionsSheet(model: provisioning, number: selection.number)
        }
        .sheet(isPresented: confirmationBinding) {
            NumberConfirmationHost(model: provisioning)
        }
    }

    // MARK: - The four segments

    /// ⚠️ BUTTONS RATHER THAN A `Picker`, matching Android for the reason its own
    /// note gives: this design system has no tab component, and inventing one for a
    /// single screen is how a second, drifting set of primitives starts.
    /// Primary-versus-secondary is already the system's "this one is active".
    ///
    /// ⚠️ FOUR OF THEM NOW, SO THEY SCROLL HORIZONTALLY rather than being squeezed below the
    /// 44pt touch target ``DistrictButtonSize`` records as the floor for a thumb.
    private var segments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DistrictSpacing.tight) {
                segment(MarketplaceCopy.tabOwned, tab: .owned)
                segment(MarketplaceCopy.tabSearch, tab: .search)
                segment(MarketplaceCopy.tabRegistrations, tab: .registrations)
                segment(MarketplaceCopy.tabCarrier, tab: .carrier)
            }
        }
    }

    /// ⚠️ `medium`, NOT `small`, WHICH IS A DELIBERATE DIVERGENCE FROM ANDROID'S
    /// `ButtonSize.Sm`. ``DistrictButtonSize`` records that 32pt is below Apple's
    /// 44pt touch-target guidance and that `small` is for pointer-dense surfaces
    /// only; all four of these are primary thumb targets on the screen.
    private func segment(_ label: String, tab: MarketplaceTab) -> some View {
        Button(label) { model.selectTab(tab) }
            .buttonStyle(DistrictButtonStyle(variant: model.tab == tab ? .primary : .secondary))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .owned:
            ownedSection
        case .search:
            searchSection
        case .registrations:
            // ⛔ LOADED WHEN THE TAB IS OPENED, NOT ON ENTRY. The route refreshes every
            // in-review filing FROM THE CARRIER on read, so this spends a customer's own
            // carrier calls and must not fire for someone who never opens the tab.
            RegistrationsSection(model: provisioning)
                .task { await provisioning.loadRegistrations() }
        case .carrier:
            // ⚠️ THREE INDEPENDENT READS, EACH WITH ITS OWN FAILURE, so one carrier hiccup
            // does not blank the other two panels. ⛔ The lookup is NOT loaded here: it is
            // billed per call and fires on one tap only.
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                CarrierSection(model: provisioning)
                NumberLookupCard(model: provisioning)
                ComplianceSection(model: provisioning)
            }
            .task {
                await provisioning.loadCarrier()
                await provisioning.loadVerify()
                await provisioning.loadSip()
            }
        }
    }

    /// ⛔ A BINDING THAT CAN ONLY CLOSE, WHICH IS THE POINT. Setting it true would open a
    /// confirmation the model never armed; only ``NumberProvisioningModel/requestConfirmation(_:)``
    /// may do that, and it refuses while the matching write is unarmed after a failed
    /// irreversible attempt. So this projects presence out and dismissal in, and nothing else.
    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { provisioning.confirmation != nil },
            set: { isOpen in
                if !isOpen {
                    provisioning.dismissConfirmation()
                }
            }
        )
    }

    // MARK: - My numbers

    @ViewBuilder
    private var ownedSection: some View {
        switch model.owned {
        case .loading:
            VStack(spacing: DistrictSpacing.row) {
                ForEach(0 ..< 4, id: \.self) { _ in
                    SkeletonBlock(height: 72)
                }
            }
        case let .ready(numbers, partial, failedProviders):
            OwnedNumbersList(
                numbers: numbers,
                partial: partial,
                failedProviders: failedProviders,
                onSelect: { openNumber = SelectedNumber(number: $0) }
            )
        case let .failed(failure):
            MarketplaceFailureCard(
                title: MarketplaceCopy.ownedFailed,
                failure: failure,
                onRetry: reloadOwned
            )
        }
    }

    // MARK: - Search

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            NumberSearchFormCard(
                areaCode: areaCodeBinding,
                country: countryBinding,
                selectedType: model.form.type,
                searching: model.isSearching,
                onSelectType: selectType,
                onSearch: runSearch
            )
            searchResults
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        switch model.search {
        case .idle:
            // ⚠️ NOTHING HAS BEEN SEARCHED YET, WHICH IS NOT "no numbers available".
            // The form above is the whole content of this state; an empty-results
            // message here would answer a question the operator has not asked.
            EmptyView()
        case .loading:
            SkeletonBlock(height: 72)
        case let .ready(provider, numbers):
            SearchResultsList(provider: provider, numbers: numbers)
        case let .notConfigured(message):
            // ⛔ AN EMPTY STATE, NOT A FAILURE, AND NO RETRY. See the ⛔ on
            // ``MarketplaceSearchState/notConfigured(_:)``.
            EmptyStateView(
                systemImage: "antenna.radiowaves.left.and.right.slash",
                title: MarketplaceCopy.notConfiguredTitle,
                message: message
            )
        case let .failed(failure):
            MarketplaceFailureCard(
                title: MarketplaceCopy.searchFailed,
                failure: failure,
                onRetry: runSearch
            )
        }
    }

    // MARK: - The read-only boundary

    /// ⛔ THE WHOLE OF THE BOUNDARY, AND IT IS TWO SENTENCES RATHER THAN A CONTROL. There is
    /// deliberately nothing beneath it: no button, no link and no caption offering to open a
    /// browser. See the ⛔ at the top of this file. ⚠️ The second sentence narrows the
    /// first: everything about a number EXCEPT buying one is in the app, so the screen
    /// as a whole is not read-only.
    private var readOnlyCaption: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(MarketplaceCopy.purchaseElsewhere)
            // ⚠️ THE ROLE STILL ONLY DECIDES WORDING ON THIS LINE, because the two marketplace
            // READS admit `viewer`. The provisioning tabs gate their own controls.
            Text(model.readOnlyCaption)
        }
        .font(DistrictType.caption)
        .foregroundStyle(colors.mutedForeground)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bindings

    /// ⚠️ BUILT BY HAND RATHER THAN PROJECTED OFF THE MODEL, so the form's only
    /// writer is ``MarketplaceModel``. Same shape ``ShellView/path(for:)`` and
    /// ``WorkflowsView``'s confirmation binding use.
    private var areaCodeBinding: Binding<String> {
        Binding(
            get: { model.form.areaCode },
            set: { model.updateAreaCode($0) }
        )
    }

    private var countryBinding: Binding<String> {
        Binding(
            get: { model.form.country },
            set: { model.updateCountry($0) }
        )
    }

    // MARK: - Actions

    /// ⚠️ EACH RETRY RE-RUNS ONLY ITS OWN READ. Retrying the owned list must not
    /// replace search results the operator is reading, which a shared reload would do.
    private func reloadOwned() {
        Task { await model.loadOwned() }
    }

    private func runSearch() {
        Task { await model.runSearch() }
    }

    /// ⚠️ A METHOD ON THIS VIEW RATHER THAN `model.updateType` PASSED DIRECTLY. Both
    /// are `@MainActor` functions handed to a plainly-typed parameter; routing through
    /// the view is the shape every other screen here already uses (``WorkflowsView``'s
    /// `onRetry: reloadCampaign`), so it is the one known to compile on the Mac.
    private func selectType(_ value: String) {
        model.updateType(value)
    }
}
