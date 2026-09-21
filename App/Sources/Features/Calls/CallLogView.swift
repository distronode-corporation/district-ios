import DistrictModel
import SwiftUI

/// The Calls tab root.
///
/// ⛔ `.id(workspaceId)` IS LOAD-BEARING AND IS THE WHOLE REASON THIS WRAPPER EXISTS.
/// ``CallLogModel`` owns one ``OffsetPager`` built for one tenant, and the pager's
/// offsets and dedup set are meaningless across a switch. Seeding `@State` in an
/// initialiser only takes effect for a NEW view identity, so without this the model
/// would survive a workspace change and mix two workspaces' rows. Changing the id
/// discards the identity and runs the initialiser again.
///
/// ⛔ NO `NavigationStack` HERE. ``ShellView`` provides one per tab and registers
/// `navigationDestination(for: Route.self)` on it exactly once; SwiftUI resolves that
/// by TYPE, so a second registration inside a tab root is a runtime coin toss.
struct CallLogView: View {
    let container: AppContainer
    let workspaceId: String

    /// The open row, on regular width only; nil on the phone. See ``RouteList``.
    var selection: Binding<Route?>?

    var body: some View {
        CallLogScreen(container: container, workspaceId: workspaceId, selection: selection)
            .id(workspaceId)
    }
}

/// The call log for one workspace.
private struct CallLogScreen: View {
    let workspaceId: String
    let selection: Binding<Route?>?

    @State private var model: CallLogModel

    init(container: AppContainer, workspaceId: String, selection: Binding<Route?>?) {
        self.workspaceId = workspaceId
        self.selection = selection
        _model = State(initialValue: CallLogModel(container: container, workspaceId: workspaceId))
    }

    var body: some View {
        content
            .navigationTitle("Call log")
            .task {
                // ⚠️ Once per appearance of this view identity, not per redraw.
                await model.loadFirst()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            skeleton
        case let .content(rows, isEnd, appending, appendFailure):
            list(rows: rows, isEnd: isEnd, appending: appending, appendFailure: appendFailure)
        case .empty:
            // ⚠️ Reachable only after a SUCCESSFUL first page, which is what makes an
            // empty state honest here rather than a failure wearing the wrong copy.
            EmptyStateView(
                systemImage: "phone",
                title: "Nothing here yet",
                message: "Inbound and outbound calls will appear here as they happen."
            )
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        }
    }

    // MARK: - States

    /// ⚠️ SKELETON ROWS, NOT A CENTRED SPINNER. The list that is arriving has a known
    /// shape, so drawing that shape says what is loading and stops the layout jumping
    /// when it lands. A spinner on a blank screen conveys only "wait".
    private var skeleton: some View {
        VStack(spacing: DistrictSpacing.row) {
            ForEach(0 ..< 6, id: \.self) { _ in
                SkeletonBlock(height: 56)
            }
            Spacer(minLength: 0)
        }
        .padding(DistrictSpacing.gutter)
    }

    private func list(
        rows: [CallSummary],
        isEnd: Bool,
        appending: Bool,
        appendFailure: FailureText?
    ) -> some View {
        RouteList(selection: selection) {
            ForEach(rows, id: \.id) { call in
                // ⛔ THE ROW IS KEYED ON THE CALL ID, AND THE PAGER DEDUPLICATES
                // BECAUSE OF IT. Offset paging over a live `createdAt desc` feed
                // serves the boundary row twice when a call arrives mid-scroll, and a
                // duplicate id in a `ForEach` is a rendering fault rather than a
                // cosmetic repeat.
                NavigationLink(value: Route.callDetail(workspaceId: workspaceId, callId: call.id)) {
                    CallRow(call: call)
                }
                .accessibilityIdentifier(A11yID.Calls.row(call.id))
                .rowContextMenu(RowContextActions.call(direction: call.direction, from: call.from))
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .onAppear { reachedEnd(of: rows, at: call) }
            }
            footer(isEnd: isEnd, appending: appending, appendFailure: appendFailure)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .districtRefreshable { await model.refresh() }
    }

    /// ⛔ THE FOOTER REPORTS ONLY THE APPEND, so a failed extra page never destroys
    /// the rows already on screen. Nothing is drawn once the feed has ended.
    @ViewBuilder
    private func footer(isEnd: Bool, appending: Bool, appendFailure: FailureText?) -> some View {
        if appending {
            // ⚠️ A spinner is correct HERE, unlike the cold-start case: the footer is
            // a strip below rows the user is already reading, so there is no shape to
            // stand in for and nothing to stop jumping.
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(DistrictSpacing.gutter)
        } else if let appendFailure {
            appendFooter(appendFailure)
        }
    }

    private func appendFooter(_ failure: FailureText) -> some View {
        VStack(spacing: DistrictSpacing.tight) {
            Text("Could not load more")
                .font(DistrictType.bodySmall)
            Text(failure.message)
                .font(DistrictType.caption)
                .multilineTextAlignment(.center)
            // ⚠️ Offered unconditionally here, unlike ``FailureView``, because the
            // only thing this footer can do is ask for the same window again. A
            // failure that cannot be retried still gets its sentence above.
            Button("Try again") { loadMore() }
                .buttonStyle(.districtSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(DistrictSpacing.gutter)
    }

    // MARK: - Actions

    /// ⚠️ `.onAppear` ON THE LAST ROW IS THE PAGINATION TRIGGER. ``CallLogModel``
    /// guards it, so firing repeatedly while a window is in flight costs nothing.
    private func reachedEnd(of rows: [CallSummary], at call: CallSummary) {
        guard call.id == rows.last?.id else { return }
        loadMore()
    }

    private func loadMore() {
        Task { await model.loadMore() }
    }

    private func reload() {
        Task { await model.loadFirst() }
    }
}
