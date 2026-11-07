@testable import DistrictAI
import DistrictModel
import XCTest

/// The HQ voice session while live: the microphone, what the room says, and the screen reports.
final class HQVoiceSessionLiveTests: HQVoiceSessionCase {
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

    /// ⛔ A QUICK PRESS AND RELEASE: the release waits for the open to finish, so the
    /// microphone is closed last and the screen says so.
    func testAReleaseDuringASlowOpenLeavesTheMicrophoneClosed() async {
        transport.reply("voice-token", 200, HQVoiceTransport.token(micMode: "push"))
        let session = makeSession()
        await goLive(session)
        engine.holdsMicrophone = true
        let press = Task { await session.holdToTalk(true) }
        _ = await eventually { engine.pendingMicrophone == 1 }
        let release = Task { await session.holdToTalk(false) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(engine.microphone, [true], "the release waits for the open")
        engine.holdsMicrophone = false
        engine.releaseMicrophone()
        await press.value
        await release.value
        XCTAssertEqual(engine.microphone, [true, false])
        XCTAssertFalse(session.isMicrophoneOn)
    }

    func testAPressOvertakenBeforeItRunsIsSkipped() async {
        transport.reply("voice-token", 200, HQVoiceTransport.token(micMode: "push"))
        let session = makeSession()
        await goLive(session)
        engine.holdsMicrophone = true
        let first = Task { await session.holdToTalk(true) }
        _ = await eventually { engine.pendingMicrophone == 1 }
        let second = Task { await session.holdToTalk(false) }
        let third = Task { await session.holdToTalk(true) }
        try? await Task.sleep(for: .milliseconds(50))
        engine.holdsMicrophone = false
        engine.releaseMicrophone()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(engine.microphone, [true, true], "the overtaken release never reached the room")
        XCTAssertTrue(session.isMicrophoneOn)
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
        let closed = await eventually { session.phase == .ended(.disconnected) }
        XCTAssertTrue(closed)
        XCTAssertFalse(stack.hasLiveRoom)
        XCTAssertEqual(ended + discarded, 0, "the service closed it: nothing to tell it")
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
