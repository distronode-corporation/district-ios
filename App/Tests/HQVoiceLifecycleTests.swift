@testable import DistrictAI
import DistrictModel
import XCTest

/// A session replaced, sent to the background or stopped mid-join: the room disconnects, the
/// microphone stops, no notice is left up, and the service hears once.
@MainActor
final class HQVoiceLifecycleTests: HQVoiceSessionCase {
    private func container() throws -> AppContainer {
        try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://calls.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted)
        )
    }

    /// ⛔ SEER, ROUND 7 ON #113: another workspace's screen ends the session it replaces.
    func testAReplacedSessionAtTheNoticeIsDiscarded() async throws {
        let container = try container()
        let session = makeSession()
        container.callStack.hqVoice = session
        await session.start(history: [], locale: "en")
        guard case .notice = session.phase else { return XCTFail("got \(session.phase)") }
        let other = HQVoiceSession.forScreen(container: container, workspaceId: "ws2", role: .agency)
        XCTAssertFalse(other === session)
        XCTAssertTrue(container.callStack.hqVoice === other)
        let gone = await eventually { discarded == 1 }
        XCTAssertTrue(gone, "the replaced session's token is discarded")
        XCTAssertEqual(session.phase, .idle, "no region notice is left up")
        XCTAssertNil(engine.joined)
    }

    func testAReplacedLiveSessionIsEndedOnce() async throws {
        let container = try container()
        let session = makeSession()
        container.callStack.hqVoice = session
        await goLive(session)
        XCTAssertTrue(session.isMicrophoneOn)
        _ = HQVoiceSession.forScreen(container: container, workspaceId: "ws2", role: .agency)
        let gone = await eventually { session.phase == .ended(.byMember) && ended == 1 }
        XCTAssertTrue(gone, "got \(session.phase)")
        XCTAssertFalse(engine.isConnected)
        XCTAssertFalse(session.isMicrophoneOn)
        XCTAssertFalse(stack.hasLiveRoom)
        XCTAssertEqual(discarded, 0)
    }

    /// ⛔ THE BACKGROUND ENDS LIVE VOICE, ONCE, THROUGH THE CALL STACK.
    func testTheBackgroundEndsALiveSessionOnce() async {
        let session = makeSession()
        stack.hqVoice = session
        await goLive(session)
        await stack.endVoiceSession()
        await stack.endVoiceSession()
        XCTAssertEqual(session.phase, .ended(.byMember))
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(discarded, 0)
        XCTAssertEqual(engine.disconnects, 1)
        XCTAssertFalse(engine.isConnected)
        XCTAssertFalse(session.isMicrophoneOn)
        XCTAssertFalse(stack.hasLiveRoom)
    }

    /// A session sent to the background at its notice comes back with no notice.
    func testTheBackgroundAtTheNoticeDiscardsAndLeavesNoNotice() async {
        let session = makeSession()
        stack.hqVoice = session
        await session.start(history: [], locale: "en")
        await stack.endVoiceSession()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(ended, 0)
        XCTAssertNil(engine.joined)
    }

    func testTheBackgroundWithNoSessionDoesNothing() async {
        let session = makeSession()
        stack.hqVoice = session
        await stack.endVoiceSession()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(transport.count("voice-token"), 0)
        XCTAssertEqual(discarded + ended, 0)
    }

    /// ⛔ A STOP DURING A SLOW JOIN: the connect that completes afterwards is disconnected, and a
    /// session that never went live is discarded, not ended.
    func testAStopDuringTheJoinLeavesNoRoomJoined() async {
        engine.holdsConnect = true
        let session = makeSession()
        await session.start(history: [], locale: "en")
        let joining = Task { await session.begin() }
        let pending = await eventually { engine.isConnectPending }
        XCTAssertTrue(pending)
        await session.stop()
        engine.releaseConnect()
        await joining.value
        XCTAssertEqual(session.phase, .ended(.byMember))
        XCTAssertNotNil(engine.joined, "the connect did complete")
        XCTAssertFalse(engine.isConnected, "and was disconnected after it")
        XCTAssertTrue(engine.microphone.isEmpty, "the microphone never opened")
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(ended, 0)
        XCTAssertFalse(stack.hasLiveRoom)
    }
}
