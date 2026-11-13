@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// The overview's "Finish setting up" card: when it shows and what it says.
///
/// ⚠️ WHEN THE SERVER SAYS YES OR NO IS `OverviewSetupRepositoryTests` (owner, 403, null
/// progress, completed, offline, undecodable) and the fixture's `SetupContractTests`. This
/// file holds what only the app decides: the workspace-switch rule and the copy.
@MainActor
final class FinishSetupTests: XCTestCase {
    // MARK: - The model

    func testTheOwnerMidSetupIsOffered() async {
        let model = FinishSetupModel(fetch: { _ in true })

        await model.refresh(workspaceId: "ws_owner")

        XCTAssertTrue(model.isOffered)
        XCTAssertEqual(model.workspaceId, "ws_owner")
    }

    /// ⛔ ONE "NO" STANDS FOR ALL FIVE: the repository folds a 403, a pre-wizard workspace, a
    /// finished wizard, a network failure and a decode failure into `false`.
    func testANoIsNotOffered() async {
        let model = FinishSetupModel(fetch: { _ in false })

        await model.refresh(workspaceId: "ws_member")

        XCTAssertFalse(model.isOffered)
    }

    /// ⛔ A LATE ANSWER FOR A WORKSPACE NO LONGER IN VIEW IS DROPPED.
    func testALateAnswerForAnotherWorkspaceIsDropped() async {
        let box = ModelBox()
        let model = FinishSetupModel(fetch: { workspaceId in
            // The user switches tenant while the first read is in flight.
            if workspaceId == "ws_a" {
                await box.switchTo("ws_b")
            }
            return workspaceId == "ws_a"
        })
        box.model = model

        await model.refresh(workspaceId: "ws_a")

        XCTAssertEqual(model.workspaceId, "ws_b")
        XCTAssertFalse(model.isOffered, "ws_a's yes must not be drawn over ws_b")
    }

    func testASwitchClearsTheCardAtOnce() async {
        let model = FinishSetupModel(fetch: { _ in true })
        await model.refresh(workspaceId: "ws_a")
        XCTAssertTrue(model.isOffered)

        model.workspaceChanged(to: "ws_b")

        XCTAssertFalse(model.isOffered)
        XCTAssertEqual(model.workspaceId, "ws_b")
    }

    /// ⚠️ A REFRESH OF THE SAME WORKSPACE KEEPS THE CARD while the answer is in flight.
    func testARefreshOfTheSameWorkspaceKeepsTheCard() async {
        let model = FinishSetupModel(fetch: { _ in true })
        await model.refresh(workspaceId: "ws_a")

        model.workspaceChanged(to: "ws_a")

        XCTAssertTrue(model.isOffered)
    }

    // ⚠️ WHERE THE BUTTON GOES MOVED: it opens the wizard in the app, and the pages the wizard
    // still hands to the web are `SetupFlowTests`' hand-off tests.

    // MARK: - What it says

    func testTheCopyIsPinned() {
        XCTAssertEqual(FinishSetupCopy.title, "Finish setting up")
        XCTAssertEqual(FinishSetupCopy.body, "A few setup steps for this workspace are still open.")
        XCTAssertEqual(FinishSetupCopy.action, "Open setup")
    }
}

/// Lets a fetch closure reach the model it belongs to.
@MainActor
private final class ModelBox {
    var model: FinishSetupModel?

    func switchTo(_ workspaceId: String) {
        model?.workspaceChanged(to: workspaceId)
    }
}
