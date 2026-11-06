import DistrictModel
import SwiftUI

/// The Live calls hub: the workspace's calls in progress, each opening its supervision.
///
/// ⛔ `.id(workspaceId)` FOR THE CALL LOG'S REASON: the model reads one tenant's calls and
/// holds one tenant's socket, and a workspace switch must build a new one.
///
/// ⛔ NO `NavigationStack` HERE: the shell gives every hub section its own (see
/// ``CallLogView``), and a row is a `NavigationLink(value:)` into it.
struct LiveCallsView: View {
    let container: AppContainer
    let workspaceId: String
    let role: WorkspaceRole?

    var body: some View {
        LiveCallsScreen(container: container, workspaceId: workspaceId, role: role)
            .id(workspaceId)
    }
}

private struct LiveCallsScreen: View {
    let workspaceId: String
    let role: WorkspaceRole?

    @State private var model: LiveCallsModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        self.role = role
        _model = State(initialValue: LiveCallsModel(container: container, workspaceId: workspaceId))
    }

    var body: some View {
        content
            .navigationTitle(SuperviseCopy.pageTitle)
            .task { await model.load() }
            // ⛔ THE SOCKET RUNS WHILE THIS SCREEN IS SHOWN AND THE APP IS IN FRONT, as the call
            // screen's transcript does; `.inactive` keeps it, since the screen is still in view.
            .onAppear {
                if scenePhase == .active {
                    model.events.activate()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: model.events.activate()
                case .background: model.events.deactivate()
                default: break
                }
            }
            .onDisappear { model.events.deactivate() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(A11yID.Live.root)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VStack(spacing: DistrictSpacing.row) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    SkeletonBlock(height: 56)
                }
                Spacer(minLength: 0)
            }
            .padding(DistrictSpacing.gutter)
        case let .ready(rows):
            list(rows)
        case let .failed(failure):
            FailureView(failure: failure, onRetry: { Task { await model.load() } })
        }
    }

    private func list(_ rows: [CallSummary]) -> some View {
        List {
            Section {
                if model.events.reconnecting {
                    Label(SuperviseCopy.feedReconnecting, systemImage: "wifi.exclamationmark")
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.mutedForeground)
                }
                if rows.isEmpty {
                    // ⚠️ REACHABLE ONLY AFTER A SUCCESSFUL READ, which is what makes it honest.
                    EmptyStateView(
                        systemImage: "phone.connection",
                        title: SuperviseCopy.emptyHeading,
                        message: SuperviseCopy.emptyBody
                    )
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier(A11yID.Live.empty)
                }
                ForEach(rows, id: \.id) { call in
                    NavigationLink(value: Route.superviseCall(workspaceId: workspaceId, role: role, callId: call.id)) {
                        CallRow(call: call)
                    }
                    .accessibilityIdentifier(A11yID.Live.row(call.id))
                }
            } header: {
                Text(SuperviseCopy.pageSubtitle)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
                    .textCase(nil)
                    .padding(.bottom, DistrictSpacing.hairline)
            }
        }
        .listStyle(.plain)
        .districtRefreshable { await model.load() }
    }
}
