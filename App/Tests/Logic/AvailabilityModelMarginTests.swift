@testable import DistrictAI
import DistrictModel
import XCTest

/// ``AvailabilityModel`` over a real container: the workspace it resolves, the read, the two
/// reasons that withdraw the switch, a save that adopts the server's echo, a refused save that
/// keeps the confirmed value, and the row that disappears when no workspace resolves.
final class AvailabilityModelMarginTests: ScreenSnapshotTestCase {
    private static let path = "/api/district/workspace/availability"
    private static let listPath = "/api/district/workspace/list"
    private static let available = #"{"success":true,"availableForCalls":true,"reason":null}"#
    private static let unavailable = #"{"success":true,"availableForCalls":false,"reason":null}"#
    private static let refused = #"{"error":"Internal error"}"#
    private let store = WorkspaceSelectionStore()

    override func setUp() async throws {
        try await super.setUp()
        store.setSelectedWorkspaceId("ws-contract-client")
    }

    override func tearDown() async throws {
        store.setSelectedWorkspaceId(nil)
        try await super.tearDown()
    }

    private func model(
        _ replies: [String: FixtureTransport.Reply],
        sequences: [String: [FixtureTransport.Reply]] = [:]
    ) async throws -> (AvailabilityModel, FixtureTransport) {
        let transport = FixtureTransport(replies, sequences: sequences)
        return try await (AvailabilityModel(container: container(transport)), transport)
    }

    private func status(_ model: AvailabilityModel) -> AvailabilityStatus? {
        guard case let .ready(status) = model.state else { return nil }
        return status
    }

    func testTheReadNamesTheResolvedWorkspace() async throws {
        let (model, transport) = try await model([Self.path: .json(Self.available)])
        await model.load()
        let status = try XCTUnwrap(status(model))
        XCTAssertEqual(status.workspaceId, "ws-contract-client")
        XCTAssertEqual(status.workspaceName, "Bravo Client")
        XCTAssertTrue(status.available)
        XCTAssertTrue(status.canToggle)
        XCTAssertEqual(transport.unanswered, [])
    }

    /// ⛔ A 200 carrying a reason is a row with no live switch, and a write is refused locally.
    func testAReasonWithdrawsTheSwitchAndBlocksTheWrite() async throws {
        for reason in [AvailabilityReason.role, AvailabilityReason.noMemberRow] {
            let body = #"{"success":true,"availableForCalls":false,"reason":"\#(reason)"}"#
            let (model, transport) = try await model([Self.path: .json(body)])
            await model.load()
            let status = try XCTUnwrap(status(model), reason)
            XCTAssertEqual(status.reason, reason)
            XCTAssertFalse(status.canToggle, reason)
            await model.setAvailable(true)
            XCTAssertFalse(transport.requested.contains("PATCH \(Self.path)"), reason)
            XCTAssertEqual(self.status(model)?.available, false, reason)
        }
    }

    /// A failed availability read is a failure on the row, not a missing row.
    func testAFailedReadIsAFailure() async throws {
        let (model, _) = try await model([Self.path: .json(#"{"error":"Internal error"}"#, status: 500)])
        await model.load()
        guard case .failed = model.state else { return XCTFail("expected a failure, got \(model.state)") }
        await model.setAvailable(true)
        guard case .failed = model.state else { return XCTFail("a write on a failed read changed \(model.state)") }
    }

    /// ⛔ A list that could not be read hides the row; it is not an availability failure.
    func testAFailedWorkspaceListHidesTheRow() async throws {
        let (model, transport) = try await model([Self.listPath: .json(#"{"error":"Internal error"}"#, status: 500)])
        await model.load()
        guard case .noWorkspace = model.state else { return XCTFail("expected no workspace, got \(model.state)") }
        XCTAssertFalse(transport.requested.contains { $0.hasSuffix(Self.path) })
    }

    func testAnEmptyWorkspaceListHidesTheRow() async throws {
        let empty = #"{"success":true,"workspaces":[],"total":0,"limit":100,"offset":0,"#
            + #""degradedRegions":[],"inactiveCount":0}"#
        let (model, _) = try await model([Self.listPath: .json(empty)])
        await model.load()
        guard case .noWorkspace = model.state else { return XCTFail("expected no workspace, got \(model.state)") }
    }

    /// ⛔ The switch shows the server's echo, not the value asked for.
    func testASaveAdoptsTheServersEcho() async throws {
        let (model, transport) = try await model(
            [:],
            sequences: [Self.path: [.json(Self.unavailable), .json(Self.unavailable)]]
        )
        await model.load()
        await model.setAvailable(true)
        XCTAssertEqual(status(model)?.available, false, "the server wrote false")
        XCTAssertEqual(status(model)?.workspaceName, "Bravo Client")
        XCTAssertFalse(model.saving)
        XCTAssertNil(model.writeFailure)
        XCTAssertTrue(transport.requested.contains("PATCH \(Self.path)"))
    }

    func testASaveThatTurnsAvailabilityOn() async throws {
        let (model, _) = try await model(
            [:],
            sequences: [Self.path: [.json(Self.unavailable), .json(Self.available)]]
        )
        await model.load()
        await model.setAvailable(true)
        XCTAssertEqual(status(model)?.available, true)
    }

    /// A refused save keeps the last confirmed value and says why beside it.
    func testARefusedSaveKeepsTheConfirmedValue() async throws {
        let (model, _) = try await model(
            [:],
            sequences: [Self.path: [.json(Self.available), .json(#"{"error":"Internal error"}"#, status: 500)]]
        )
        await model.load()
        await model.setAvailable(false)
        XCTAssertEqual(status(model)?.available, true)
        XCTAssertNotNil(model.writeFailure)
        XCTAssertFalse(model.saving)
        model.dismissFailure()
        XCTAssertNil(model.writeFailure)
    }

    /// A reload clears a write failure left from before.
    func testAReloadClearsAWriteFailure() async throws {
        let (model, _) = try await model(
            [:],
            sequences: [Self.path: [.json(Self.available), .json(Self.refused, status: 500), .json(Self.available)]]
        )
        await model.load()
        await model.setAvailable(false)
        XCTAssertNotNil(model.writeFailure)
        await model.load()
        XCTAssertNil(model.writeFailure)
        XCTAssertEqual(status(model)?.available, true)
    }

    /// ⚠️ A second toggle while one is in flight is dropped.
    func testASecondToggleWhileSavingIsDropped() async throws {
        let (model, transport) = try await model([Self.path: .json(Self.available)])
        await model.load()
        // The first write is held in flight until the second toggle has been tried.
        transport.hold("PATCH \(Self.path)")
        let first = Task { await model.setAvailable(false) }
        await transport.waitUntilHeld("PATCH \(Self.path)")
        XCTAssertTrue(model.saving)
        await model.setAvailable(true)
        transport.release("PATCH \(Self.path)")
        await first.value
        XCTAssertEqual(transport.requested.filter { $0 == "PATCH \(Self.path)" }.count, 1)
    }

    /// ⚠️ A name that ends in its own period closes the sentence once; an ellipsis is left alone.
    func testTheSubtitleEndsWithOneFullStop() {
        let once = AvailabilityCopy.rowSubtitleOnce("Plomberie Desrosiers-Lanthier inc.")
        XCTAssertFalse(once.hasSuffix(".."), once)
        XCTAssertTrue(once.hasSuffix("."), once)
        let plain = AvailabilityCopy.rowSubtitleOnce("Bravo Client")
        XCTAssertEqual(plain, AvailabilityCopy.rowSubtitle("Bravo Client"))
        let ellipsis = AvailabilityCopy.rowSubtitleOnce("Wait...")
        XCTAssertEqual(ellipsis, AvailabilityCopy.rowSubtitle("Wait..."))
    }
}
