import DistrictNetwork
import SwiftUI

/// Telephony analytics over a selectable window, this month's metered usage, and the
/// recent-months trend.
///
/// ⛔ THE THREE CARD AREAS FAIL INDEPENDENTLY. Analytics, usage and usage history are
/// separate server reads, so a failure of one is rendered inside its own card with
/// the others' figures still on screen. The whole-screen failure is reached only when
/// EVERY read failed and there is genuinely nothing left to preserve. See
/// ``AnalyticsState``.
///
/// ⚠️ THIS FILE OWNS THE SHELL ONLY — the scroll view, the window selector and the
/// three top-level states. The cards live in `AnalyticsCards.swift` and
/// `AnalyticsUsageCards.swift`, their chrome in `AnalyticsChrome.swift` and their
/// arithmetic in `AnalyticsFormat.swift`, which is the same seam the Android screen
/// was split along.
///
/// ⚠️ ONE `task`, NOT TWO. The Overview watches both the workspace id and the session
/// epoch because it is a TAB that survives a sign-out and a tenant switch; this is a
/// pushed destination whose workspace id is carried in the ``Route`` itself, and a
/// session that ends underneath it takes the whole stack with it.
struct AnalyticsView: View {
    @State private var model: AnalyticsModel

    init(container: AppContainer, workspaceId: String) {
        // ⚠️ `State(initialValue:)` in `init`, as every other model-owning screen
        // does: SwiftUI keeps the value for the lifetime of this view's identity, so
        // the model is not rebuilt on every re-render.
        _model = State(initialValue: AnalyticsModel(container: container, workspaceId: workspaceId))
    }

    var body: some View {
        ScrollView {
            content
                .padding(.bottom, DistrictSpacing.header)
        }
        // ⚠️ ON THE SCROLL VIEW RATHER THAN INSIDE A CONTENT BRANCH, so a failed read
        // can be pulled to retry rather than only through its button.
        .districtRefreshable { await model.load(refreshing: true) }
        .task { await model.load() }
        .navigationTitle("Analytics")
        .navigationBarTitleDisplayMode(.inline)
    }

    // ── States ───────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            LoadingView(message: "Loading analytics…")
        case let .failed(failure):
            // ⛔ REACHED ONLY WHEN ALL THREE READS FAILED. Anything partial keeps its
            // figures and confines the failure to a card.
            FailureView(failure: failure, onRetry: retry)
        case let .content(loaded):
            // ⚠️ THE ARGUMENT AND THE BUILDER ARE DELIBERATELY NOT THE SAME WORD.
            // `self.loaded(loaded)` would read fine and `--self remove` in
            // `.swiftformat` would then strip the `self.`, leaving a call that no
            // longer resolves to the method.
            stack(loaded)
        }
    }

    private func stack(_ content: AnalyticsContent) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.section) {
            rangePicker(content.range)
            refreshingIndicator(content.refreshing)
            analyticsSections(content.analytics)
            usageSection(content.usage)
            historySection(content.history)
        }
        .padding(.horizontal, DistrictSpacing.gutter)
        .padding(.top, DistrictSpacing.gutter)
        .districtReadableWidth()
    }

    // ── The window selector ──────────────────────────────────────────────────

    /// ⚠️ A SEGMENTED `Picker` RATHER THAN THREE BUTTONS. Android uses a row of
    /// primary/secondary buttons only because its design system has no chip; iOS has
    /// the platform control for exactly this, and it brings the selected-segment
    /// semantics and the accessibility traits with it.
    private func rangePicker(_ range: AnalyticsRange) -> some View {
        Picker("Window", selection: selection(range)) {
            ForEach(AnalyticsRange.allCases, id: \.self) { option in
                Text(Self.label(for: option)).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    /// ⚠️ THE BINDING READS THE MODEL AND WRITES THROUGH ``AnalyticsModel/select(_:)``,
    /// which is what makes a tap on the already-selected segment a no-op rather than
    /// a second full-window aggregate. The `range` argument is the value the state
    /// carries, so the segment moves with the state rather than lagging one render
    /// behind it.
    private func selection(_ range: AnalyticsRange) -> Binding<AnalyticsRange> {
        Binding(
            get: { range },
            set: { next in Task { await model.select(next) } }
        )
    }

    /// ⚠️ THE LABELS ARE THE ANDROID CLIENT'S, WORD FOR WORD, and they are display
    /// copy rather than wire values — ``AnalyticsRange/wire`` is the only thing that
    /// may reach the server, because an unrecognised `timeRange` is silently served
    /// as 7d with a 200.
    private static func label(for range: AnalyticsRange) -> String {
        switch range {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        }
    }

    /// ⚠️ A SECOND INDICATOR DURING A PULL-TO-REFRESH IS THE ACCEPTED COST HERE, and
    /// the Overview deliberately takes the opposite trade. There, `refreshing` only
    /// ever means a pull, which SwiftUI is already drawing; here it also means a
    /// WINDOW SWITCH, which has no gesture and no system indicator — so without this
    /// a tap on "90 days" would look dead for the length of an aggregate over every
    /// call in the window.
    @ViewBuilder
    private func refreshingIndicator(_ refreshing: Bool) -> some View {
        if refreshing {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    // ── Sections ─────────────────────────────────────────────────────────────

    @ViewBuilder
    private func analyticsSections(_ state: AnalyticsCardState) -> some View {
        switch state {
        case let .ready(report):
            AnalyticsMetricTiles(metrics: report.metrics)
            AnalyticsDeltaCard(delta: report.callVolumeDelta)
            AnalyticsTrendCard(points: report.engagementTrends)
            AnalyticsFunnelCard(stages: report.funnelData)
            AnalyticsSentimentCard(slices: report.sentimentDistribution)
        case let .failed(failure):
            AnalyticsCardFailure(title: "Could not load analytics.", failure: failure, onRetry: retry)
        }
    }

    @ViewBuilder
    private func usageSection(_ state: UsageCardState) -> some View {
        switch state {
        case let .ready(usage):
            AnalyticsUsageCard(usage: usage)
        case let .failed(failure):
            // ⛔ FAIL-SOFT, INSIDE ITS OWN CARD. The analytics figures beside it came
            // from a different read and are still correct.
            AnalyticsCardFailure(title: "Could not load usage.", failure: failure, onRetry: retry)
        }
    }

    @ViewBuilder
    private func historySection(_ state: UsageHistoryCardState) -> some View {
        switch state {
        case let .ready(months):
            AnalyticsHistoryCard(months: months)
        case let .failed(failure):
            // ⛔ BESIDE THE CURRENT MONTH, NOT INSTEAD OF IT. The two are separate
            // requests against the same route (`history=true` is the only
            // difference), so a failed history must not take this month's figures off
            // the screen.
            AnalyticsCardFailure(title: "Could not load usage history.", failure: failure, onRetry: retry)
        }
    }

    // ── Loading ──────────────────────────────────────────────────────────────

    /// ⚠️ A COLD LOAD RATHER THAN A REFRESH. A retry is reached from a state with
    /// nothing worth preserving, and asking to keep content that is not there would
    /// leave the spinner off while the request ran.
    private func retry() {
        Task { await model.load() }
    }
}
