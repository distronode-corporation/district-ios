@testable import DistrictAI
import DistrictModel
import XCTest

/// The HQ voice session against a fake room and a stub service: when it mints, what comes
/// before the microphone, how it ends, and how it shares the audio with calls and meetings.
final class HQVoiceSessionTests: HQVoiceSessionCase {
    // MARK: - Starting

    func testNothingIsMintedUntilTheMemberTaps() async {
        let session = makeSession()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(transport.count("voice-token"), 0)
        await session.start(history: [HQVoiceTurn(role: .user, text: "hello")], locale: "fr")
        XCTAssertEqual(transport.count("voice-token"), 1)
        XCTAssertTrue(transport.bodies("voice-token")[0].contains(#""locale":"fr""#))
    }

    func testTheNoticeComesBeforeTheMicrophone() async {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        guard case let .notice(credential) = session.phase else {
            return XCTFail("expected the region notice, got \(session.phase)")
        }
        XCTAssertEqual(credential.processingRegion, "us")
        XCTAssertNil(engine.joined, "nothing is joined before Start")
        XCTAssertEqual(engine.microphone, [])
        XCTAssertFalse(stack.hasLiveRoom)

        await session.begin()
        XCTAssertEqual(session.phase, .live)
        XCTAssertEqual(engine.joined?.url, "wss://hq.example.test")
        XCTAssertEqual(engine.joined?.token, "tok-secret")
        XCTAssertEqual(engine.microphone, [true], "an open mode opens the microphone at the join")
        XCTAssertTrue(session.isMicrophoneOn)
        XCTAssertTrue(stack.hasLiveRoom, "the session holds the room for its whole length")
    }

    func testCancelAtTheNoticeDiscardsAndJoinsNothing() async {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        await session.cancelNotice()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(transport.bodies("voice-discard"), [#"{"sessionId":"sess-secret","workspaceId":"ws1"}"#])
        XCTAssertNil(engine.joined)
    }

    func testStopEndsARunningSession() async {
        let session = makeSession()
        await goLive(session)
        await session.stop()
        XCTAssertEqual(session.phase, .ended(.byMember))
        XCTAssertEqual(transport.bodies("voice-end"), [#"{"sessionId":"sess-secret","workspaceId":"ws1"}"#])
        XCTAssertEqual(engine.disconnects, 1)
        XCTAssertFalse(stack.hasLiveRoom)
        XCTAssertEqual(discarded, 0)
    }

    func testStopAtTheNoticeIsCancel() async {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        await session.stop()
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(ended, 0)
    }

    func testTheAllowanceAnswerShowsTheServiceSentence() async {
        transport.reply("voice-token", 402, HQVoiceTransport.allowance)
        let session = makeSession()
        await session.start(history: [], locale: "en")
        guard case let .ended(.refused(message)) = session.phase else {
            return XCTFail("expected the allowance refusal, got \(session.phase)")
        }
        XCTAssertTrue(message.contains("120"), message)
        XCTAssertFalse(session.isActive, "the text console stays usable")
        XCTAssertNil(engine.joined)
    }

    func testAnUnjoinableCredentialIsAFailureNotAJoin() async {
        transport.reply("voice-token", 200, HQVoiceTransport.token().replacingOccurrences(of: "k3y", with: ""))
        let session = makeSession()
        await session.start(history: [], locale: "en")
        guard case .ended(.failed) = session.phase else {
            return XCTFail("a room without a key is never joined, got \(session.phase)")
        }
    }

    func testTheSessionEndsAtThirtyMinutes() async {
        let session = makeSession(timesOut: true)
        await goLive(session)
        let timedOut = await eventually { session.phase == .ended(.timedOut) }
        XCTAssertTrue(timedOut, "got \(session.phase)")
        XCTAssertEqual(slept, [HQVoice.sessionSeconds])
        let endSent = await eventually { ended == 1 }
        XCTAssertTrue(endSent, "the app ended it, so the service is told")
        XCTAssertEqual(HQVoice.sessionSeconds, 30 * 60)
    }

    func testAJoinFailureEndsAndReleasesTheRoom() async {
        engine.failsToJoin = true
        let session = makeSession()
        await goLive(session)
        XCTAssertEqual(session.phase, .ended(.failed(HQCopy.voiceJoinFailed)))
        XCTAssertFalse(stack.hasLiveRoom)
        XCTAssertEqual(discarded, 1, "a session that never went live is discarded")
        XCTAssertEqual(ended, 0)
    }

    func testADeniedMicrophoneMintsNothing() async {
        let session = makeSession(microphone: FakeMicrophoneAccess(status: .denied))
        await session.start(history: [], locale: "en")
        XCTAssertEqual(session.phase, .ended(.microphoneDenied))
        XCTAssertEqual(transport.count("voice-token"), 0)
    }

    // MARK: - Calls and meetings

    func testRefusedDuringACall() async {
        stack.onSystemRequest = { _ in }
        let session = makeSession()
        await session.start(history: [], locale: "en")
        XCTAssertEqual(session.phase, .ended(.busy))
        XCTAssertEqual(transport.count("voice-token"), 0, "nothing billed")
        XCTAssertEqual(HQVoiceBar.sentence(.busy), HQCopy.voiceBusy)
    }

    func testRefusedDuringAMeeting() async {
        let meeting = MeetingRoom()
        stack.claimRoom(meeting)
        let session = makeSession()
        await session.start(history: [], locale: "en")
        XCTAssertEqual(session.phase, .ended(.busy))
        XCTAssertTrue(stack.room === meeting, "the meeting keeps the audio")
    }

    func testACallRingingAtTheNoticeRefusesStart() async {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        stack.onSystemRequest = { _ in }
        await session.begin()
        XCTAssertEqual(session.phase, .ended(.busy))
        XCTAssertEqual(discarded, 1)
        XCTAssertNil(engine.joined)
    }

    func testARingEndsTheSession() async {
        let session = makeSession()
        await goLive(session)
        await stack.ringArrived()
        XCTAssertEqual(session.phase, .ended(.callArrived))
        XCTAssertEqual(HQVoiceBar.sentence(.callArrived), HQCopy.voiceEndedCall)
        XCTAssertFalse(stack.hasLiveRoom)
        XCTAssertEqual(engine.disconnects, 1)
        XCTAssertEqual(ended, 1)
    }

    /// ⚠️ A RING WHILE THE MICROPHONE IS STILL PUBLISHING: no clock and no screen report for a
    /// session that has already ended.
    func testARingDuringTheMicrophonePublishStartsNoClock() async {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        engine.holdsMicrophone = true
        let begin = Task { await session.begin() }
        _ = await eventually { engine.pendingMicrophone == 1 }
        await stack.ringArrived()
        engine.holdsMicrophone = false
        engine.releaseMicrophone()
        await begin.value
        XCTAssertEqual(session.phase, .ended(.callArrived))
        XCTAssertEqual(slept, [], "no 30-minute clock for an ended session")
        XCTAssertEqual(transport.count("voice-context"), 0)
    }

    func testARingLeavesAMeetingUpUntilTheAnswer() async {
        let meeting = MeetingRoom()
        stack.claimRoom(meeting)
        await stack.ringArrived()
        XCTAssertTrue(stack.room === meeting)
        XCTAssertEqual(meeting.yields, [])
    }

    func testAnAnsweredCallEndsTheSessionToo() async {
        let session = makeSession()
        await goLive(session)
        await stack.endRoom(.telephoneCall)
        XCTAssertEqual(session.phase, .ended(.callArrived))
    }

    func testASignOutEndsTheSession() async {
        let session = makeSession()
        await goLive(session)
        await stack.endRoom(.sessionEnded)
        XCTAssertEqual(session.phase, .ended(.byMember))
        XCTAssertEqual(engine.disconnects, 1)
    }
}

/// A meeting room on the call stack, for the overlap rules.
@MainActor
private final class MeetingRoom: RoomAudio {
    private(set) var yields: [RoomAudioYield] = []

    func yieldAudio(_ reason: RoomAudioYield) async {
        yields.append(reason)
    }
}
