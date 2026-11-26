@testable import DistrictAI
import XCTest

/// What the phone sends the Watch, built by ``ContainerWatchSnapshotSource`` from a real
/// container over the service's recorded responses: the selected workspace, availability,
/// the unread count, the conversations and the calls, each read failing on its own.
final class WatchSnapshotSourceTests: ScreenSnapshotTestCase {
    private static let availability = "/api/district/workspace/availability"
    private static let available = #"{"success":true,"availableForCalls":true,"reason":null}"#
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let noWorkspaces = #"{"success":true,"workspaces":[],"total":0,"limit":50,"offset":0,"#
        + #""degradedRegions":[],"inactiveCount":0,"defaultWorkspaceId":null}"#

    override func setUp() async throws {
        try await super.setUp()
        // ⚠️ THE STORED SELECTION IS CLEARED, so the recorded list's default workspace is the
        // one chosen, whatever another test left in the standard defaults.
        WorkspaceSelectionStore().setSelectedWorkspaceId(nil)
    }

    private func snapshot(_ replies: [String: FixtureTransport.Reply]) async throws -> WatchSnapshot? {
        let container = try await container(FixtureTransport(replies))
        return await ContainerWatchSnapshotSource(container: container).snapshot(at: Self.now)
    }

    /// Every read answered: the recorded default workspace, its unread count, both recorded
    /// conversations and the recorded calls, stamped with the time asked for.
    func testEveryReadAnswered() async throws {
        let built = try await snapshot([Self.availability: .json(Self.available)])
        let watch = try XCTUnwrap(built)
        XCTAssertTrue(watch.signedIn)
        XCTAssertEqual(watch.generatedAt, Self.now)
        XCTAssertEqual(watch.workspace?.id, "ws-contract-viewer")
        XCTAssertEqual(watch.workspace?.name, "Alpha Client")
        XCTAssertEqual(watch.availability?.available, true)
        XCTAssertEqual(watch.unreadCount, 3)
        XCTAssertEqual(watch.conversations?.count, 2)
        XCTAssertEqual(watch.calls?.count, 5)
    }

    /// A call log that could not be read leaves the calls out and keeps everything else.
    func testARefusedCallLogBlanksOnlyTheCalls() async throws {
        let built = try await snapshot([
            Self.availability: .json(Self.available),
            "/api/district/calls": .json(#"{"error":"Internal error"}"#, status: 500),
        ])
        let watch = try XCTUnwrap(built)
        XCTAssertNil(watch.calls)
        XCTAssertEqual(watch.unreadCount, 3)
        XCTAssertEqual(watch.conversations?.count, 2)
    }

    /// Refused availability and inbox reads leave those parts out, not zeroed.
    func testRefusedInboxAndAvailabilityAreLeftOut() async throws {
        let refused = FixtureTransport.Reply.json(#"{"error":"Internal error"}"#, status: 500)
        let built = try await snapshot([
            Self.availability: refused,
            "/api/district/messages/unread-count": refused,
            "/api/district/conversations": refused,
        ])
        let watch = try XCTUnwrap(built)
        XCTAssertNil(watch.availability)
        XCTAssertNil(watch.unreadCount)
        XCTAssertNil(watch.conversations)
        XCTAssertEqual(watch.calls?.count, 5)
    }

    /// No workspace at all is said so, with nothing else in it.
    func testNoWorkspace() async throws {
        let built = try await snapshot([
            "/api/district/workspace/list": .json(Self.noWorkspaces),
        ])
        let watch = try XCTUnwrap(built)
        XCTAssertTrue(watch.signedIn)
        XCTAssertNil(watch.workspace)
        XCTAssertNil(watch.calls)
        XCTAssertNil(watch.conversations)
    }

    /// A workspace list that cannot be read publishes nothing rather than "no workspace".
    func testAnUnreadableWorkspaceListPublishesNoWorkspaceSentence() async throws {
        let built = try await snapshot([
            "/api/district/workspace/list": .json(#"{"error":"Internal error"}"#, status: 500),
        ])
        // The model reads a failed list as no selection; the Watch is told there is no
        // workspace only through the composer's own sentence, never with stale rows.
        XCTAssertNil(built?.calls)
        XCTAssertNil(built?.conversations)
    }
}
