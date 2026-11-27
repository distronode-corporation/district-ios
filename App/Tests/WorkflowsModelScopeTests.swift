@testable import DistrictAI
import DistrictModel
import XCTest

/// The Workflows model's switch, run history and campaign control, against the service's
/// recorded answers and its refusals.
///
/// ⚠️ A ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN CONTAINER: nothing here draws.
final class WorkflowsModelScopeTests: ScreenSnapshotTestCase {
    private static let campaign = "/api/district/workspace/campaign-status"
    private static let workflows = "/api/district/workflows"
    private static let runs = "/api/district/workflows/runs"

    private func workflowsModel(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (WorkflowsModel, FixtureTransport) {
        var all: [String: FixtureTransport.Reply] = [Self.runs: .fixture("district-workflow-runs")]
        all.merge(replies) { $1 }
        let transport = FixtureTransport(all)
        let model = try await WorkflowsModel(
            container: container(transport),
            workspaceId: "ws-contract-test",
            role: role
        )
        await model.loadCampaign()
        await model.loadWorkflows()
        return (model, transport)
    }

    private func workflow(_ model: WorkflowsModel, _ id: String) throws -> WorkflowListItem {
        var items: [WorkflowListItem] = []
        if case let .ready(rows) = model.list {
            items = rows
        }
        return try XCTUnwrap(items.first(where: { $0.id == id }), "no workflow \(id) in the recorded list")
    }

    // MARK: - The switch

    func testAnAcceptedSwitchHoldsUntilTheNextRead() async throws {
        let (model, _) = try await workflowsModel(["PATCH \(Self.workflows)": .fixture("district-workflow-toggle")])
        let paused = try workflow(model, "wf_contract_paused")
        await model.setActive(workflowId: paused.id, active: true)

        XCTAssertTrue(model.isActive(paused))
        XCTAssertFalse(model.isToggling(paused))
        XCTAssertNil(model.toggleFailure)

        await model.loadWorkflows()
        XCTAssertFalse(model.isActive(paused), "the fresh list is the truth")
    }

    /// ⛔ A REFUSED SWITCH GOES BACK TO WHAT THE SERVER LAST SAID, and says why.
    func testARefusedSwitchSnapsBackAndSaysWhy() async throws {
        let (model, _) = try await workflowsModel(["PATCH \(Self.workflows)": .refused(500)])
        let active = try workflow(model, "wf_contract_active")
        await model.setActive(workflowId: active.id, active: false)

        XCTAssertTrue(model.isActive(active))
        XCTAssertNotNil(model.toggleFailure)
        model.dismissToggleFailure()
        XCTAssertNil(model.toggleFailure)
    }

    func testAViewerAndAnUnreadListSendNoSwitch() async throws {
        let (viewer, viewerTransport) = try await workflowsModel(role: .viewer)
        await viewer.setActive(workflowId: "wf_contract_active", active: false)
        XCTAssertFalse(viewer.canToggle)

        let (unread, unreadTransport) = try await workflowsModel([Self.workflows: .refused(500)])
        await unread.setActive(workflowId: "wf_contract_active", active: false)

        for transport in [viewerTransport, unreadTransport] {
            XCTAssertFalse(transport.requested.contains("PATCH \(Self.workflows)"))
        }
    }

    // MARK: - Run history

    func testOpeningReadsThePageOnceAndClosingKeepsIt() async throws {
        let (model, transport) = try await workflowsModel()
        await model.toggleExpanded("wf_contract_active")
        XCTAssertEqual(model.expanded, "wf_contract_active")
        XCTAssertEqual(model.runs["wf_contract_active"]?.runs.count, 4)
        XCTAssertEqual(model.runs["wf_contract_active"]?.total, 9)
        XCTAssertEqual(model.runs["wf_contract_active"]?.hasMore, true)

        await model.toggleExpanded("wf_contract_active")
        XCTAssertNil(model.expanded)
        await model.toggleExpanded("wf_contract_active")
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.runs)" }.count, 1, "a loaded history is kept")
    }

    /// ⛔ LOAD MORE APPENDS: a second page never replaces the first.
    func testLoadMoreAppends() async throws {
        let (model, _) = try await workflowsModel()
        await model.loadMoreRuns("wf_contract_active")
        XCTAssertNil(model.runs["wf_contract_active"], "nothing to extend before the first page")

        await model.toggleExpanded("wf_contract_active")
        await model.loadMoreRuns("wf_contract_active")
        XCTAssertEqual(model.runs["wf_contract_active"]?.runs.count, 8)
    }

    func testAFailedFirstPageIsNotLoadedAndRetries() async throws {
        let (model, transport) = try await workflowsModel([Self.runs: .refused(500)])
        await model.toggleExpanded("wf_contract_active")

        let history = try XCTUnwrap(model.runs["wf_contract_active"])
        XCTAssertNotNil(history.failure)
        XCTAssertFalse(history.loaded)
        XCTAssertTrue(history.needsFirstPage)

        await model.retryRuns("wf_contract_active")
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.runs)" }.count, 2)
        await model.retryRuns("wf_never_opened")
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.runs)" }.count, 2)
    }

    // MARK: - The campaign

    func testAskingForTheStateItIsAlreadyInAsksNothing() async throws {
        let (model, _) = try await workflowsModel()
        model.requestCampaignChange(enable: true)
        XCTAssertNil(model.campaignConfirm, "the recorded campaign is already running")

        model.requestCampaignChange(enable: false)
        XCTAssertEqual(model.campaignConfirm?.enable, false)
        model.dismissCampaignConfirm()
        XCTAssertNil(model.campaignConfirm)

        await model.confirmCampaignChange()
        XCTAssertFalse(model.campaignPending, "nothing confirmed, nothing sent")
    }

    func testAConfirmedPauseAdoptsTheServersCampaign() async throws {
        let (model, _) = try await workflowsModel(["PATCH \(Self.campaign)": .fixture("district-campaign-pause")])
        model.requestCampaignChange(enable: false)
        await model.confirmCampaignChange()

        guard case let .ready(status) = model.campaign else {
            return XCTFail("expected a campaign, got \(model.campaign)")
        }
        XCTAssertFalse(status.infiniteSdrEnabled)
        XCTAssertNil(model.campaignFailure)
    }

    /// ⛔ A REFUSED CHANGE KEEPS THE LAST STATE THE SERVER SENT.
    func testARefusedPauseKeepsTheCampaignRunning() async throws {
        let (model, _) = try await workflowsModel(["PATCH \(Self.campaign)": .refused(500)])
        model.requestCampaignChange(enable: false)
        await model.confirmCampaignChange()

        guard case let .ready(status) = model.campaign else {
            return XCTFail("expected a campaign, got \(model.campaign)")
        }
        XCTAssertTrue(status.infiniteSdrEnabled)
        XCTAssertNotNil(model.campaignFailure)
    }

    func testResetForgetsEverything() async throws {
        let (model, _) = try await workflowsModel(["PATCH \(Self.workflows)": .refused(500)])
        await model.toggleExpanded("wf_contract_active")
        await model.setActive(workflowId: "wf_contract_active", active: false)
        model.reset()

        XCTAssertNil(model.expanded)
        XCTAssertTrue(model.runs.isEmpty)
        XCTAssertNil(model.toggleFailure)
        guard case .loading = model.list, case .loading = model.campaign else {
            return XCTFail("reset returns both reads to loading")
        }
    }
}
