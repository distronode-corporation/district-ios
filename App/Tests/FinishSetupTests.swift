@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// The overview's "Finish setting up" card: when it shows, where it goes, what it says.
///
/// ⚠️ WHEN THE SERVER SAYS YES OR NO IS `OverviewSetupRepositoryTests` (owner, 403, null
/// progress, completed, offline, undecodable) and the fixture's `SetupContractTests`. This
/// file holds what only the app decides: the workspace-switch rule and the hand-off URL.
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

    // MARK: - Where the button goes

    func testTheButtonOpensTheConsoleHomeOnTheBuildsOwnHost() throws {
        let production = try XCTUnwrap(URL(string: "https://www.distronode.com"))
        XCTAssertEqual(
            FinishSetupCard.destination(baseURL: production)?.absoluteString,
            "https://www.distronode.com/dashboard/district"
        )

        let staging = try XCTUnwrap(URL(string: "https://staging.example.com/api?x=1#y"))
        XCTAssertEqual(
            FinishSetupCard.destination(baseURL: staging)?.absoluteString,
            "https://staging.example.com/dashboard/district",
            "a staging build hands off to staging, and nothing of the base's path survives"
        )
    }

    /// ⛔ `SFSafariViewController` TRAPS ON A NON-HTTP SCHEME, so no URL is better than one.
    func testANonHTTPSBaseOffersNoButton() throws {
        let local = try XCTUnwrap(URL(string: "http://localhost:3000"))
        XCTAssertNil(FinishSetupCard.destination(baseURL: local))
    }

    /// ⛔ WHY THE CARD USES A SAFARI SHEET: the destination is a URL this app CLAIMS, so
    /// handing it to the system would route it straight back here.
    func testTheDestinationIsAClaimedURLWhichIsWhyItIsNeverHandedToTheSystem() throws {
        let production = try XCTUnwrap(URL(string: "https://www.distronode.com"))
        let url = try XCTUnwrap(FinishSetupCard.destination(baseURL: production))

        XCTAssertNotNil(AppLinkResolver.resolve(url), "if this ever stops being claimed, revisit the sheet")
    }

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
