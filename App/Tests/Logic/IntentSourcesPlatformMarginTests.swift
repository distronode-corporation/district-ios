@testable import DistrictAI
import DistrictModel
import XCTest

/// ``ContainerIntentSources`` and ``IntentRunner`` over a real signed-in container answering from
/// the service's recorded responses: the workspace an intent acts in, the availability write it
/// sends, and the latest-message sentence it says.
final class IntentSourcesPlatformMarginTests: ScreenSnapshotTestCase {
    private static let availability = "/api/district/workspace/availability"
    private static let refused = FixtureTransport.Reply.json(#"{"error":"Internal error"}"#, status: 500)
    private static let noWorkspaces = #"{"success":true,"workspaces":[],"total":0,"limit":50,"offset":0,"#
        + #""degradedRegions":[],"inactiveCount":0,"defaultWorkspaceId":null}"#

    override func setUp() async throws {
        try await super.setUp()
        // ⚠️ The recorded list's default workspace is chosen only with no stored selection.
        WorkspaceSelectionStore().setSelectedWorkspaceId(nil)
    }

    private func makeSources(_ transport: FixtureTransport) async throws -> (ContainerIntentSources, AppContainer) {
        let container = try await container(transport)
        return (ContainerIntentSources(container: container), container)
    }

    // MARK: - The workspace

    func testTheSelectedWorkspaceIsTheRecordedDefault() async throws {
        let (sources, container) = try await makeSources(FixtureTransport())
        let workspace = try await (sources.workspace()).get()
        XCTAssertEqual(workspace, IntentWorkspace(id: "ws-contract-viewer", name: "Alpha Client"))
        withExtendedLifetime(container) {}
    }

    func testNoWorkspaceSaysChooseOneFirst() async throws {
        let (sources, container) = try await makeSources(FixtureTransport([
            "/api/district/workspace/list": .json(Self.noWorkspaces),
        ]))
        let result = await sources.workspace()
        guard case let .failure(failure) = result else { return XCTFail("no workspace must fail, got \(result)") }
        XCTAssertEqual(failure.sentence, IntentCopy.noWorkspace)
        withExtendedLifetime(container) {}
    }

    func testAnUnreadableWorkspaceListIsAFailureNeverAWorkspace() async throws {
        let (sources, container) = try await makeSources(FixtureTransport([
            "/api/district/workspace/list": Self.refused,
        ]))
        let result = await sources.workspace()
        guard case let .failure(failure) = result else { return XCTFail("a refused list must fail, got \(result)") }
        XCTAssertFalse(failure.sentence.isEmpty)
        withExtendedLifetime(container) {}
    }

    // MARK: - The reads and the write

    func testSaveAvailabilityReturnsTheServersAnswer() async throws {
        let transport = FixtureTransport([
            Self.availability: .json(#"{"success":true,"availableForCalls":false,"reason":null}"#),
        ])
        let (sources, container) = try await makeSources(transport)
        let response = try await (sources.saveAvailability(workspaceId: "ws-contract-viewer", available: false)).get()
        XCTAssertFalse(response.availableForCalls)
        XCTAssertNil(response.reason)
        XCTAssertTrue(transport.requested.contains { $0.hasSuffix(" \(Self.availability)") }, "\(transport.requested)")
        withExtendedLifetime(container) {}
    }

    func testARefusedAvailabilityWriteIsAnError() async throws {
        let (sources, container) = try await makeSources(FixtureTransport([Self.availability: Self.refused]))
        let result = await sources.saveAvailability(workspaceId: "ws-contract-viewer", available: true)
        guard case .failure = result else { return XCTFail("a 500 must be an error, got \(result)") }
        withExtendedLifetime(container) {}
    }

    func testConversationsAreTheRecordedInboxRows() async throws {
        let (sources, container) = try await makeSources(FixtureTransport())
        let rows = try await (sources.conversations(workspaceId: "ws-contract-viewer")).get()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.lastMessage.createdAt, "2026-08-15T14:20:00.000Z")
        withExtendedLifetime(container) {}
    }

    // MARK: - The runner end to end

    func testTurningAvailabilityOffIsSaidForTheWorkspace() async throws {
        let (sources, container) = try await makeSources(FixtureTransport([
            Self.availability: .json(#"{"success":true,"availableForCalls":false,"reason":null}"#),
        ]))
        let sentence = await IntentRunner(sources: sources).setAvailability(false)
        XCTAssertEqual(sentence, IntentCopy.availabilityOff("Alpha Client"))
        withExtendedLifetime(container) {}
    }

    func testTurningAvailabilityOnIsSaidForTheWorkspace() async throws {
        let (sources, container) = try await makeSources(FixtureTransport([
            Self.availability: .json(#"{"success":true,"availableForCalls":true,"reason":null}"#),
        ]))
        let sentence = await IntentRunner(sources: sources).setAvailability(true)
        XCTAssertEqual(sentence, IntentCopy.availabilityOn("Alpha Client"))
        withExtendedLifetime(container) {}
    }

    func testTheLatestMessageIsTheNewestRecordedConversation() async throws {
        let (sources, container) = try await makeSources(FixtureTransport())
        let sentence = await IntentRunner(sources: sources).latestMessageSentence()
        XCTAssertTrue(sentence.contains("Contract Test Caller"), sentence)
        XCTAssertTrue(sentence.contains("Thursday to Friday"), sentence)
        XCTAssertFalse(sentence.contains("roofing"), sentence)
        withExtendedLifetime(container) {}
    }

    func testARefusedInboxIsSaidNotSilent() async throws {
        let (sources, container) = try await makeSources(FixtureTransport([
            "/api/district/conversations": Self.refused,
        ]))
        let sentence = await IntentRunner(sources: sources).latestMessageSentence()
        XCTAssertFalse(sentence.isEmpty)
        XCTAssertNotEqual(sentence, IntentCopy.noMessages)
        withExtendedLifetime(container) {}
    }
}
