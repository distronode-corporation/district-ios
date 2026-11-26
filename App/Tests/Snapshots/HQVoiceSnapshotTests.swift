@testable import DistrictAI
import DistrictL10n
import DistrictModel
import SwiftUI
import XCTest

/// District HQ by voice: the bar above the console in each phase of a session, the region notice,
/// and the voice settings sheet. Each session is driven by the real ``HQVoiceSession`` over a stub
/// service and a fake room (``HQVoiceTransport``, ``FakeHQVoiceEngine``), as the session's own
/// tests drive it; the bar draws whatever the session says.
final class HQVoiceSnapshotTests: ScreenSnapshotTestCase {
    private var transport = HQVoiceTransport()
    private var engine = FakeHQVoiceEngine()
    private var stack = CallStack(microphone: FakeMicrophoneAccess(status: .granted))
    private var sessions: [HQVoiceSession] = []

    override func setUp() async throws {
        try await super.setUp()
        transport = HQVoiceTransport()
        transport.reply("voice-token", 200, HQVoiceTransport.token())
        transport.reply("voice-context", 200, #"{"success":true}"#)
        transport.reply("voice-end", 200, #"{"success":true,"ended":true}"#)
        transport.reply("voice-discard", 200, #"{"success":true,"discarded":true}"#)
        engine = FakeHQVoiceEngine()
        stack = CallStack(microphone: FakeMicrophoneAccess(status: .granted))
        stack.voiceEndDeadline = { _ in try? await Task.sleep(for: .seconds(3600)) }
        sessions = []
    }

    override func tearDown() async throws {
        engine.releaseConnect()
        for session in sessions {
            await session.stop()
        }
        try await super.tearDown()
    }

    /// A session whose clocks never ring on their own.
    private func makeSession(
        microphone: any MicrophoneAccess = FakeMicrophoneAccess(status: .granted),
        canConfirm: Bool = true
    ) -> HQVoiceSession {
        let engine = engine
        let session = HQVoiceSession(
            workspaceId: "ws1",
            canConfirm: canConfirm,
            hq: transport.repository,
            callStack: stack,
            microphone: microphone,
            makeEngine: { _ in engine },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            waitForAgent: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        sessions.append(session)
        return session
    }

    private func assertBar(
        _ session: HQVoiceSession,
        locales: [L10nLocale] = [.en, .frCA],
        testName: String = #function,
        line: UInt = #line
    ) async throws {
        try await assertScreen(devices: [.iPhone], locales: locales, testName: testName, line: line) { _ in
            VStack {
                HQVoiceBar(session: session, history: { [] }, openSettings: {})
                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Not in a session

    /// Before Talk: the microphone explainer.
    func testIdle() async throws {
        try await assertBar(makeSession())
    }

    /// The microphone permission was refused: said as a failure, Talk still offered.
    func testEndedMicrophoneDenied() async throws {
        let session = makeSession(microphone: FakeMicrophoneAccess(status: .denied))
        await session.start(history: [], locale: "en")
        XCTAssertEqual(session.phase, .ended(.microphoneDenied))
        try await assertBar(session)
    }

    /// The month's voice minutes are spent: the service's own sentence.
    func testEndedAllowanceReached() async throws {
        transport.reply("voice-token", 429, HQVoiceTransport.allowance)
        let session = makeSession()
        await session.start(history: [], locale: "en")
        guard case .ended(.refused) = session.phase else {
            return XCTFail("expected the allowance refusal, got \(session.phase)")
        }
        try await assertBar(session)
    }

    /// Ended by the member: the plain sentence, not a failure.
    func testEndedByMember() async throws {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        await session.begin()
        XCTAssertEqual(session.phase, .live)
        await session.stop()
        XCTAssertEqual(session.phase, .ended(.byMember))
        try await assertBar(session)
    }

    // MARK: - Starting

    /// Joining the room: the spinner and Stop.
    func testConnecting() async throws {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        engine.holdsConnect = true
        Task { await session.begin() }
        let pending = await eventually { self.engine.isConnectPending }
        XCTAssertTrue(pending)
        XCTAssertEqual(session.phase, .connecting)
        try await assertBar(session)
    }

    /// The region notice for a workspace whose voice is processed in another region.
    func testNoticeOtherRegion() async throws {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        guard case let .notice(credential) = session.phase else {
            return XCTFail("expected the notice, got \(session.phase)")
        }
        try await assertScreen(devices: [.iPhone]) { _ in
            HQVoiceNotice(
                session: session,
                regionLine: HQVoiceNotice.regionLine(processing: credential.processingRegion, workspace: "ca")
            )
        }
    }

    /// The notice where the voice is processed in the workspace's own region: no region line.
    func testNoticeSameRegion() async throws {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        guard case .notice = session.phase else {
            return XCTFail("expected the notice, got \(session.phase)")
        }
        try await assertScreen(devices: [.iPhone], locales: [.en]) { _ in
            HQVoiceNotice(session: session, regionLine: nil)
        }
    }

    // MARK: - Live

    /// Live with an open microphone: listening, the mute switch, the last turns of the transcript.
    func testLiveTranscript() async throws {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        await session.begin()
        engine.emit(.transcript(HQVoiceSegment(
            id: "s1",
            text: "Add a note to the Ortiz call.",
            isFinal: true,
            fromMember: true
        )))
        engine.emit(.transcript(HQVoiceSegment(
            id: "s2",
            text: "Which call do you mean?",
            isFinal: true,
            fromMember: false
        )))
        engine.emit(.agentState(.speaking))
        let done = await eventually { session.agentState == .speaking && session.segments.count == 2 }
        XCTAssertTrue(done)
        try await assertBar(session)
    }

    /// Push to talk: the hold-to-talk control, the microphone closed, HQ thinking.
    func testLivePushToTalk() async throws {
        transport.reply("voice-token", 200, HQVoiceTransport.token(micMode: "push"))
        let session = makeSession()
        await session.start(history: [], locale: "en")
        await session.begin()
        engine.emit(.agentState(.thinking))
        let done = await eventually { session.agentState == .thinking }
        XCTAssertTrue(done)
        XCTAssertFalse(session.isMicrophoneOn)
        try await assertBar(session)
    }

    /// A proposal waiting for Confirm, and one HQ already applied.
    func testLiveProposals() async throws {
        let session = makeSession()
        await session.start(history: [], locale: "en")
        await session.begin()
        engine.emit(.packet(.proposal(HQVoiceProposal(
            proposalId: "p1", tool: "add_note", args: .object([:]), summary: "Add a note to the Ortiz call."
        ))))
        engine.emit(.packet(.proposal(HQVoiceProposal(
            proposalId: "p2", tool: "block_contact", args: .object([:]), summary: "Block +1 416 555 0199."
        ))))
        engine.emit(.packet(.resolved(HQVoiceResolution(
            proposalId: "p2", status: .applied, error: nil, joinCallId: nil
        ))))
        let done = await eventually { session.proposals.count == 2 && session.proposals[1].outcome == .applied }
        XCTAssertTrue(done)
        try await assertBar(session)
    }

    /// A viewer's proposal: HQ may propose, but Confirm is not offered.
    func testLiveProposalViewer() async throws {
        let session = makeSession(canConfirm: false)
        await session.start(history: [], locale: "en")
        await session.begin()
        engine.emit(.packet(.proposal(HQVoiceProposal(
            proposalId: "p3", tool: "add_note", args: .object([:]), summary: "Add a note to the Ortiz call."
        ))))
        let done = await eventually { !session.proposals.isEmpty }
        XCTAssertTrue(done)
        try await assertBar(session, locales: [.en])
    }

    // MARK: - Settings

    /// The recorded voice settings.
    func testSettings() async throws {
        let body = try XCTUnwrap(String(
            bytes: FixtureTransport.fixtureData("district-hq-voice-settings"),
            encoding: .utf8
        ))
        transport.reply("voice-settings", 200, body)
        let model = HQVoiceSettingsModel(hq: transport.repository, workspaceId: "ws1")
        await model.load()
        XCTAssertNotNil(model.draft)
        try await assertScreen { _ in HQVoiceSettingsView(model: model) }
    }

    /// The settings could not be read.
    func testSettingsLoadFailed() async throws {
        transport.reply("voice-settings", 500, #"{"error":"Something went wrong."}"#)
        let model = HQVoiceSettingsModel(hq: transport.repository, workspaceId: "ws1")
        await model.load()
        XCTAssertNotNil(model.loadFailure)
        try await assertScreen(devices: [.iPhone]) { _ in HQVoiceSettingsView(model: model) }
    }
}

/// The bar's words for each way a session ends, and which of them are failures.
@MainActor
final class HQVoiceBarWordingTests: XCTestCase {
    func testEveryEndHasItsSentence() {
        XCTAssertEqual(HQVoiceBar.sentence(.byMember), HQCopy.voiceEnded)
        XCTAssertEqual(HQVoiceBar.sentence(.disconnected), HQCopy.voiceEnded)
        XCTAssertEqual(HQVoiceBar.sentence(.agentLeft), HQCopy.voiceEnded)
        XCTAssertEqual(HQVoiceBar.sentence(.callArrived), HQCopy.voiceEndedCall)
        XCTAssertEqual(HQVoiceBar.sentence(.timedOut), HQCopy.voiceEndedTimeout)
        XCTAssertEqual(HQVoiceBar.sentence(.busy), HQCopy.voiceBusy)
        XCTAssertEqual(HQVoiceBar.sentence(.noAgent), HQCopy.voiceNoAgent)
        XCTAssertEqual(HQVoiceBar.sentence(.microphoneDenied), HQCopy.voiceMicDenied)
        XCTAssertEqual(HQVoiceBar.sentence(.refused("The minutes are spent.")), "The minutes are spent.")
        XCTAssertEqual(HQVoiceBar.sentence(.failed("")), "", "the service's sentence, even an empty one")
    }

    func testOnlyARefusalOrAFaultIsAFailure() {
        for reason: HQVoiceSession.EndReason in [.byMember, .disconnected, .agentLeft, .callArrived, .timedOut] {
            XCTAssertFalse(HQVoiceBar.isFailure(reason), "\(reason)")
        }
        for reason: HQVoiceSession.EndReason in [.busy, .noAgent, .microphoneDenied, .refused("x"), .failed("x")] {
            XCTAssertTrue(HQVoiceBar.isFailure(reason), "\(reason)")
        }
    }

    func testTheRegionLineOnlyWhenTheRegionsDiffer() {
        XCTAssertNil(HQVoiceNotice.regionLine(processing: "us", workspace: "us"))
        XCTAssertNil(HQVoiceNotice.regionLine(processing: "us", workspace: nil), "no workspace region, no claim")
        XCTAssertEqual(
            HQVoiceNotice.regionLine(processing: "us", workspace: "ca"),
            HQCopy.voiceNoticeRegion(RegionCopy.label("ca"))
        )
    }

    func testTheAgentIsAskedInTheAppsLanguage() {
        L10nRuntime.locale = .frCA
        defer { L10nRuntime.locale = .en }
        XCTAssertEqual(HQVoiceBar.locale, "fr")
        L10nRuntime.locale = .en
        XCTAssertEqual(HQVoiceBar.locale, "en")
    }
}
