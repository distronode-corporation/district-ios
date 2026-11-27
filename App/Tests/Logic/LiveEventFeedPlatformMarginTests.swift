@testable import DistrictAI
import DistrictLive
import DistrictModel
import XCTest

/// ``LiveEventFeed`` over the real ``TelemetryConnectionRunner``, a scripted socket and a manual
/// clock: the connection states the Live screen draws, what reaches `onEvent`, and when a lost
/// socket reads "reconnecting" rather than "loading".
@MainActor
final class LiveEventFeedPlatformMarginTests: XCTestCase {
    private let clock = ManualLiveClock()
    private let script = SocketScript()

    private func makeFeed(minter: ScriptedMinter? = nil) -> LiveEventFeed {
        LiveEventFeed(
            workspaceId: TranscriptWire.workspaceId,
            dependencies: LiveEventFeed.Dependencies(
                minter: minter ?? ScriptedMinter(clock: clock),
                transport: script.transport(clock: clock),
                clock: clock,
                jitter: { 0 }
            )
        )
    }

    private func open(_ feed: LiveEventFeed) async -> FakeWebSocketTask? {
        feed.activate()
        await waitUntil(state: "connection=\(feed.connection)") { feed.connection == .open }
        return script.tasks.first
    }

    // MARK: - Opening

    func testActivateConnectsThenOpensAndSaysSoOnce() async {
        let feed = makeFeed()
        let seen = FeedRecord()
        feed.onOpen = { seen.opens += 1 }
        XCTAssertEqual(feed.connection, .idle)

        feed.activate()
        XCTAssertEqual(feed.connection, .connecting)
        XCTAssertFalse(feed.reconnecting, "a first connect is loading, not lost")
        await waitUntil { feed.connection == .open }

        XCTAssertEqual(seen.opens, 1)
        XCTAssertFalse(feed.reconnecting)
        // ⛔ The broadcast socket sends no mode frame and no subscription on open.
        XCTAssertEqual(script.tasks.first?.sent, [])
        feed.deactivate()
    }

    func testASecondActivateOpensNoSecondSocket() async {
        let minter = ScriptedMinter(clock: clock)
        let feed = makeFeed(minter: minter)
        _ = await open(feed)
        feed.activate()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(script.tasks.count, 1)
        XCTAssertEqual(minter.count, 1)
        feed.deactivate()
    }

    // MARK: - Events

    func testAnEnvelopeForThisWorkspaceReachesOnEvent() async {
        let feed = makeFeed()
        let seen = FeedRecord()
        feed.onEvent = { seen.events.append($0) }
        let task = await open(feed)

        task?.deliver(TranscriptWire.envelope("call_updated", #"{"status":"ringing"}"#))
        await waitUntil(state: "events=\(seen.events.count)") { seen.events.count == 1 }

        XCTAssertEqual(seen.events.first?.eventType, .callUpdated)
        XCTAssertEqual(seen.events.first?.callId, TranscriptWire.callId)
        feed.deactivate()
    }

    /// ⛔ Another workspace's envelope and an unreadable frame are dropped, never passed on.
    func testAnotherWorkspacesEnvelopeAndGarbageAreDropped() async {
        let feed = makeFeed()
        let seen = FeedRecord()
        feed.onEvent = { seen.events.append($0) }
        let task = await open(feed)

        task?.deliver(#"{"workspaceId":"ws_other","callId":"call_1","eventType":"call_updated","data":{},"#
            + #""timestamp":"2026-10-06T14:30:02.010Z"}"#)
        task?.deliver("not json at all")
        task?.deliver("")
        task?.deliver(TranscriptWire.envelope("call_ended", "{}"))
        await waitUntil(state: "events=\(seen.events.count)") { seen.events.count == 1 }

        XCTAssertEqual(seen.events.map(\.eventType), [.callEnded])
        XCTAssertEqual(feed.connection, .open)
        feed.deactivate()
    }

    // MARK: - Losing the socket

    func testALostSocketAfterOpeningReadsReconnectingUntilItReopens() async {
        let feed = makeFeed()
        let seen = FeedRecord()
        feed.onOpen = { seen.opens += 1 }
        let first = await open(feed)

        first?.serverClosed(code: 1011, reason: "Server error")
        await waitUntil(state: "connection=\(feed.connection)") { feed.connection == .connecting }
        XCTAssertTrue(feed.reconnecting)

        for _ in 0 ..< 200 where feed.connection != .open {
            clock.advance(by: 1000)
            try? await Task.sleep(for: .milliseconds(5))
        }
        await waitUntil(state: "connection=\(feed.connection)") { feed.connection == .open }

        XCTAssertFalse(feed.reconnecting)
        XCTAssertEqual(seen.opens, 2)
        XCTAssertEqual(script.tasks.count, 2)
        feed.deactivate()
    }

    /// ⛔ 4403 ENDS THE FEED WITH AN ERROR, and a deactivate afterwards keeps it failed.
    func testA4403FailsAndDeactivateKeepsItFailed() async {
        let feed = makeFeed()
        let first = await open(feed)

        first?.serverClosed(code: 4403, reason: "Access denied to workspace")
        await waitUntil(state: "connection=\(feed.connection)") { feed.connection == .failed }
        XCTAssertFalse(feed.reconnecting)

        feed.deactivate()
        XCTAssertEqual(feed.connection, .failed)
        XCTAssertEqual(script.tasks.count, 1, "a forbidden workspace is not retried")
    }

    // MARK: - Deactivating

    func testDeactivateClosesTheSocketAndReturnsToIdle() async {
        let feed = makeFeed()
        let task = await open(feed)

        feed.deactivate()

        XCTAssertEqual(feed.connection, .idle)
        XCTAssertFalse(feed.reconnecting)
        await waitUntil(state: "cancels=\(task?.cancelCodes ?? [])") { task?.cancelCodes.isEmpty == false }
        XCTAssertEqual(task?.cancelCodes.first, .normalClosure)
    }

    func testDeactivateBeforeActivateIsHarmless() {
        let feed = makeFeed()
        feed.deactivate()
        XCTAssertEqual(feed.connection, .idle)
        XCTAssertTrue(script.tasks.isEmpty)
    }

    func testAFeedCanBeActivatedAgainAfterDeactivating() async {
        let feed = makeFeed()
        _ = await open(feed)
        feed.deactivate()

        feed.activate()
        await waitUntil(state: "connection=\(feed.connection)") { feed.connection == .open }
        XCTAssertEqual(script.tasks.count, 2)
        feed.deactivate()
    }
}

/// What a feed's callbacks were handed, read after the fact.
@MainActor
final class FeedRecord {
    var opens = 0
    var events: [TelemetryEnvelope] = []
}
