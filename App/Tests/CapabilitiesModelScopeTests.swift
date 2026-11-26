@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// The skills model against the service's recorded config: which tools are drawn on, what
/// a save sends (an unknown stored tool survives it), and the caller-enrichment switch.
///
/// ⚠️ A SUBCLASS OF ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN CONTAINER; nothing here
/// draws.
final class CapabilitiesModelScopeTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let config = "/api/district/workspace/config"
    private static let tools = "PATCH /api/district/workspace/tools"
    private static let persona = "PATCH /api/district/workspace/persona"

    private typealias Loaded = (CapabilitiesModel, FixtureTransport)

    private func loaded(_ replies: [String: FixtureTransport.Reply] = [:]) async throws -> Loaded {
        let transport = FixtureTransport(replies)
        let container = try await container(transport)
        let model = CapabilitiesModel(container: container, workspaceId: Self.workspace)
        await model.loadConfig()
        return (model, transport)
    }

    // MARK: - Reading

    /// The catalogue in its order, on where stored, then the stored tool this build does not
    /// know, drawn under its wire id.
    func testRowsAreTheCatalogueThenUnknownStoredTools() async throws {
        let (model, _) = try await loaded()
        XCTAssertEqual(model.rows.map(\.id), CapabilityCatalog.ids + ["transfer_to_creator"])
        let enabled = model.rows.filter(\.enabled).map(\.id)
        XCTAssertEqual(Set(enabled), [
            "search_knowledge_base", "transfer_to_agent", "book_appointment", "transfer_to_creator",
            "leave_message", "dispatch_email",
        ])
        XCTAssertNil(model.rows.last?.label)
        XCTAssertTrue(model.canEditTools)
        XCTAssertFalse(model.toolsDirty)
        XCTAssertTrue(model.enrichmentEnabled)
    }

    /// ⛔ NO STORED LIST MEANS EVERY TOOL IS ON, and the list cannot be edited into existence.
    func testNoStoredListIsEveryToolOnAndNotEditable() async throws {
        let (model, transport) = try await loaded([Self.config: .fixture("district-workspace-config-sparse")])
        XCTAssertFalse(model.hasStoredTools)
        XCTAssertTrue(model.rows.allSatisfy(\.enabled))
        XCTAssertEqual(model.rows.count, CapabilityCatalog.ids.count)
        XCTAssertNil(model.pendingTools)
        model.toggleTool("send_sms", to: false)
        XCTAssertFalse(model.toolsDirty)
        await model.saveTools()
        XCTAssertFalse(transport.requested.contains(Self.tools))
        XCTAssertFalse(model.enrichmentEnabled, "an absent switch reads as off")
    }

    func testAFailedReadDrawsNoRows() async throws {
        let (model, _) = try await loaded([Self.config: .refused(500)])
        XCTAssertTrue(model.rows.isEmpty)
        model.toggleEnrichment(to: false)
        XCTAssertFalse(model.enrichmentDirty)
        XCTAssertFalse(model.canSaveEnrichment)
    }

    func testEveryCatalogueToolHasALabelAndNothingElseDoes() {
        for id in CapabilityCatalog.ids {
            XCTAssertNotNil(CapabilityCatalog.label(for: id), id)
        }
        XCTAssertNil(CapabilityCatalog.label(for: "transfer_to_creator"))
        XCTAssertNil(CapabilityCatalog.label(for: ""))
    }

    // MARK: - Tools

    /// ⛔ TURNING A TOOL OFF AND ANOTHER ON SENDS THE STORED ORDER, THE NEW ONE APPENDED, AND THE
    /// UNKNOWN STORED TOOL KEPT.
    func testAToggleKeepsStoredOrderAndUnknownTools() async throws {
        let (model, _) = try await loaded()
        model.toggleTool("transfer_to_agent", to: false)
        model.toggleTool("send_sms", to: true)
        XCTAssertEqual(model.pendingTools, [
            "search_knowledge_base", "book_appointment", "transfer_to_creator", "leave_message",
            "dispatch_email", "send_sms",
        ])
        XCTAssertTrue(model.toolsDirty)
        model.toggleTool("transfer_to_agent", to: true)
        model.toggleTool("send_sms", to: false)
        XCTAssertFalse(model.toolsDirty, "back where it started")
    }

    func testASavedToolListReReadsAndClearsTheToggles() async throws {
        let (model, transport) = try await loaded([Self.tools: .fixture("district-tools-patch")])
        model.toggleTool("send_sms", to: true)
        XCTAssertTrue(model.canSaveTools)
        await model.saveTools()
        guard case .saved = model.toolsSave else { return XCTFail("expected saved, got \(model.toolsSave)") }
        XCTAssertEqual(transport.requested.last, "GET \(Self.config)")
        XCTAssertFalse(model.toolsDirty, "the toggles give way to the re-read")
    }

    func testARefusedToolListKeepsTheToggles() async throws {
        let (model, _) = try await loaded([Self.tools: .refused(400, "Unknown tool")])
        model.toggleTool("send_sms", to: true)
        await model.saveTools()
        guard case let .failed(failure) = model.toolsSave else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.message, "Unknown tool")
        XCTAssertTrue(model.toolsDirty)
        model.dismissNotices()
        guard case .idle = model.toolsSave else { return XCTFail("expected dismissed") }
    }

    // MARK: - Enrichment

    func testTheEnrichmentSwitchIsDirtyOnlyWhenMoved() async throws {
        let (model, transport) = try await loaded()
        model.toggleEnrichment(to: true)
        XCTAssertFalse(model.enrichmentDirty)
        await model.saveEnrichment()
        XCTAssertFalse(transport.requested.contains(Self.persona))
        model.toggleEnrichment(to: false)
        XCTAssertTrue(model.enrichmentDirty)
        XCTAssertFalse(model.enrichmentEnabled)
    }

    func testASavedEnrichmentSwitchReReads() async throws {
        let (model, transport) = try await loaded([Self.persona: .fixture("district-persona-patch")])
        model.toggleEnrichment(to: false)
        await model.saveEnrichment()
        guard case .saved = model.enrichmentSave else { return XCTFail("expected saved") }
        XCTAssertEqual(transport.requested.last, "GET \(Self.config)")
        XCTAssertFalse(model.enrichmentDirty)
    }

    func testARefusedEnrichmentSwitchStaysMoved() async throws {
        let (model, _) = try await loaded([Self.persona: .refused(500)])
        model.toggleEnrichment(to: false)
        await model.saveEnrichment()
        guard case .failed = model.enrichmentSave else { return XCTFail("expected a failure") }
        XCTAssertTrue(model.enrichmentDirty)
    }
}
