@testable import DistrictAI
import DistrictModel
import XCTest

/// The lifecycle review of #115: a refused discard is ended, an agent that never joins or that
/// leaves ends the session, a sign-out ends voice while the credential is alive, the background
/// end is held by a background task and sent while the room disconnects, and a room that closes
/// during the join never goes live.
@MainActor
final class HQVoiceLifecycleReviewTests: HQVoiceSessionCase {
    /// Each sign-out deadline that ran out.
    var deadlinesRunOut: [TimeInterval] = []

    // MARK: - A refused or failed discard is ended

    /// ⛔ `discarded: false` (a row past 90 seconds) leaves it open for 30 minutes: it is ended.
    func testARefusedDiscardAtTheNoticeIsEnded() async {
        transport.reply("voice-discard", 200, #"{"success":true,"discarded":false}"#)
        let session = makeSession()
        await session.start(history: [], locale: "en")
        await session.cancelNotice()
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(ended, 1, "the service's end closes the row the discard left open")
        XCTAssertEqual(transport.bodies("voice-end"), transport.bodies("voice-discard"), "by the same session")
    }

    func testAFailedDiscardAfterAFailedJoinIsEnded() async {
        transport.reply("voice-discard", 503, #"{"success":false,"error":"unavailable"}"#)
        engine.failsToJoin = true
        let session = makeSession()
        await goLive(session)
        guard case .ended(.failed) = session.phase else { return XCTFail("got \(session.phase)") }
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(ended, 1)
    }

    func testARefusedDiscardWhenTheAudioIsBusyIsEnded() async {
        transport.reply("voice-discard", 200, #"{"success":true,"discarded":false}"#)
        let session = makeSession()
        await session.start(history: [], locale: "en")
        stack.claimRoom(MeetingRoom())
        await session.begin()
        XCTAssertEqual(session.phase, .ended(.busy))
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(ended, 1)
    }

    /// ⛔ A STOP WHILE THE TOKEN MINTS: the token that arrives late is discarded, and ended when
    /// the discard is refused.
    func testALateTokenWithARefusedDiscardIsEnded() async {
        transport.reply("voice-discard", 200, #"{"success":true,"discarded":false}"#)
        transport.hold("voice-token")
        let session = makeSession()
        let starting = Task { await session.start(history: [], locale: "en") }
        let minting = await eventually { transport.isHolding }
        XCTAssertTrue(minting)
        XCTAssertEqual(session.phase, .minting)
        await session.stop()
        transport.release()
        await starting.value
        XCTAssertEqual(session.phase, .ended(.byMember))
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(ended, 1)
        XCTAssertNil(engine.joined)
    }

    func testADiscardTheServiceAcceptedIsNotEnded() async {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        await session.cancelNotice()
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(ended, 0)
    }

    // MARK: - The agent-join window and the agent leaving

    /// ⛔ NO AGENT WITHIN 20 SECONDS: discarded, not ended, in the service's busy words.
    func testNoAgentWithinTheWindowDiscardsTheSession() async {
        let session = makeSession(agentNeverJoins: true)
        await goLive(session)
        let gone = await eventually { session.phase == .ended(.noAgent) && discarded == 1 }
        XCTAssertTrue(gone, "got \(session.phase)")
        XCTAssertEqual(waitedForAgent, [HQVoiceSession.agentJoinSeconds])
        XCTAssertEqual(HQVoiceSession.agentJoinSeconds, 20)
        XCTAssertEqual(ended, 0)
        XCTAssertFalse(engine.isConnected)
        XCTAssertFalse(session.isMicrophoneOn)
        XCTAssertFalse(stack.hasLiveRoom)
        XCTAssertEqual(HQVoiceBar.sentence(.noAgent), HQCopy.voiceNoAgent)
        XCTAssertTrue(HQVoiceBar.isFailure(.noAgent))
    }

    func testNoAgentWithARefusedDiscardIsEnded() async {
        transport.reply("voice-discard", 200, #"{"success":true,"discarded":false}"#)
        let session = makeSession(agentNeverJoins: true)
        await goLive(session)
        let gone = await eventually { discarded == 1 && ended == 1 }
        XCTAssertTrue(gone, "got discard \(discarded), end \(ended)")
        XCTAssertEqual(session.phase, .ended(.noAgent))
    }

    /// ⚠️ THE WINDOW OPENS IN ITS OWN TASK, so the test waits for it to open before the agent
    /// speaks: asserted straight after the join, it raced that task (CI run 42437605874).
    func testTheAgentsFirstStateClosesTheWindow() async {
        let session = makeSession()
        await goLive(session)
        let opened = await eventually { waitedForAgent == [HQVoiceSession.agentJoinSeconds] }
        XCTAssertTrue(opened, "got \(waitedForAgent)")
        engine.emit(.agentState(.listening))
        let closed = await eventually { agentWaitsCancelled == 1 }
        XCTAssertTrue(closed)
        XCTAssertEqual(session.phase, .live)
    }

    /// ⚠️ AN AGENT WHOSE STATE ARRIVED DURING THE JOIN HAS JOINED: no window opens.
    func testAnAgentAlreadyInTheRoomOpensNoWindow() async {
        engine.holdsConnect = true
        let session = makeSession(agentNeverJoins: true)
        await session.start(history: [], locale: "en")
        let joining = Task { await session.begin() }
        _ = await eventually { engine.isConnectPending }
        engine.emit(.agentState(.listening))
        _ = await eventually { session.agentState == .listening }
        engine.releaseConnect()
        await joining.value
        XCTAssertEqual(session.phase, .live)
        XCTAssertEqual(waitedForAgent, [])
    }

    /// ⛔ THE AGENT LEAVING ENDS THE SESSION, AND THE SERVICE IS TOLD (from an uncancelled task).
    func testTheAgentLeavingEndsTheSession() async {
        let session = makeSession()
        await goLive(session)
        engine.emit(.agentLeft)
        let gone = await eventually { session.phase == .ended(.agentLeft) && ended == 1 }
        XCTAssertTrue(gone, "got \(session.phase), end \(ended)")
        XCTAssertEqual(discarded, 0)
        XCTAssertFalse(engine.isConnected)
        XCTAssertFalse(stack.hasLiveRoom)
        XCTAssertEqual(HQVoiceBar.sentence(.agentLeft), HQCopy.voiceEnded)
        XCTAssertFalse(HQVoiceBar.isFailure(.agentLeft))
    }

    // MARK: - A room that closes during the join

    /// ⛔ A ROOM DELETED MID-JOIN NEVER GOES LIVE, and the session is discarded.
    func testADisconnectDuringTheJoinNeverGoesLive() async {
        engine.holdsConnect = true
        let session = makeSession()
        await session.start(history: [], locale: "en")
        let joining = Task { await session.begin() }
        _ = await eventually { engine.isConnectPending }
        engine.emit(.disconnected)
        let failed = await eventually { session.phase == .ended(.failed(VoiceFailure.joinFailed)) }
        XCTAssertTrue(failed, "got \(session.phase)")
        engine.releaseConnect()
        await joining.value
        XCTAssertEqual(session.phase, .ended(.failed(VoiceFailure.joinFailed)))
        XCTAssertFalse(engine.isConnected)
        XCTAssertTrue(engine.microphone.isEmpty)
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(ended, 0)
        XCTAssertFalse(stack.hasLiveRoom)
    }

    // MARK: - The background end

    /// ⛔ THE END IS SENT WHILE THE ROOM DISCONNECTS, under a background task held until both are done.
    func testTheBackgroundEndIsSentWhileTheRoomDisconnectsUnderABackgroundTask() async {
        let tasks = FakeBackgroundTasks()
        let session = makeSession()
        stack.hqVoice = session
        await goLive(session)
        engine.holdsDisconnect = true
        let ending = Task { await stack.endVoiceSessionInBackground(on: tasks) }
        let sent = await eventually { ended == 1 && engine.isDisconnectPending }
        XCTAssertTrue(sent, "the end does not wait for the room")
        XCTAssertEqual(tasks.begun.count, 1)
        XCTAssertEqual(tasks.ended, [], "the background task is held while the room disconnects")
        engine.releaseDisconnect()
        await ending.value
        XCTAssertEqual(tasks.ended, tasks.begun)
        XCTAssertEqual(session.phase, .ended(.byMember))
        XCTAssertFalse(engine.isConnected)
    }

    func testTheBackgroundEndWithNoSessionTakesNoBackgroundTime() async {
        let tasks = FakeBackgroundTasks()
        await stack.endVoiceSessionInBackground(on: tasks)
        XCTAssertEqual(tasks.begun, [])
    }

    // MARK: - Sign-out

    /// ⛔ THE SIGN-OUT ENDS LIVE VOICE ITSELF, before the revoke (``SessionModel/signOut()``).
    func testTheSignOutEndsLiveVoice() async throws {
        let container = try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://calls.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted)
        )
        let session = makeSession()
        container.callStack.hqVoice = session
        await goLive(session)
        container.callStack.voiceEndDeadline = Self.noVoiceEndDeadline
        let model = SessionModel(container: container, push: PushRegistrar(container: container))
        await model.signOut()
        XCTAssertEqual(session.phase, .ended(.byMember))
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(engine.isConnected)
    }

    /// ⛔ A STALLED END DOES NOT HOLD THE REVOKE (Seer, PR #115): the sign-out stops waiting at
    /// the deadline, signs out, and the end it left running is still sent.
    func testAStalledVoiceEndDoesNotHoldTheSignOut() async throws {
        let container = try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://calls.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted)
        )
        let session = makeSession()
        container.callStack.hqVoice = session
        await goLive(session)
        transport.hold("voice-end")
        // The deadline runs out only once the end is stalled in flight: ordered, no clock.
        let transport = transport
        container.callStack.voiceEndDeadline = { [weak self] seconds in
            while !transport.isHolding {
                await Task.yield()
            }
            await MainActor.run { self?.deadlinesRunOut.append(seconds) }
        }
        let model = SessionModel(container: container, push: PushRegistrar(container: container))
        await model.signOut()
        XCTAssertEqual(deadlinesRunOut, [CallStack.voiceEndSeconds])
        XCTAssertEqual(CallStack.voiceEndSeconds, 3)
        guard case .signedOut = model.phase else { return XCTFail("got \(model.phase)") }
        XCTAssertTrue(transport.isHolding, "the end is still in flight after the sign-out")
        XCTAssertEqual(ended, 0)
        transport.release()
        let sent = await eventually { ended == 1 && session.phase == .ended(.byMember) }
        XCTAssertTrue(sent, "the end the sign-out stopped waiting for is still sent, got \(session.phase)")
    }

    /// ⛔ A SIGN-OUT WHILE THE TOKEN MINTS WAITS FOR IT AND GIVES IT BACK (#116): the discard
    /// goes out with the credential, before the sign-out finishes, not after the revoke.
    func testTheSignOutDuringTheMintDiscardsTheSessionFirst() async throws {
        let container = try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://calls.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted)
        )
        let session = makeSession()
        container.callStack.hqVoice = session
        container.callStack.voiceEndDeadline = Self.noVoiceEndDeadline
        transport.hold("voice-token")
        let starting = Task { await session.start(history: [], locale: "en") }
        let minting = await eventually { transport.isHolding }
        XCTAssertTrue(minting)
        let model = SessionModel(container: container, push: PushRegistrar(container: container))
        let signingOut = Task { await model.signOut() }
        let waiting = await eventually { model.isBusy && session.phase == .idle }
        XCTAssertTrue(waiting, "the sign-out reached the voice end, got \(session.phase)")
        if case .signedOut = model.phase {
            XCTFail("the sign-out did not wait for the token in flight")
        }
        XCTAssertEqual(discarded, 0)
        transport.release()
        await signingOut.value
        await starting.value
        guard case .signedOut = model.phase else { return XCTFail("got \(model.phase)") }
        XCTAssertEqual(discarded, 1, "discarded before the sign-out finished")
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(transport.authorizations("voice-discard"), ["Bearer session-token"])
        XCTAssertTrue(try XCTUnwrap(transport.bodies("voice-discard").first).contains("sess-secret"))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(engine.joined)
    }

    /// ⛔ A REFUSED DISCARD DURING THE SIGN-OUT FALLS BACK TO THE END, also before it finishes.
    func testTheSignOutDuringTheMintEndsARefusedDiscard() async throws {
        let container = try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://calls.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted)
        )
        transport.reply("voice-discard", 200, #"{"success":true,"discarded":false}"#)
        let session = makeSession()
        container.callStack.hqVoice = session
        container.callStack.voiceEndDeadline = Self.noVoiceEndDeadline
        transport.hold("voice-token")
        let starting = Task { await session.start(history: [], locale: "en") }
        let minting = await eventually { transport.isHolding }
        XCTAssertTrue(minting)
        let model = SessionModel(container: container, push: PushRegistrar(container: container))
        let signingOut = Task { await model.signOut() }
        let waiting = await eventually { model.isBusy && session.phase == .idle }
        XCTAssertTrue(waiting)
        transport.release()
        await signingOut.value
        await starting.value
        guard case .signedOut = model.phase else { return XCTFail("got \(model.phase)") }
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(ended, 1, "ended before the sign-out finished")
        XCTAssertEqual(transport.authorizations("voice-end"), ["Bearer session-token"])
    }

    /// ⛔ A MINT THAT STALLS PAST THE DEADLINE DOES NOT HOLD THE SIGN-OUT: it finishes at the
    /// deadline, and the token that arrives later is still given back.
    func testAStalledMintDoesNotHoldTheSignOut() async throws {
        let container = try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://calls.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted)
        )
        let session = makeSession()
        container.callStack.hqVoice = session
        transport.hold("voice-token")
        let starting = Task { await session.start(history: [], locale: "en") }
        let minting = await eventually { transport.isHolding }
        XCTAssertTrue(minting)
        // The deadline runs out only once the sign-out is waiting on the stalled mint.
        container.callStack.voiceEndDeadline = { [weak self] seconds in
            while await MainActor.run(body: { session.phase != .idle }) {
                await Task.yield()
            }
            await MainActor.run { self?.deadlinesRunOut.append(seconds) }
        }
        let model = SessionModel(container: container, push: PushRegistrar(container: container))
        await model.signOut()
        XCTAssertEqual(deadlinesRunOut, [CallStack.voiceEndSeconds])
        guard case .signedOut = model.phase else { return XCTFail("got \(model.phase)") }
        XCTAssertTrue(transport.isHolding, "the mint is still in flight after the sign-out")
        XCTAssertEqual(discarded, 0)
        transport.release()
        await starting.value
        let sent = await eventually { discarded == 1 }
        XCTAssertTrue(sent, "the late token is still discarded")
        XCTAssertEqual(session.phase, .idle)
    }

    func testTheSignOutEndsVoiceBeforeTheRevoke() throws {
        let source = try SourceScan.stripComments(String(
            contentsOf: SourceScan.sourceRoot().appendingPathComponent("Session/SessionModel.swift"),
            encoding: .utf8
        ))
        let body = try XCTUnwrap(source.components(separatedBy: "func signOut() async {").dropFirst().first)
        let voice = try XCTUnwrap(body.range(of: "await container.callStack.endVoiceSession()"))
        let revoke = try XCTUnwrap(body.range(of: "await container.signOut("))
        XCTAssertLessThan(voice.lowerBound, revoke.lowerBound)
    }
}
