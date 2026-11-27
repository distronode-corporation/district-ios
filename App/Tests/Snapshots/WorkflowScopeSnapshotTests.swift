@testable import DistrictAI
import SwiftUI
import XCTest

/// The Workflows screen in the states its two reads leave it in, and its cards (the
/// campaign, a workflow row, a run history) once the operator has acted on them.
final class WorkflowScopeSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let campaign = "/api/district/workspace/campaign-status"
    private static let workflows = "/api/district/workflows"
    private static let runs = "/api/district/workflows/runs"

    // MARK: - The screen

    /// Both reads refused: each section's own failure card with its retry.
    func testWorkflowsFailed() async throws {
        try await assertScreen([Self.campaign: .refused(500), Self.workflows: .refused(500)]) { container in
            WorkflowsView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// No workflows, and a campaign never configured: the empty sentence, and the card's
    /// unset batch and goal lines.
    func testWorkflowsEmpty() async throws {
        try await assertScreen([
            Self.campaign: .fixture("district-campaign-status-empty"),
            Self.workflows: .json(#"{"success":true,"workflows":[]}"#),
        ]) { container in
            WorkflowsView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// A viewer: switches disabled, no Pause, and the viewer's read-only line.
    func testWorkflowsForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            WorkflowsView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    // MARK: - The cards, driven

    /// A workflow opened onto its recorded runs (success, partial with a skip reason,
    /// failed with no finish, skipped), with Load more because the service has more.
    func testRunHistoryLoaded() async throws {
        try await assertScreen([Self.runs: .fixture("district-workflow-runs")]) { container in
            WorkflowCardsHost(model: Self.model(container)) { model in
                await model.toggleExpanded("wf_contract_active")
            }
        }
    }

    /// A workflow that has never run: the empty sentence in its panel.
    func testRunHistoryEmpty() async throws {
        let none = #"{"success":true,"runs":[],"total":0,"limit":10,"offset":0,"hasMore":false}"#
        try await assertScreen([Self.runs: .json(none)], devices: [.iPhone]) { container in
            WorkflowCardsHost(model: Self.model(container)) { model in
                await model.toggleExpanded("wf_contract_paused")
            }
        }
    }

    /// The first page refused: the failure line with its retry, and no rows.
    func testRunHistoryFailed() async throws {
        try await assertScreen([Self.runs: .refused(500)], devices: [.iPhone]) { container in
            WorkflowCardsHost(model: Self.model(container)) { model in
                await model.toggleExpanded("wf_contract_active")
            }
        }
    }

    /// Pausing the campaign, refused by the service: the card keeps the last state it was
    /// sent (Active) and says why under the control.
    func testCampaignChangeRefused() async throws {
        try await assertScreen(["PATCH \(Self.campaign)": .refused(500)]) { container in
            WorkflowCardsHost(model: Self.model(container)) { model in
                model.requestCampaignChange(enable: false)
                await model.confirmCampaignChange()
            }
        }
    }

    /// Pausing the campaign, accepted: the card redrawn from the service's answer (Paused,
    /// with Resume offered).
    func testCampaignPaused() async throws {
        try await assertScreen(
            ["PATCH \(Self.campaign)": .fixture("district-campaign-pause")],
            devices: [.iPhone]
        ) { container in
            WorkflowCardsHost(model: Self.model(container)) { model in
                model.requestCampaignChange(enable: false)
                await model.confirmCampaignChange()
            }
        }
    }

    private static func model(_ container: AppContainer) -> WorkflowsModel {
        WorkflowsModel(container: container, workspaceId: workspace, role: .client)
    }
}

/// The Workflows cards over one model, after `drive` has acted on it: the campaign card,
/// then each workflow row with its run history when open, the order the screen draws them.
private struct WorkflowCardsHost: View {
    let model: WorkflowsModel
    let drive: @MainActor (WorkflowsModel) async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                if case let .ready(status) = model.campaign {
                    SdrCampaignCard(model: model, status: status)
                }
                if case let .ready(workflows) = model.list {
                    ForEach(workflows, id: \.id) { workflow in
                        WorkflowRowView(model: model, workflow: workflow)
                        if model.expanded == workflow.id {
                            RunHistoryPanel(model: model, workflowId: workflow.id)
                        }
                    }
                }
            }
            .padding(DistrictSpacing.gutter)
        }
        .task {
            await model.loadCampaign()
            await model.loadWorkflows()
            await drive(model)
        }
    }
}
