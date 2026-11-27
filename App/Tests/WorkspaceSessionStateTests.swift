@testable import DistrictAI
import Foundation
import XCTest

/// Which workspace the app opens on and what it says when there is none, from each shape the
/// service's workspace list answers in: the stored choice, the service's default, a stale choice
/// on a complete and on a partial list, no workspace, every workspace lapsed, the 503 for
/// unreachable regions, and a plain failure.
///
/// ⚠️ A ``ScreenSnapshotTestCase`` FOR ITS SIGNED-IN CONTAINER ONLY: nothing here is drawn.
final class WorkspaceSessionStateTests: ScreenSnapshotTestCase {
    private static let listPath = "/api/district/workspace/list"
    private let store = WorkspaceSelectionStore()

    override func tearDown() async throws {
        store.setSelectedWorkspaceId(nil)
        try await super.tearDown()
    }

    private func loaded(_ replies: [String: FixtureTransport.Reply] = [:]) async throws -> WorkspaceSessionModel {
        let transport = FixtureTransport(replies)
        let model = try await WorkspaceSessionModel(container: container(transport))
        await model.load()
        XCTAssertEqual(transport.unanswered, [])
        return model
    }

    /// With nothing stored, the service's `defaultWorkspaceId` (the viewer's workspace in the fixture).
    func testNothingStoredOpensTheServicesDefault() async throws {
        store.setSelectedWorkspaceId(nil)
        let model = try await loaded()
        XCTAssertEqual(model.selectedEntry?.id, "ws-contract-viewer")
        XCTAssertEqual(model.workspaceId, "ws-contract-viewer")
        guard case .content = model.state else {
            return XCTFail("expected content, got \(model.state)")
        }
    }

    func testAStoredChoiceThatResolvesIsKept() async throws {
        store.setSelectedWorkspaceId("ws-contract-client")
        let model = try await loaded()
        XCTAssertEqual(model.selectedEntry?.id, "ws-contract-client")
        XCTAssertEqual(store.selectedWorkspaceId(), "ws-contract-client")
    }

    /// ⚠️ A CHOICE THE COMPLETE LIST NO LONGER HOLDS IS FORGOTTEN, and the default opens instead.
    func testAStaleChoiceIsForgottenOnACompleteList() async throws {
        store.setSelectedWorkspaceId("ws-gone")
        let model = try await loaded()
        XCTAssertEqual(model.selectedEntry?.id, "ws-contract-viewer")
        XCTAssertNil(store.selectedWorkspaceId(), "the dead id is not re-read on every launch")
    }

    /// ⛔ BUT KEPT ON A PARTIAL ONE: the workspace may be in the region that did not answer.
    func testAChoiceMissingFromAPartialListIsKept() async throws {
        store.setSelectedWorkspaceId("ws-contract-viewer")
        let model = try await loaded([Self.listPath: .fixture("district-workspace-list-partial")])
        XCTAssertEqual(store.selectedWorkspaceId(), "ws-contract-viewer", "eu did not answer; the choice stands")
        XCTAssertEqual(model.selectedEntry?.id, "ws-contract-active", "the first listed opens meanwhile")
        guard case let .partial(_, _, regions) = model.state else {
            return XCTFail("expected partial, got \(model.state)")
        }
        XCTAssertEqual(regions, ["eu"])
    }

    func testNoWorkspaceIsEmpty() async throws {
        let model = try await loaded([Self.listPath: ShellSnapshotTests.emptyList(inactive: 0)])
        guard case .empty = model.state else {
            return XCTFail("expected empty, got \(model.state)")
        }
        XCTAssertNil(model.selectedEntry)
        XCTAssertNil(model.workspaceId)
    }

    /// Every workspace lapsed is the plan's sentence, with how many, not "no workspaces".
    func testEveryWorkspaceLapsedIsLapsed() async throws {
        let model = try await loaded([Self.listPath: ShellSnapshotTests.emptyList(inactive: 2)])
        guard case let .lapsed(inactiveCount) = model.state else {
            return XCTFail("expected lapsed, got \(model.state)")
        }
        XCTAssertEqual(inactiveCount, 2)
    }

    /// The service's 503 for unreachable regions is degraded, never empty or a generic failure.
    func testUnreachableRegionsAreDegraded() async throws {
        let model = try await loaded([Self.listPath: ShellSnapshotTests.degraded])
        guard case let .degraded(message) = model.state else {
            return XCTFail("expected degraded, got \(model.state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(model.selectedEntry)
    }

    func testAnyOtherRefusalIsAFailure() async throws {
        let model = try await loaded([Self.listPath: .json(#"{"error":"Something went wrong."}"#, status: 500)])
        guard case .failed = model.state else {
            return XCTFail("expected failed, got \(model.state)")
        }
    }

    /// Choosing a workspace stores it and reads the list again.
    func testSelectingStoresTheChoice() async throws {
        store.setSelectedWorkspaceId(nil)
        let transport = FixtureTransport()
        let model = try await WorkspaceSessionModel(container: container(transport))
        await model.load()
        await model.select("ws-contract-active")
        XCTAssertEqual(store.selectedWorkspaceId(), "ws-contract-active")
        XCTAssertEqual(model.selectedEntry?.id, "ws-contract-active")
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.listPath)" }.count, 2)
    }
}
