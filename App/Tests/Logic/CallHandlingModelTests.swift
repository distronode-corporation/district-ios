@testable import DistrictAI
import DistrictModel
import XCTest

/// ``CallHandlingModel`` over a real container: what it reads, the draft it keeps, what a save
/// sends, the server's echo it adopts, and what a viewer may not do. (The screen itself is not
/// drawn: its large title could not hold a reference; see SettingsSnapshotTests.)
final class CallHandlingModelTests: ScreenSnapshotTestCase {
    private static let path = "/api/district/workspace/call-handling"
    private static let recorded = #"{"success":true,"callHandling":"ai_then_app","appRingSeconds":20}"#

    private func model(
        _ replies: [String: FixtureTransport.Reply],
        sequences: [String: [FixtureTransport.Reply]] = [:],
        role: WorkspaceRole = .client
    ) async throws -> (CallHandlingModel, FixtureTransport) {
        let transport = FixtureTransport(replies, sequences: sequences)
        let container = try await container(transport)
        return (CallHandlingModel(container: container, workspaceId: "ws-contract-test", role: role), transport)
    }

    func testTheReadBecomesTheBaselineAndTheDraft() async throws {
        let (model, _) = try await model([Self.path: .json(Self.recorded)])
        await model.load()
        XCTAssertEqual(model.draft, CallHandlingSetting(mode: "ai_then_app", ringSeconds: 20))
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.canSave)
    }

    /// A failed read is a failure with no draft, not a picker on a stale baseline.
    func testAFailedReadKeepsNoDraft() async throws {
        let (model, _) = try await model([Self.path: .json(#"{"error":"Internal error"}"#, status: 500)])
        await model.load()
        guard case .failed = model.load else { return XCTFail("expected a failure, got \(model.load)") }
        XCTAssertNil(model.draft)
        model.select(mode: "app_first")
        model.setRing(10)
        XCTAssertNil(model.draft)
    }

    /// The ring time is clamped to the service's range, whatever is asked for.
    func testTheRingIsClamped() async throws {
        let (model, _) = try await model([Self.path: .json(Self.recorded)])
        await model.load()
        model.setRing(1)
        XCTAssertEqual(model.draft?.ringSeconds, CallHandling.minimumRingSeconds)
        model.setRing(999)
        XCTAssertEqual(model.draft?.ringSeconds, CallHandling.maximumRingSeconds)
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.canSave)
    }

    /// A save sends only what changed, and adopts the server's echo rather than the draft.
    func testASaveAdoptsTheServersValues() async throws {
        let echo = #"{"success":true,"callHandling":"app_first","appRingSeconds":15}"#
        let (model, transport) = try await model(
            [:],
            sequences: [Self.path: [.json(Self.recorded), .json(echo)]]
        )
        await model.load()
        model.select(mode: "app_first")
        model.setRing(16)
        await model.saveChanges()
        XCTAssertEqual(model.draft, CallHandlingSetting(mode: "app_first", ringSeconds: 15))
        guard case .saved = model.save else { return XCTFail("expected saved, got \(model.save)") }
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(transport.requested.filter { $0.hasSuffix(Self.path) }.count, 2)
        model.dismissNotices()
        guard case .idle = model.save else { return XCTFail("expected idle, got \(model.save)") }
    }

    /// A refused save keeps the edits and says why.
    func testARefusedSaveKeepsTheDraft() async throws {
        let (model, _) = try await model(
            [:],
            sequences: [Self.path: [.json(Self.recorded), .json(#"{"error":"Internal error"}"#, status: 500)]]
        )
        await model.load()
        model.select(mode: "app_first")
        await model.saveChanges()
        guard case .failed = model.save else { return XCTFail("expected a failed save, got \(model.save)") }
        XCTAssertEqual(model.draft?.mode, "app_first")
        XCTAssertTrue(model.isDirty)
    }

    /// Nothing changed: no save is sent.
    func testAnUnchangedDraftSendsNothing() async throws {
        let (model, transport) = try await model([Self.path: .json(Self.recorded)])
        await model.load()
        await model.saveChanges()
        XCTAssertEqual(transport.requested.filter { $0.hasSuffix(Self.path) }.count, 1)
        guard case .idle = model.save else { return XCTFail("expected idle, got \(model.save)") }
    }

    /// A viewer reads but changes nothing and saves nothing.
    func testAViewerCannotChangeAnything() async throws {
        let (model, transport) = try await model([Self.path: .json(Self.recorded)], role: .viewer)
        await model.load()
        model.select(mode: "app_first")
        model.setRing(10)
        await model.saveChanges()
        XCTAssertEqual(model.draft, CallHandlingSetting(mode: "ai_then_app", ringSeconds: 20))
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(transport.requested.filter { $0.hasSuffix(Self.path) }.count, 1)
    }
}
