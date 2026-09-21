import DistrictModel
import SwiftUI

/// The Overview tab: which workspace is in view, its four headline numbers, and
/// the calls that just happened.
///
/// ⛔ THE ENTRY POINTS LAND HERE. Android grew its column because the nav bar had no
/// room, and `OverviewScreen.kt` records the measurement rather than the preference: a
/// sixth text item pushes the bar past its width budget, where the failure is a control
/// squeezed silently out of reach instead of wrapping visibly. This client has the same
/// five tabs and the same ceiling, so the column comes over whole, in Android's order
/// and with its labels.
///
/// ⚠️ EVERY ONE OF THOSE DESTINATIONS RENDERS A REAL SCREEN, as Android's own header
/// asks ("a link is added here only once the screen behind it exists"), and a new
/// ``Route`` case fails to compile in `RouteDestinations` instead of landing on a stub.
///
/// ⚠️ TWO `task(id:)` MODIFIERS, AND THEY WATCH DIFFERENT THINGS. The workspace id
/// changes when the user switches tenant; ``SessionModel/epoch`` changes when a
/// sign-in COMPLETES, which is the mechanism that stops a screen holding a terminal
/// "your session has ended" after the user has signed back in. Android shipped
/// without the second one and the only way out of that state was killing the app.
struct OverviewView: View {
    let container: AppContainer
    let session: SessionModel
    let workspaceSession: WorkspaceSessionModel
    /// ⚠️ THE SHELL'S OWN SIGN-IN, PASSED DOWN. There is one ``SessionModel`` per
    /// process and ``RootView`` owns it; a second sign-in path here would leave the
    /// gate and this screen disagreeing about whether the user is signed in.
    let onSignIn: () -> Void
    /// ⛔ CALLS AND CONTACTS ARE TABS, NOT ROUTES. Pushing one would put a second copy
    /// of a tab root on THIS tab's stack, with its own scroll position and a back
    /// button out of it. The selection lives in ``ShellPaths``, so the switch travels up.
    let onSelectTab: (Tab) -> Void
    /// ⚠️ FALSE ON REGULAR WIDTH, where every row of the entry column is a sidebar row.
    var showsEntryPoints = true

    @State private var model: OverviewModel
    /// ⛔ THE DE-DUPLICATOR FOR THE TWO `task(id:)` MODIFIERS ABOVE. Both fire on
    /// first appearance, so without this every appearance of this tab costs two
    /// identical requests. Keyed on both ids so a change to EITHER still reloads.
    @State private var loadedKey: String?
    @State private var isPickerPresented = false
    /// The owner mid-setup's card. ⚠️ Its own model: see the ⛔ on ``FinishSetupModel``.
    @State private var setup: FinishSetupModel
    @State private var setupHandOff: AppLinkHandOff?

    @Environment(\.colorScheme) private var colorScheme

    init(
        container: AppContainer,
        session: SessionModel,
        workspaceSession: WorkspaceSessionModel,
        onSignIn: @escaping () -> Void,
        onSelectTab: @escaping (Tab) -> Void
    ) {
        self.container = container
        self.session = session
        self.workspaceSession = workspaceSession
        self.onSignIn = onSignIn
        self.onSelectTab = onSelectTab
        // ⚠️ `State(initialValue:)` in `init`, exactly as `ShellView` does with
        // `WorkspaceSessionModel`: SwiftUI keeps the value for the lifetime of this
        // view's identity, so the model is not rebuilt on every re-render.
        _model = State(initialValue: OverviewModel(container: container))
        _setup = State(initialValue: FinishSetupModel(container: container))
    }

    var body: some View {
        ScrollView {
            content
                .padding(.bottom, DistrictSpacing.header)
        }
        // ⚠️ ON THE SCROLL VIEW RATHER THAN INSIDE THE CONTENT BRANCH, so a failed
        // read can still be pulled to retry rather than only through its button.
        .districtRefreshable { await reload(refreshing: true) }
        .task(id: workspaceSession.workspaceId) { await reload() }
        .task(id: session.epoch) { await reload() }
        .sheet(isPresented: $isPickerPresented) {
            WorkspacePickerSheet(workspaceSession: workspaceSession)
        }
        // ⛔ A SAFARI SHEET, NOT `openURL`: the page is one this app claims. See ``FinishSetupCard``.
        .sheet(item: $setupHandOff) { handOff in
            SafariView(url: handOff.url)
        }
        .navigationTitle(Tab.overview.label)
        // ⛔ `.contain` FIRST. See the long note in SignInView: an identifier on a
        // container is INHERITED, so applied alone it stamps every metric tile and
        // activity row with `district-overview-root` and overwrites their own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Overview.root)
    }

    // ── States ───────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            LoadingView(message: "Loading your overview…")
        case let .failed(failure):
            FailureView(failure: failure, onRetry: retry, onSignIn: onSignIn)
        case let .content(response, _):
            loaded(response)
        }
    }

    private func loaded(_ response: OverviewResponse) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.section) {
            header(response)
            partialCaption
            finishSetup(response)
            metricTiles(response)
            recentActivity(response)
            // ⚠️ BELOW RECENT ACTIVITY, WHERE ANDROID PUTS IT: above, ten rows of
            // navigation would push the calls off a small screen.
            if showsEntryPoints {
                entryPoints(response)
            }
        }
        .padding(.top, DistrictSpacing.gutter)
    }

    // ── Header ───────────────────────────────────────────────────────────────

    /// ⚠️ RENDERED ONLY WITH A REAL ENTRY. A placeholder name over real numbers
    /// would be the same lie the mismatch guard in ``OverviewModel`` exists to stop.
    @ViewBuilder
    private func header(_ response: OverviewResponse) -> some View {
        if let entry = workspaceSession.selectedEntry {
            WorkspaceHeader(
                name: entry.name,
                region: entry.region,
                // ⛔ THE OVERVIEW'S ROLE, NOT THE LIST'S. The server can grant
                // `agency` for support access with no membership row at all, and
                // `workspace/list` reports the membership role while this route
                // reports the EFFECTIVE one. ⚠️ And `allowsMutation` rather than
                // `== .viewer`, so an unparsed role also reads as read-only:
                // `fromWire` fails closed and nil means no privileges.
                isReadOnly: !WorkspaceRole.allowsMutation(WorkspaceRole.fromWire(response.role)),
                canSwitch: workspaceSession.workspaces.count > 1,
                onSwitch: { isPickerPresented = true }
            )
            .padding(.horizontal, DistrictSpacing.gutter)
        }
    }

    /// ⛔ SURFACED, NOT SWALLOWED. The figures are correct — they came from one
    /// workspace — but the switcher is missing entries, and implying the user has
    /// fewer workspaces than they do is the same class of mistake as showing an
    /// empty account.
    @ViewBuilder
    private var partialCaption: some View {
        if case let .partial(_, _, regions) = workspaceSession.state {
            PartialWorkspacesCaption(regions: regions)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DistrictSpacing.gutter)
        }
    }

    // ── Setup ────────────────────────────────────────────────────────────────

    /// ⚠️ ABOVE THE METRICS, and only for the workspace whose numbers are on screen.
    @ViewBuilder
    private func finishSetup(_ response: OverviewResponse) -> some View {
        let offered = setup.isOffered && setup.workspaceId == response.workspaceId
        if offered, let url = FinishSetupCard.destination(baseURL: container.baseURL) {
            FinishSetupCard(onOpen: { setupHandOff = AppLinkHandOff(url: url) })
                .padding(.horizontal, DistrictSpacing.gutter)
        }
    }

    // ── Metrics ──────────────────────────────────────────────────────────────

    /// ⚠️ A HAND-BUILT 2×2, NOT A `LazyVGrid`. Four items, never more and never
    /// fewer, and a lazy grid inside this scroll view would need an explicit height
    /// — which hardcodes the very measurement the grid was supposed to compute.
    private func metricTiles(_ response: OverviewResponse) -> some View {
        let metrics = response.metrics
        return VStack(spacing: DistrictSpacing.row) {
            HStack(spacing: DistrictSpacing.row) {
                MetricTile(label: "Total Calls Routed", value: "\(metrics.totalCalls)", caption: "Cumulative")
                MetricTile(label: "Weekly Call Volume", value: "\(metrics.callsThisWeek)", caption: "Last 7 days")
            }
            HStack(spacing: DistrictSpacing.row) {
                MetricTile(label: "Customer Contacts", value: "\(metrics.totalContacts)", caption: "CRM")
                // ⛔ THE SERVER'S LABEL, NOT A LOCAL FORMAT. Two duration formats
                // ship in this product and disagree on the same input: this tile
                // omits a zero minutes component ("45s") while a call row always
                // emits one ("0m 45s"). Formatting `metrics.avgDuration` here would
                // make the app disagree with the browser on every sub-minute
                // average.
                //
                // ⛔ THE CAPTION MUST NOT SAY "Per call". The server averages
                // `status: 'completed'` only, as an EXACT case-sensitive match, over
                // ALL TIME. `Call.status` stores the raw provider value by design, so
                // every `answered`, `machine` and `human` row is outside this average,
                // and it is not "per call" by a wide margin.
                //
                // ⚠️ AND IT IS A DIFFERENT POPULATION FROM THE ANALYTICS TILE OF THE
                // SAME NAME, which takes four statuses within the selected window. The
                // two numbers are both correct and will not match; the captions are
                // what tell an operator why. Do not make them agree by editing the copy.
                MetricTile(
                    label: "Avg Call Duration",
                    value: response.avgDurationLabel,
                    caption: "Completed, all time"
                )
            }
        }
        .padding(.horizontal, DistrictSpacing.gutter)
    }

    // ── Recent activity ──────────────────────────────────────────────────────

    private func recentActivity(_ response: OverviewResponse) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            DistrictEyebrow(text: "Recent Activity")
                .padding(.horizontal, DistrictSpacing.gutter)
            calls(response)
        }
    }

    /// ⛔ AN EMPTY LIST GETS ITS OWN SENTENCE. Every list in this app can reach this
    /// state on day one of a new workspace, and a blank expanse is indistinguishable
    /// from a failed load to the person holding the phone.
    @ViewBuilder
    private func calls(_ response: OverviewResponse) -> some View {
        if response.recentCalls.isEmpty {
            EmptyStateView(
                systemImage: "phone",
                title: "Nothing here yet",
                message: "Inbound and outbound calls will appear here as they happen."
            )
        } else {
            // ⚠️ `response.workspaceId` RATHER THAN THE SESSION'S. It is the
            // workspace that actually answered, and `OverviewModel` has already
            // refused the response if the two disagreed — so a row pushed from here
            // carries an id that matches the numbers above it.
            callRows(response.recentCalls, workspaceId: response.workspaceId)
        }
    }

    private func callRows(_ rows: [CallSummary], workspaceId: String) -> some View {
        ForEach(rows, id: \.id) { call in
            VStack(spacing: 0) {
                // ⚠️ `NavigationLink(value:)`, resolved by the ONE
                // `navigationDestination(for: Route.self)` registered in
                // `ShellView`. The call-detail screen behind it is real.
                NavigationLink(value: Route.callDetail(workspaceId: workspaceId, callId: call.id)) {
                    ActivityRow(call: call)
                }
                .buttonStyle(.plain)
                DistrictRowDivider()
            }
        }
    }

    // ── Entry points ─────────────────────────────────────────────────────────

    /// ⛔ THE ROLE IS THE OVERVIEW'S, NOT THE SESSION'S. `workspace/list` reports the
    /// MEMBERSHIP role while this route reports the EFFECTIVE one, and the server can
    /// grant `agency` for support access with no membership row at all. Gating this
    /// column on ``WorkspaceSessionModel/role`` would hide the dialler from a support
    /// engineer the server would have admitted. See that property's own ⚠️.
    private func entryPoints(_ response: OverviewResponse) -> some View {
        let entries = OverviewEntry.all(
            workspaceId: response.workspaceId,
            role: WorkspaceRole.fromWire(response.role)
        )
        return VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            // ⚠️ LABELLED, THOUGH ANDROID'S COLUMN IS NOT: its entries are visibly
            // buttons, these are list rows directly under another block of list rows.
            DistrictEyebrow(text: "Workspace")
                .padding(.horizontal, DistrictSpacing.gutter)
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    entryRow(entry)
                    DistrictRowDivider()
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: OverviewEntry) -> some View {
        switch entry.target {
        case let .route(route):
            // ⚠️ Resolved by the ONE `navigationDestination(for: Route.self)` in
            // ``ShellView``, exactly as the activity rows above are.
            NavigationLink(value: route) { entryLabel(entry) }
                .buttonStyle(.plain)
        case let .tab(tab):
            Button(action: { onSelectTab(tab) }, label: { entryLabel(entry) })
                .buttonStyle(.plain)
        }
    }

    /// ⚠️ The chevron is drawn explicitly, as on ``AccountView``: a `VStack` of rows
    /// is not a `List`, so nothing supplies one for free.
    private func entryLabel(_ entry: OverviewEntry) -> some View {
        DistrictListRow(title: entry.title, subtitle: entry.caption, trailing: { chevron })
    }

    private var chevron: some View {
        // ⚠️ DECORATION, as on the Settings hub: the row is already a link.
        Image(systemName: "chevron.right")
            .font(DistrictType.label)
            .foregroundStyle(DistrictColors.resolve(colorScheme).mutedForeground)
            .accessibilityHidden(true)
    }

    // ── Loading ──────────────────────────────────────────────────────────────

    private func reload(refreshing: Bool = false) async {
        guard let workspaceId = workspaceSession.workspaceId else { return }
        let key = "\(session.epoch):\(workspaceId)"
        if !refreshing, loadedKey == key {
            return
        }
        loadedKey = key
        setup.workspaceChanged(to: workspaceId)
        await model.load(workspaceId: workspaceId, refreshing: refreshing)
        // ⛔ AFTER THE OVERVIEW, and only once it rendered: the card never delays the numbers.
        if case .content = model.state {
            await setup.refresh(workspaceId: workspaceId)
        }
    }

    /// ⚠️ CLEARS THE KEY FIRST. A retry after a failure asks for the same workspace
    /// and the same epoch, so without this the de-duplicator would swallow it.
    private func retry() {
        Task {
            loadedKey = nil
            await reload()
        }
    }
}

/// One KPI tile.
///
/// ⚠️ THE LABEL IS THE MONO EYEBROW, NOT A BOLD SMALL HEADING. Android's tiles used
/// `labelSmall` at Material's default weight, which read as a heading competing with
/// the number beneath it; the eyebrow demotes it to an annotation so the value is
/// unambiguously the subject.
private struct MetricTile: View {
    let label: String
    let value: String
    let caption: String

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            DistrictEyebrow(text: label)
            Text(value)
                .font(DistrictType.metric)
                .foregroundStyle(colors.foreground)
            Text(caption)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DistrictSpacing.card)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DistrictRadius.card)
                .strokeBorder(colors.border, lineWidth: 1)
        }
        // ⚠️ THE LABEL AND VALUE ARE ONE ANNOUNCEMENT. Read separately a screen
        // reader says "Total Calls Routed" then "412" with no stated relationship;
        // paired, the tile announces itself as a fact.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

/// One recent-activity row.
///
/// ⚠️ THE DISPLAY RULES ARE DERIVED HERE, ONCE, and they are Android's
/// `OverviewRepository.toActivity` rather than its `CallDisplay`. The two differ
/// deliberately: this one reads ``CallSummary/callerName`` and falls back to
/// ``CallSummary/from``, while the call screens read ``CallSummary/number``
/// through ``CallDisplay``; do not unify them by accident.
private struct ActivityRow: View {
    let call: CallSummary

    var body: some View {
        DistrictListRow(
            title: displayName ?? "No caller ID",
            subtitle: subtitle,
            // ⛔ LABELLED SLOTS, or this is `ambiguous use of 'init'` — see the ⛔
            // above the constrained initialisers in `DistrictListRow.swift`.
            leading: { avatar },
            trailing: { badges }
        )
    }

    /// ⚠️ A CALLER WITH NO ID GETS THE NEUTRAL TONE, so an anonymous row does not
    /// wear the brand accent as if it were a known contact.
    private var avatar: some View {
        DistrictAvatar(name: displayName ?? "", tone: displayName == nil ? .neutral : .district)
    }

    private var badges: some View {
        HStack(spacing: DistrictSpacing.hairline) {
            // ⛔ BOTH TRANSFER OUTCOMES, AND THE FAILURE IS DANGER-TONED. A transfer
            // that failed is the one thing on this screen a human has to act on, and
            // a neutral chip would make it look like a successful one.
            if isTransferred {
                DistrictBadge(text: "Transferred", tone: .info)
            }
            if isTransferFailed {
                DistrictBadge(text: "Transfer failed", tone: .danger)
            }
            DistrictBadge(text: statusLabel, tone: statusTone)
        }
    }

    // ── Derived ──────────────────────────────────────────────────────────────

    /// nil when there was no usable caller ID.
    ///
    /// ⛔ BOTH READS GO THROUGH ``CallerIdentity``, THE FALLBACK INCLUDED. A withheld
    /// caller's `callerName` is "Unknown" and its `from` is the sentence "Inbound SIP
    /// Caller", so guarding only BLANKNESS on the `from` fallback would print that
    /// sentence as a name, with the brand-accent avatar below. The full set and the
    /// server lines that write it live in ``CallerIdentity``.
    private var displayName: String? {
        CallerIdentity.resolved(call.callerName) ?? CallerIdentity.resolved(call.from)
    }

    /// ⛔ ``CallSummary/createdAt`` IN THE DEVICE ZONE, NOT ``CallSummary/time``.
    /// The server formats `time` with `user.timezone || "America/Toronto"`, and that
    /// column is settable only from the web settings page, which this client does not
    /// implement, so `time` is a Toronto wall clock, unlabelled, for every operator who
    /// has not opened the browser app. `createdAt` is the true instant and
    /// ``ContactDates/readable(_:)`` is the formatter the rest of this app uses.
    private var subtitle: String {
        let direction = call.direction == Self.outboundDirection ? "Outbound" : "Inbound"
        return "\(direction) · \(ContactDates.readable(call.createdAt))"
    }

    /// ⛔ DERIVED FROM THE DISPLAY STATUS, WHICH IS THE WHOLE POINT. The server has
    /// already downgraded an in-progress call whose terminal webhook was lost to
    /// `no-answer`, so only a genuinely live call still reads this way. Recomputing
    /// liveness from a raw status would resurrect the bug where a day-old stuck row
    /// renders a "Live" badge forever.
    private var isLive: Bool {
        call.status == Self.inProgressStatus || call.status == Self.ringingStatus
    }

    private var isTransferred: Bool {
        call.transferStatus == Self.transferSucceeded
    }

    private var isTransferFailed: Bool {
        call.transferStatus == Self.transferFailed
    }

    private var statusLabel: String {
        isLive ? "Live" : call.status
    }

    /// ⚠️ IN PROGRESS IS NOT A VERDICT, so a live call wears the accent rather than
    /// a semantic tone. Everything else goes through ``Tone/forCallStatus(_:)``,
    /// which fails to neutral for a status this client does not model.
    private var statusTone: Tone {
        isLive ? .district : Tone.forCallStatus(call.status)
    }

    // ⚠️ WIRE VALUES, NOT DISPLAY COPY. They are not localizable and they are the
    // strings Android keeps in exactly one place, because duplicating them is what
    // let the transfer-failed badge go missing from its call log.
    //
    // ⛔ THE CALLER SENTINELS ARE NOT AMONG THEM. A partial copy here is how
    // "Inbound SIP Caller" gets rendered as a contact; the whole set is
    // ``CallerIdentity``, in `DistrictModel`, where every reader sees the same list.
    private static let outboundDirection = "outbound"
    private static let inProgressStatus = "in-progress"
    private static let ringingStatus = "ringing"
    private static let transferSucceeded = "success"
    private static let transferFailed = "failed"
}
