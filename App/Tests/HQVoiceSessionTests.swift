@testable import DistrictAI
import DistrictModel
import XCTest

/// The HQ voice session against a fake room and a stub service: when it mints, what comes
/// before the microphone, how it ends, and how it shares the audio with calls and meetings.
@MainActor
final class HQVoiceSessionTests: XCTestCase {
    private var transport = HQVoiceTransport()
    private var engine = FakeHQVoiceEngine()
    private var closing = RecordingHQVoiceClosing()
    private var stack = CallStack(microphone: FakeMicrophoneAccess(status: .granted))
    private var slept: [TimeInterval] = []

    override func setUp() async throws {
        transport = HQVoiceTransport()
        transport.reply("voice-token", 200, HQVoiceTransport.token())
        transport.reply("voice-context", 200, #"{"success":true}"#)
        engine = FakeHQVoiceEngine()
        closing = RecordingHQVoiceClosing()
        stack = CallStack(microphone: FakeMicrophoneAccess(status: .granted))
        slept = []
    }

    /// A session whose 30-minute clock never rings unless `timesOut`.
    private func makeSession(
        microphone: any MicrophoneAccess = FakeMicrophoneAccess(status: .granted),
        canConfirm: Bool = true,
        timesOut: Bool = false
    ) -> HQVoiceSession {
        let engine = engine
        return HQVoiceSession(
            workspaceId: "ws1",
            canConfirm: canConfirm,
            hq: transport.repository,
            callStack: stack,
            microphone: microphone,
            closing: closing,
            makeEngine: { _ in engine },
            sleep: { [weak self] seconds in
                await MainActor.run { self?.slept.append(seconds) }
                if !timesOut {
                    try await Task.sleep(for: .seconds(3600))
                }
            }
        )
    }

    private func goLive(_ session: HQVoiceSession) async {
        await session.start(history: [], locale: "en")
        await session.begin()
    }

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
        XCTAssertEqual(closing.discarded, ["sess-secret"])
        XCTAssertNil(engine.joined)
    }

    func testStopEndsARunningSession() async {
        let session = makeSession()
        await goLive(session)
        await session.stop()
        XCTAssertEqual(session.phase, .ended(.byMember))
        XCTAssertEqual(closing.ended, ["hq_ws1_abc"])
        XCTAssertEqual(engine.disconnects, 1)
        XCTAssertFalse(stack.hasLiveRoom)
        XCTAssertTrue(closing.discarded.isEmpty)
    }

    func testStopAtTheNoticeIsCancel() async {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        await session.stop()
        XCTAssertEqual(closing.discarded, ["sess-secret"])
        XCTAssertTrue(closing.ended.isEmpty)
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
        let ended = await eventually { session.phase == .ended(.timedOut) }
        XCTAssertTrue(ended, "got \(session.phase)")
        XCTAssertEqual(slept, [HQVoice.sessionSeconds])
        XCTAssertEqual(HQVoice.sessionSeconds, 30 * 60)
    }

    func testAJoinFailureEndsAndReleasesTheRoom() async {
        engine.failsToJoin = true
        let session = makeSession()
        await goLive(session)
        XCTAssertEqual(session.phase, .ended(.failed(HQCopy.voiceJoinFailed)))
        XCTAssertFalse(stack.hasLiveRoom)
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
        XCTAssertEqual(closing.discarded, ["sess-secret"])
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
        XCTAssertEqual(closing.ended, ["hq_ws1_abc"])
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

    // MARK: - The microphone

    func testPushStartsMuted() async {
        transport.reply("voice-token", 200, HQVoiceTransport.token(micMode: "push"))
        let session = makeSession()
        await goLive(session)
        XCTAssertEqual(session.phase, .live)
        XCTAssertEqual(session.micMode, .push)
        XCTAssertFalse(session.isMicrophoneOn, "push-to-talk is muted until held")
        XCTAssertEqual(engine.microphone, [], "the microphone is never opened at the join")

        await session.holdToTalk(true)
        XCTAssertTrue(session.isMicrophoneOn)
        await session.holdToTalk(false)
        XCTAssertFalse(session.isMicrophoneOn)
        XCTAssertEqual(engine.microphone, [true, false])
        await session.toggleMute()
        XCTAssertEqual(engine.microphone, [true, false], "push has no mute switch")
    }

    func testAnUnknownMicModeIsAnOpenMicrophoneWithAMuteSwitch() async {
        transport.reply("voice-token", 200, HQVoiceTransport.token(micMode: "whisper"))
        let session = makeSession()
        await goLive(session)
        XCTAssertEqual(session.micMode, .open)
        XCTAssertTrue(session.isMicrophoneOn)
        await session.toggleMute()
        XCTAssertFalse(session.isMicrophoneOn)
        await session.holdToTalk(true)
        XCTAssertEqual(engine.microphone, [true, false], "an open mode does not hold to talk")
    }

    // MARK: - What the room says

    func testOnlyFinalSegmentsAreKept() async {
        let session = makeSession()
        await goLive(session)
        engine.emit(.transcript(HQVoiceSegment(id: "s1", text: "Add a", isFinal: false, fromMember: true)))
        engine.emit(.transcript(HQVoiceSegment(id: "s1", text: "Add a note.", isFinal: true, fromMember: true)))
        engine.emit(.agentState(.thinking))
        let done = await eventually { session.agentState == .thinking }
        XCTAssertTrue(done)
        XCTAssertEqual(session.segments.map(\.text), ["Add a note."])
        XCTAssertEqual(session.segments.first?.fromMember, true)
    }

    func testAProposalAndItsVoiceResolution() async {
        let session = makeSession()
        await goLive(session)
        let proposal = HQVoiceProposal(proposalId: "p1", tool: "add_note", args: .object([:]), summary: "Add a note.")
        engine.emit(.packet(.proposal(proposal)))
        engine.emit(.packet(.proposal(proposal)))
        engine.emit(.packet(.resolved(HQVoiceResolution(
            proposalId: "p1", status: .applied, error: nil, joinCallId: nil
        ))))
        let resolved = await eventually { session.proposals.first?.outcome == .applied }
        XCTAssertTrue(resolved)
        XCTAssertEqual(session.proposals.count, 1, "a repeated proposal is one card")
    }

    func testCancelAProposalCallsTheCancelRoute() async {
        transport.reply("proposals/cancel", 200, #"{"success":true}"#)
        let session = makeSession()
        await goLive(session)
        engine.emit(.packet(.proposal(HQVoiceProposal(
            proposalId: "p2", tool: "add_note", args: .object([:]), summary: "Add a note."
        ))))
        _ = await eventually { !session.proposals.isEmpty }
        await session.cancel(session.proposals[0])
        XCTAssertEqual(session.proposals[0].outcome, .cancelled)
        XCTAssertTrue(transport.bodies("proposals/cancel").first?.contains(#""proposalId":"p2""#) == true)
    }

    func testAViewerCannotConfirm() async {
        let session = makeSession(canConfirm: false)
        await goLive(session)
        engine.emit(.packet(.proposal(HQVoiceProposal(
            proposalId: "p3", tool: "add_note", args: .object([:]), summary: "Add a note."
        ))))
        _ = await eventually { !session.proposals.isEmpty }
        await session.confirm(session.proposals[0])
        XCTAssertNil(session.proposals[0].outcome)
        XCTAssertEqual(transport.paths.filter { $0.hasSuffix("/hq") }, [])
    }

    func testTheRoomClosingEndsTheSession() async {
        let session = makeSession()
        await goLive(session)
        engine.emit(.disconnected)
        let ended = await eventually { session.phase == .ended(.disconnected) }
        XCTAssertTrue(ended)
        XCTAssertFalse(stack.hasLiveRoom)
    }

    // MARK: - Screen context

    func testEachNavigationIsReportedWhileLive() async {
        let session = makeSession()
        session.report(HQVoicePlace(.contacts))
        XCTAssertEqual(transport.count("voice-context"), 0, "nothing is reported before the session is live")
        await goLive(session)
        let first = await eventually { transport.count("voice-context") == 1 }
        XCTAssertTrue(first)
        XCTAssertTrue(transport.bodies("voice-context")[0].contains(#""contacts""#), "the place before the join")

        var paths = ShellPaths()
        paths.adopt("ws1")
        paths.setRegularSelection(.calls, workspaceId: "ws1", role: .agency)
        paths.setRegularPath([.callDetail(workspaceId: "ws1", callId: "call_42")], for: .calls)
        session.report(paths.hqVoicePlace)
        let second = await eventually { transport.count("voice-context") == 2 }
        XCTAssertTrue(second)
        let body = transport.bodies("voice-context")[1]
        XCTAssertTrue(body.contains(#""calls""#), body)
        XCTAssertTrue(body.contains("call_42"), body)
        XCTAssertTrue(body.contains("hq_ws1_abc"), body)

        await session.stop()
        session.report(HQVoicePlace(.inbox))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.count("voice-context"), 2, "nothing is reported once it ended")
    }

    func testTheSecretsAreNotInTheSessionDescription() async {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        let printed = "\(session.phase)"
        XCTAssertFalse(printed.contains("tok-secret"), printed)
        XCTAssertFalse(printed.contains("sess-secret"), printed)
        XCTAssertFalse(printed.contains("k3y"), printed)
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
