import DistrictModel
import SwiftUI
import UIKit

/// The scheduling hub: what state the tenancy is in, the one button that provisions
/// one, and the way in to the nine sections.
///
/// ⛔ THE NATIVE SECTIONS ARE THE PRODUCT AND THE HAND-OFF IS THE FALLBACK.
/// `POST /api/district/scheduling/admin` is a catalogued allowlist of seventy-five
/// operations (``SchedulingAdminOp``), with typed DTOs and repository methods for every
/// one, and the scheduler's own admin console is retired — `scheduling/sso` answers
/// **410** — so event types, availability, questions and branding are edited here.
///
/// ⛔ AND NOTHING ON THIS SCREEN OFFERS A PURCHASE PATH. A workspace the feature
/// does not admit gets one sentence and no control at all: App Store Review
/// Guideline 3.1.3(b) forbids the purchase, and a "contact sales" link out of a
/// paid product's own settings is that offer wearing a different hat.
///
/// ⛔ THE SECTION LIST APPEARS ONLY FOR A `live` TENANCY. Every one of the nine reads
/// answers **409 `scheduling_not_ready`** without one, so offering the rows earlier would
/// be nine links to the same refusal — and the refusal's own sentence ("Scheduling is not
/// set up for this workspace yet") is already what the card above says, better.
///
/// ⛔ `canManage` STILL COMES FROM THE SERVER AND IS NOT RE-DERIVED FROM THE ROLE. The
/// status route answers it for exactly this purpose; a second gate built from a role
/// STRING would fail closed on a role that did not parse and hide Enable from an owner the
/// server would have admitted. ⚠️ The role IS used, for one thing only: the recordings
/// section's download affordance, whose bar is narrower than the list beside it.
///
/// ⚠️ EVERY STATE GETS ITS OWN SENTENCE. A workspace with no tenancy row, a
/// provision that failed and a read that never landed are three different answers
/// and none of them is "there is nothing here"; see ``SchedulingPresentation`` and
/// ``FailureText``.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and
/// registers `navigationDestination(for: Route.self)` on it exactly once.
struct SchedulingHubView: View {
    @State private var model: SchedulingModel

    let workspaceId: String
    let role: WorkspaceRole?

    /// ⛔ THE HAND-OFF LIVES HERE, FOR AS LONG AS THE SHEET IS UP, AND NOWHERE
    /// ELSE. Its URL carries a 60-second single-use token, so `sheet(item:)` is
    /// what guarantees it is dropped the moment the browser closes — SwiftUI
    /// writes nil back through the binding itself. The model deliberately answers
    /// the URL rather than storing it; see ``SchedulingModel/manageScheduling()``.
    @State private var handOff: SchedulingHandOff?

    /// ⚠️ DOES NOT TIME OUT, ON PURPOSE. A confirmation that reverts needs a timer
    /// task whose only job is to change a label back, and it resets on leaving the
    /// screen anyway. The button says what it did and keeps saying it.
    @State private var copied = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        self.role = role
        // ⚠️ `State(initialValue:)` in `init`, as every other model-owning screen
        // does: building it in `body` would be a new model, and a new read, on
        // every redraw.
        _model = State(initialValue: SchedulingModel(container: container, workspaceId: workspaceId))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⛔ THE WHOLE POLLING POLICY, IN ONE VALUE. `task(id:)` starts the loop when
    /// this flips true and CANCELS it when it flips false, so the poll runs only
    /// while the tenancy is provisioning and the scene is active — and the task's
    /// own lifetime ends when this view disappears, which covers navigating away.
    /// A timer owned by the model would keep running through all three.
    private var pollsNow: Bool {
        scenePhase == .active && model.isProvisioning
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                notice
                content
                sections
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .accessibilityIdentifier(A11yID.Scheduling.root)
        .navigationTitle("Scheduling")
        .navigationBarTitleDisplayMode(.inline)
        .districtRefreshable { await model.load(.manual) }
        .task { await model.load() }
        .task(id: pollsNow) {
            guard pollsNow else { return }
            await model.pollWhileProvisioning()
        }
        .sheet(item: $handOff) { target in
            SafariView(url: target.url)
        }
    }

    // MARK: - Sections

    /// The nine native sections, for a tenancy that is live.
    ///
    /// ⛔ GATED ON THE TENANCY BEING `live`, NOT ON THE READ HAVING SUCCEEDED. A failed
    /// status read leaves ``SchedulingModel/state`` on `.failed` and draws no rows, which
    /// is right: the client does not know whether there is a booking page, so it must not
    /// offer nine links that may all answer 409.
    ///
    /// ⛔ AND EVERY ROW IS PRESENT FOR EVERY ROLE, WHICH IS A MEASUREMENT RATHER THAN AN
    /// OVERSIGHT. ``SchedulingSection/minReadRole`` is `viewer` for all nine, because the
    /// server's rule is "reads are viewer, writes are client" and every row opens a
    /// read. The row list is still built THROUGH that property rather than unconditionally,
    /// so the day a section's read needs `client` the hub drops it instead of offering a
    /// screen whose first request answers 403.
    @ViewBuilder
    private var sections: some View {
        if case let .ready(status) = model.state, status.tenant?.status == .ready {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                DistrictEyebrow(text: SchedulingCopy.sectionsEyebrow)
                sectionRows
                Text(SchedulingCopy.sectionsFootnote)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
    }

    private var sectionRows: some View {
        VStack(spacing: 0) {
            ForEach(visibleSections, id: \.self) { section in
                sectionLink(section)
                if section != visibleSections.last {
                    DistrictRowDivider()
                }
            }
        }
        .districtCardSurface()
    }

    /// ⚠️ ASKS THE SECTION'S OWN `minReadRole` RATHER THAN ANSWERING HERE, so that "who may
    /// open what" has one definition. A viewer clears every bar today; see the ⛔ on
    /// ``sections``.
    private var visibleSections: [SchedulingSection] {
        SchedulingSection.listed.filter { section in
            switch section.minReadRole {
            case .viewer: true
            case .client: WorkspaceRole.allowsMutation(role)
            }
        }
    }

    private func sectionLink(_ section: SchedulingSection) -> some View {
        NavigationLink(
            value: Route.scheduling(workspaceId: workspaceId, role: role, section: section)
        ) {
            DistrictListRow(
                title: SchedulingCopy.sectionTitle(section),
                subtitle: SchedulingCopy.sectionSubtitle(section),
                trailing: { chevron }
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.Scheduling.section(section.pathSegment ?? "hub"))
    }

    private var chevron: some View {
        // ⚠️ DECORATION. The row is a `NavigationLink`, so VoiceOver already announces it
        // as a button and says it opens something; a chevron on top of that is "chevron
        // dot right" read after every entry on the screen. Same call as
        // ``SettingsHubView``.
        Image(systemName: "chevron.right")
            .font(DistrictType.label)
            .foregroundStyle(colors.mutedForeground)
            .accessibilityHidden(true)
    }

    // MARK: - Notice

    /// ⚠️ ABOVE THE CARD RATHER THAN INSIDE IT, so a refused provision keeps its
    /// sentence even when the re-read that follows replaces the card with a
    /// failure of its own.
    @ViewBuilder
    private var notice: some View {
        if let message = model.notice {
            SchedulingNotice(message: message, onDismiss: model.dismissNotice)
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            LoadingView(message: "Loading scheduling…")
        case let .failed(failure):
            // ⛔ A FAILURE, NEVER AN EMPTY CARD. `tenant == nil` is a legitimate
            // answer on this surface, so the two would otherwise look identical.
            FailureView(failure: failure, onRetry: reload)
        case let .ready(status):
            card(status)
        }
    }

    private func card(_ status: SchedulingStatusResponse) -> some View {
        let presentation = SchedulingPresentation.from(status)
        return VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            header(presentation)
            Text(presentation.sentence)
                .font(DistrictType.bodySmall)
                .foregroundStyle(presentation.isFailure ? colors.destructive : colors.mutedForeground)
            detail(presentation)
            // ⛔ ASKED BEFORE THE ROW IS BUILT, NOT INSIDE IT. An `HStack` that
            // renders nothing still takes the stack's spacing and its own top
            // padding, so the two states that must offer NOTHING would each carry a
            // gap where a control used to be — which is how one quietly comes back.
            if presentation.offersAnyAction(eligible: status.eligible, canManage: status.canManage) {
                actions(status, presentation)
            }
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .districtCardSurface()
    }

    private func header(_ presentation: SchedulingPresentation) -> some View {
        HStack(spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: "Booking page")
            Spacer(minLength: DistrictSpacing.tight)
            if let badge = presentation.badge {
                DistrictBadge(text: badge.label, tone: badge.tone)
            }
        }
    }

    // MARK: - Per-state detail

    @ViewBuilder
    private func detail(_ presentation: SchedulingPresentation) -> some View {
        switch presentation {
        case let .live(tenant):
            liveDetail(tenant)
        case let .failedProvision(tenant):
            // ⛔ SHOWN TO ANY MEMBER, BY DESIGN. Somebody who cannot see why a
            // provision failed has to open a ticket to learn it, and the server
            // already classifies and truncates this string so it can never carry a
            // credential or a raw remote body.
            Text(SchedulingCopy.setupFailed(tenant.lastError))
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.destructive)
        case let .provisioning(tenant), let .switchedOff(tenant):
            Text(SchedulingCopy.hostLine(tenant.publicHost))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        case .notEligible, .legacy:
            EmptyView()
        }
    }

    /// The live booking page: the link, the two ways to pass it on, the public
    /// host and when it was last observed provisioned.
    private func liveDetail(_ tenant: SchedulingTenant) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            if let link = tenant.bookingUrl {
                Text(link)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                bookingActions(link)
            } else {
                // ⛔ NEVER REBUILT FROM `publicHost`. The route derives this key
                // server-side and sends it only for a ready tenancy, so a client
                // that assembled its own would publish a booking link for a page
                // that is not there. Use the key or offer no link.
                Text(SchedulingCopy.liveWithoutLink)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            }
            Text(SchedulingCopy.hostLine(tenant.publicHost))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            if let stamp = tenant.lastReadyAt {
                Text(SchedulingCopy.lastReadyLine(stamp))
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
    }

    private func bookingActions(_ link: String) -> some View {
        HStack(spacing: DistrictSpacing.row) {
            Button(copied ? SchedulingCopy.copied : SchedulingCopy.copyLink) { copyBookingLink(link) }
                .buttonStyle(.districtSecondary)
            // ⚠️ ONLY WHEN THE STRING PARSES. `ShareLink` needs a real `URL`, and
            // a share sheet is a nicety where the copy button is the guarantee.
            if let url = URL(string: link) {
                ShareLink("Share", item: url)
            }
        }
    }

    // MARK: - Actions

    /// ⚠️ A PLAIN FUNCTION RATHER THAN A `@ViewBuilder` ONE, so the enable gate can
    /// be computed once in an ordinary `let` instead of inside a result builder.
    private func actions(_ status: SchedulingStatusResponse, _ presentation: SchedulingPresentation) -> some View {
        let offersEnable = presentation.offersEnable(eligible: status.eligible, canManage: status.canManage)
        return HStack(spacing: DistrictSpacing.row) {
            if presentation.offersOpen {
                // ⛔ ONE BUTTON, AND NO "Open scheduler". That spent `scheduling/sso`,
                // which answers **410** because the console it signed into is retired,
                // so every press would be a round trip to a refusal.
                // ⚠️ `schedulingHandoff` is the ESCAPE HATCH: it is how somebody
                // reaches the parts of the scheduler this app does not draw.
                browserButton
            }
            if offersEnable {
                enableButton
            }
            if presentation.offersRefresh {
                refreshButton
            }
        }
        .padding(.top, DistrictSpacing.tight)
    }

    /// ⛔ SECONDARY, NOT PRIMARY. The nine section rows below are the product and this is
    /// the way out for what they do not cover; a primary button here would send people
    /// out of the app to do things the app can do.
    private var browserButton: some View {
        Button(model.opening ? SchedulingCopy.opening : SchedulingCopy.openInBrowser, action: openInBrowser)
            .buttonStyle(.districtSecondary)
            .disabled(model.opening)
            // ⚠️ THE `Scheduling.open` ID IS STABLE ACROSS WORDING. A test pressing "the
            // way out of the app" should not have to change its identifier when the
            // words on the button change.
            .accessibilityIdentifier(A11yID.Scheduling.open)
    }

    private var enableButton: some View {
        Button(model.busy ? SchedulingCopy.enabling : SchedulingCopy.enable, action: enable)
            .buttonStyle(.districtPrimary)
            .disabled(model.busy)
            .accessibilityIdentifier(A11yID.Scheduling.enable)
    }

    private var refreshButton: some View {
        Button(SchedulingCopy.refresh, action: reload)
            .buttonStyle(.districtSecondary)
            .disabled(model.busy)
    }

    private func reload() {
        Task { await model.load(.manual) }
    }

    private func enable() {
        Task { await model.enable() }
    }

    /// ⛔ THE URL IS PUT STRAIGHT INTO THE SHEET AND NOWHERE ELSE. It is minted per
    /// press, lives about sixty seconds and may be spent once, so nothing caches it,
    /// nothing logs it, and the bearer that bought it never touches the browser. A stale
    /// one lands on a page saying the link has expired; the remedy is to close the sheet
    /// and press again, which is why the model re-mints rather than holding one.
    ///
    /// ⚠️ IT CALLS `manageScheduling()`, WHICH IS THE HAND-OFF MINT AND NOT THE RETIRED
    /// SSO ROUTE. The console hand-off on `scheduling/sso` answers **410**. ⛔ Do not
    /// wire a button back to it.
    private func openInBrowser() {
        Task {
            guard let url = await model.manageScheduling() else { return }
            handOff = SchedulingHandOff(url: url)
        }
    }

    private func copyBookingLink(_ link: String) {
        UIPasteboard.general.string = link
        copied = true
    }
}

/// One press of "Open scheduler", carried to the browser sheet.
///
/// ⛔ THE `id` IS A FRESH UUID AND NEVER THE URL. Identity has to change on every
/// press so a second hand-off re-presents rather than being deduplicated against a
/// token that has already been spent — and a URL used as an identity is a URL
/// SwiftUI keeps a copy of.
struct SchedulingHandOff: Identifiable {
    let id = UUID()
    let url: URL
}

/// A dismissible sentence above the card. Mirrors `DeviceNotice`.
private struct SchedulingNotice: View {
    let message: String
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.destructive)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.districtGhost)
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .districtCardSurface(bordered: false)
    }
}
