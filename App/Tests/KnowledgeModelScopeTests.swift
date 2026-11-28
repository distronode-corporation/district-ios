@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// The knowledge model's reads and writes against the service's recorded knowledge
/// responses: the two reads that land independently, adding a document, and the mode switch.
/// (Reading a picked file is `KnowledgeModelFileTests`.)
///
/// ⚠️ A SUBCLASS OF ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN CONTAINER; nothing here
/// draws.
final class KnowledgeModelScopeTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let documents = "/api/district/workspace/knowledge"
    private static let mode = "/api/district/workspace/knowledge-mode"

    private func loaded(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (KnowledgeModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let container = try await container(transport)
        let model = KnowledgeModel(container: container, workspaceId: Self.workspace, role: role)
        await model.load()
        return (model, transport)
    }

    // MARK: - Reads

    func testBothReadsLand() async throws {
        let (model, _) = try await loaded()
        XCTAssertEqual(model.documents.map(\.id), ["doc_contract_ready", "doc_contract_processing"])
        XCTAssertEqual(model.mode, "linked")
        XCTAssertFalse(model.modeUnavailable)
        XCTAssertTrue(model.canChangeMode)
    }

    /// ⚠️ AN UNREADABLE MODE DOES NOT TAKE THE DOCUMENTS WITH IT, and is not offered as a choice.
    func testAnUnreadableModeLeavesTheListAndOffersNoChoice() async throws {
        let (model, transport) = try await loaded([Self.mode: .refused(500)])
        XCTAssertEqual(model.documents.count, 2)
        XCTAssertNil(model.mode)
        XCTAssertTrue(model.modeUnavailable)
        XCTAssertFalse(model.canChangeMode)
        await model.setMode(.internal)
        XCTAssertEqual(transport.requested.filter { $0.hasPrefix("PATCH") }, [])
    }

    func testAnUnreadableListFails() async throws {
        let (model, _) = try await loaded([Self.documents: .refused(500)])
        guard case .failed = model.list else { return XCTFail("expected a failed list") }
        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertEqual(model.mode, "linked")
    }

    // MARK: - Adding

    /// A blank title or body is refused here and nothing is sent; an edit retires the refusal.
    func testABlankDocumentIsRefused() async throws {
        let (model, transport) = try await loaded()
        model.editTitle("  ")
        model.editContent("Body")
        XCTAssertFalse(model.canAdd)
        await model.addDocument()
        XCTAssertTrue(model.addRejected)
        model.editTitle("Holiday hours")
        XCTAssertFalse(model.addRejected)
        model.editContent("\n\n")
        await model.addDocument()
        XCTAssertTrue(model.addRejected)
        XCTAssertFalse(transport.requested.contains { $0.hasPrefix("POST") })
    }

    /// A viewer's add is not even a refusal: nothing is offered.
    func testAViewerAddsNothing() async throws {
        let (model, transport) = try await loaded(role: .viewer)
        model.editTitle("Holiday hours")
        model.editContent("Closed on the 25th.")
        XCTAssertFalse(model.canAdd)
        XCTAssertFalse(model.canChangeMode)
        await model.addDocument()
        await model.setMode(.internal)
        XCTAssertFalse(model.addRejected)
        XCTAssertEqual(transport.requested.filter { !$0.hasPrefix("GET") }, [])
    }

    /// A document that lands clears the form and re-reads the list.
    func testADocumentThatLandsClearsTheFormAndReReads() async throws {
        let (model, transport) = try await loaded(["POST \(Self.documents)": .fixture("district-knowledge-create")])
        model.editTitle(" Holiday hours ")
        model.editContent(" Closed on the 25th. ")
        await model.addDocument()
        XCTAssertEqual(model.draftTitle, "")
        XCTAssertEqual(model.draftContent, "")
        guard case .saved = model.addSave else { return XCTFail("expected saved, got \(model.addSave)") }
        XCTAssertEqual(transport.requested.last, "GET \(Self.documents)")
    }

    /// ⚠️ A REFUSED DOCUMENT KEEPS WHAT WAS TYPED.
    func testARefusedDocumentKeepsTheForm() async throws {
        let (model, _) = try await loaded(["POST \(Self.documents)": .refused(400, "Too long")])
        model.editTitle("Holiday hours")
        model.editContent("Closed on the 25th.")
        await model.addDocument()
        XCTAssertEqual(model.draftTitle, "Holiday hours")
        guard case let .failed(failure) = model.addSave else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.message, "Too long")
        model.dismissNotices()
        guard case .idle = model.addSave else { return XCTFail("expected dismissed") }
    }

    // MARK: - The mode

    /// ⛔ ONLY A MOVE TO `linked` IS A RESIDENCY CHANGE, and only from somewhere else.
    func testOnlyAMoveToLinkedIsAResidencyChange() async throws {
        let (linked, _) = try await loaded()
        XCTAssertFalse(linked.isResidencyChange(to: .linked))
        XCTAssertFalse(linked.isResidencyChange(to: .internal))
        let (internalMode, _) = try await loaded([Self.mode: .fixture("district-knowledge-mode-patch")])
        XCTAssertEqual(internalMode.mode, "internal")
        XCTAssertTrue(internalMode.isResidencyChange(to: .linked))
    }

    /// The mode the service stored is the one shown; choosing the held one sends nothing.
    func testAModeChangeShowsWhatWasStored() async throws {
        let (model, transport) = try await loaded([
            "PATCH \(Self.mode)": .fixture("district-knowledge-mode-patch"),
        ])
        await model.setMode(.linked)
        XCTAssertFalse(transport.requested.contains { $0.hasPrefix("PATCH") })
        await model.setMode(.internal)
        XCTAssertEqual(model.mode, "internal")
        guard case .saved = model.modeSave else { return XCTFail("expected saved") }
    }

    func testARefusedModeChangeKeepsTheHeldMode() async throws {
        let (model, _) = try await loaded(["PATCH \(Self.mode)": .refused(403)])
        await model.setMode(.internal)
        XCTAssertEqual(model.mode, "linked")
        guard case .failed = model.modeSave else { return XCTFail("expected a failure") }
    }
}
