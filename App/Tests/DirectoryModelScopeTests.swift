@testable import DistrictAI
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The transfer directory editor against the service's recorded config: which stored values
/// it will edit, how rows are added, removed and filtered, what a row sends, and each save
/// outcome.
///
/// ⚠️ A SUBCLASS OF ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN CONTAINER; nothing here
/// draws.
final class DirectoryModelScopeTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let config = "/api/district/workspace/config"
    private static let save = "PATCH /api/district/workspace/directory"

    private func loaded(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (DirectoryModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let container = try await container(transport)
        let model = DirectoryModel(container: container, workspaceId: Self.workspace, role: role)
        await model.loadConfig()
        return (model, transport)
    }

    private func configWithDirectory(_ value: Any) -> FixtureTransport.Reply {
        .recorded("district-workspace-config") { json in
            json.editObject("config") { $0["callDirectory"] = value }
        }
    }

    // MARK: - Reading

    func testTheRecordedRowsBecomeDrafts() async throws {
        let (model, _) = try await loaded()
        let drafts = try XCTUnwrap(model.drafts)
        XCTAssertEqual(drafts.map(\.name), ["Ops desk", "On-call engineer"])
        XCTAssertEqual(drafts.map(\.phoneNumber), ["+14165550177", "+14165550166"])
        XCTAssertFalse(model.notEditable)
        XCTAssertTrue(model.canSave)
    }

    /// An absent or null directory is an empty one, which can be added to.
    func testANullDirectoryIsEmpty() async throws {
        let (model, _) = try await loaded([Self.config: configWithDirectory(NSNull())])
        XCTAssertEqual(model.drafts?.count, 0)
        XCTAssertTrue(model.wouldSaveEmpty)
        model.addRow()
        XCTAssertEqual(model.drafts?.count, 1)
    }

    /// ⛔ A STORED VALUE THIS BUILD CANNOT READ IS NOT EDITED, so a save cannot overwrite it.
    func testAnUnreadableDirectoryIsNotEditable() async throws {
        for hostile: Any in ["not a list", [["name": "Desk"], "loose string"] as [Any], 42] {
            let (model, transport) = try await loaded([Self.config: configWithDirectory(hostile)])
            XCTAssertTrue(model.notEditable, "\(hostile) should not be editable")
            XCTAssertNil(model.drafts)
            XCTAssertFalse(model.canSave)
            model.addRow()
            XCTAssertNil(model.drafts)
            await model.saveDirectory()
            XCTAssertFalse(transport.requested.contains(Self.save))
        }
    }

    func testAFailedReadHasNoDrafts() async throws {
        let (model, _) = try await loaded([Self.config: .refused(500)])
        XCTAssertNil(model.drafts)
        XCTAssertFalse(model.canSave)
    }

    // MARK: - Editing

    /// Blank rows are dropped from the save; a row with only a name is still sent.
    func testBlankRowsAreNotSent() async throws {
        let (model, _) = try await loaded()
        model.addRow()
        model.addRow()
        let ids = try XCTUnwrap(model.drafts).map(\.id)
        XCTAssertEqual(ids, [0, 1, 2, 3], "new rows take the next ids")
        model.editName(3, "Front desk")
        let added = try XCTUnwrap(model.drafts?.last)
        XCTAssertTrue(added.isIncomplete)
        XCTAssertFalse(added.isBlank)
        model.removeRow(0)
        model.removeRow(1)
        XCTAssertEqual(model.drafts?.map(\.id), [2, 3])
        XCTAssertFalse(model.wouldSaveEmpty)
        model.removeRow(3)
        XCTAssertTrue(model.wouldSaveEmpty, "only a blank row is left")
    }

    /// An edit to a row that is gone does nothing.
    func testAnEditToAMissingRowIsIgnored() async throws {
        let (model, _) = try await loaded()
        model.editNumber(99, "+1")
        model.editType(99, "app")
        XCTAssertEqual(model.drafts?.map(\.phoneNumber), ["+14165550177", "+14165550166"])
    }

    /// A viewer can neither edit, add, remove nor save.
    func testAViewerChangesNothing() async throws {
        let (model, transport) = try await loaded(role: .viewer)
        model.editName(0, "Changed")
        model.addRow()
        model.removeRow(1)
        await model.saveDirectory()
        XCTAssertEqual(model.drafts?.map(\.name), ["Ops desk", "On-call engineer"])
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(transport.requested.contains(Self.save))
    }

    // MARK: - Saving

    func testASaveThatLandsReReadsTheConfig() async throws {
        let (model, transport) = try await loaded([Self.save: .fixture("district-directory-patch")])
        model.editType(0, "app")
        await model.saveDirectory()
        guard case .saved = model.save else { return XCTFail("expected saved, got \(model.save)") }
        XCTAssertEqual(transport.requested.last, "GET \(Self.config)")
        XCTAssertNil(model.drafts?.first?.type, "the re-read is what the screen now holds")
        model.dismissNotices()
        guard case .idle = model.save else { return XCTFail("expected dismissed") }
    }

    func testARefusedSaveKeepsTheEdits() async throws {
        let (model, _) = try await loaded([Self.save: .refused(400, "Not a phone number")])
        model.editNumber(0, "call me")
        await model.saveDirectory()
        guard case let .failed(failure) = model.save else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.message, "Not a phone number")
        XCTAssertEqual(model.drafts?.first?.phoneNumber, "call me")
    }

    // MARK: - What a row sends

    /// ⛔ A STORED ROW IS CARRIED WHOLE: unknown keys survive, the two edited ones are trimmed.
    func testARowCarriesItsUnknownKeysAndTrims() {
        let stored = WireJSON.object([
            "name": .string("On-call engineer"),
            "phoneNumber": .string("+14165550166"),
            "extension": .string("402"),
            "type": .string("app"),
        ])
        var draft = DirectoryDraft(id: 0, row: stored)
        XCTAssertEqual(draft.type, "app")
        draft.name = "  On call  "
        draft.phoneNumber = " +14165550100\n"
        XCTAssertEqual(draft.rendered(), .object([
            "name": .string("On call"),
            "phoneNumber": .string("+14165550100"),
            "extension": .string("402"),
            "type": .string("app"),
        ]))
        draft.type = nil
        XCTAssertEqual(draft.rendered(), .object([
            "name": .string("On call"),
            "phoneNumber": .string("+14165550100"),
            "extension": .string("402"),
        ]))
    }

    /// A new row, and a stored row whose fields are not strings, start blank.
    func testNonStringFieldsReadAsBlank() {
        let empty = DirectoryDraft(id: 1, row: nil)
        XCTAssertTrue(empty.isBlank)
        XCTAssertTrue(empty.isIncomplete)
        XCTAssertEqual(empty.rendered(), .object(["name": .string(""), "phoneNumber": .string("")]))
        let odd = DirectoryDraft(id: 2, row: .object(["name": .integer(7), "phoneNumber": .null, "type": .bool(true)]))
        XCTAssertEqual(odd.name, "")
        XCTAssertEqual(odd.phoneNumber, "")
        XCTAssertNil(odd.type)
    }
}
