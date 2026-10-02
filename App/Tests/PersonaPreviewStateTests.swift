@testable import DistrictAI
import DistrictNetwork
import Foundation
import XCTest

/// The persona audition's state machine, arbitration and teardown.
///
/// ⛔ THE ONLY WAY ANY OF THIS IS CHECKED, BECAUSE THE REAL THING COSTS MONEY. Each
/// token is an invitation for the voice agent to join a room and start burning speech
/// and model minutes on the workspace's own pipeline; the route is capped at 10/min per
/// workspace and is not idempotent. "Start it and see" is not an available way to find
/// out whether a dismissed sheet leaves a microphone publishing.
///
/// ⚠️ WHAT IS PROVEN HERE IS THE MACHINE, NOT THE MEDIA. A fake engine cannot tell you
/// that audio flows, that the key derives the same AES key the agent derives, or that
/// the SDK's `@objc optional` delegate selectors match — all three need a device and a
/// real room. What it can tell you is that a call ends the session, that a failure
/// releases the audio claim, and that every exit path disconnects.
@MainActor
final class PersonaPreviewStateTests: XCTestCase {
    // MARK: - The happy path

    /// ⛔ CONNECTED IS NOT LIVE. The agent is dispatched into the room and takes a moment
    /// to arrive; telling somebody to start talking before it has would have them speak
    /// into a room nothing is listening to and conclude the persona is broken.
    func testItWaitsForTheAgentBeforeSayingTheAgentIsListening() async {
        let harness = Harness()
        await harness.model.start()
        XCTAssertEqual(harness.model.phase, .connecting)

        harness.engine.emit(.connected)
        await waitUntil { harness.model.phase == .waiting }
        XCTAssertEqual(harness.model.phase, .waiting)

        harness.engine.participants = [Harness.agent(level: 0)]
        harness.engine.emit(.rosterChanged)
        await waitUntil { harness.model.phase == .live }
        XCTAssertEqual(harness.model.phase, .live)
        XCTAssertTrue(harness.model.agentPresent)
    }

    /// ⚠️ THE MICROPHONE IS PUBLISHED ON THE JOIN, unlike a meeting. An audition joined
    /// muted is an audition of nothing.
    func testItPublishesTheMicrophoneAndPrefersTheSpeaker() async {
        let harness = Harness()
        await harness.model.start()
        XCTAssertTrue(harness.engine.microphoneRequests.contains(true))
        XCTAssertEqual(harness.engine.speakerRequests, [true])
        XCTAssertTrue(harness.model.micEnabled)
    }

    /// ⚠️ A DENIED MICROPHONE IS NOT FATAL AND IS NOT SILENT. The agent still greets and
    /// can be heard, which is worth keeping — but nothing will be heard back, and the
    /// screen says so.
    func testADeniedMicrophoneStillJoinsAndSaysWhy() async {
        let harness = Harness(microphoneGranted: false)
        await harness.model.start()
        XCTAssertTrue(harness.model.microphoneDenied)
        XCTAssertFalse(harness.model.micEnabled)
        XCTAssertTrue(harness.engine.microphoneRequests.isEmpty)
        XCTAssertEqual(harness.engine.connects.count, 1)
    }

    /// ⛔ THE PASSPHRASE REACHES THE SDK VERBATIM AND IS NEVER BASE64-DECODED. Every
    /// LiveKit SDK UTF-8-encodes this string and runs PBKDF2 over those ASCII bytes;
    /// decoding it first selects a different key, and the failure is not an error —
    /// both sides join and every track is noise.
    func testTheEncryptionKeyIsHandedToTheEngineUntouched() async {
        let harness = Harness()
        await harness.model.start()
        XCTAssertEqual(harness.keys, [Harness.e2eeKey])
    }

    /// ⚠️ AN EMPTY KEY IS NOT "no encryption": it would derive a real key nobody else in
    /// the room derives. nil is the honest answer when the server sent nothing usable.
    func testABlankEncryptionKeyIsNotForwarded() async {
        let harness =
            Harness(
                token: #"{"success":true,"token":"t","url":"wss://eu","roomName":"preview_1","e2ee":{"key":"   "}}"#
            )
        await harness.model.start()
        XCTAssertEqual(harness.keys, [nil])
    }

    /// ⚠️ THE LEVEL IS THE LOUDEST REMOTE PARTICIPANT, moved by the SFU's own speaker
    /// updates rather than by anybody joining or publishing.
    func testTheLevelFollowsTheSpeakerUpdates() async {
        let harness = Harness()
        await harness.model.start()
        harness.engine.participants = [Harness.agent(level: 0.42)]
        harness.engine.emit(.speakersChanged)
        await waitUntil { abs(harness.model.level - 0.42) < 0.0001 }
        XCTAssertEqual(harness.model.level, 0.42, accuracy: 0.0001)
    }

    // MARK: - Arbitration

    /// ⛔ ONE PROCESS OWNS ONE AUDIO SESSION. A preview during a call would put two
    /// owners on it, which is how a private customer call becomes audible somewhere else.
    func testItRefusesToStartWhileATelephoneCallIsLive() async {
        let harness = Harness()
        harness.callStack.onSystemRequest = { _ in }
        XCTAssertFalse(harness.model.canStart)
        await harness.model.start()
        XCTAssertEqual(harness.model.phase, .idle)
        XCTAssertTrue(harness.transport.paths.isEmpty, "a refused preview must not spend a rate-limit slot")
        XCTAssertEqual(harness.model.refusal, SettingsCopy.previewBusyCall)
    }

    /// ⛔ IT CLAIMS THE DEVICE'S AUDIO FOR THE LENGTH OF A SESSION, which is what makes
    /// the exclusion mutual: a dial and a room join both read that claim.
    func testItHoldsTheAudioClaimWhileRunningAndGivesItBackAfterwards() async {
        let harness = Harness()
        await harness.model.start()
        XCTAssertTrue(harness.callStack.hasLiveRoom)
        await harness.model.end()
        XCTAssertFalse(harness.callStack.hasLiveRoom)
    }

    /// ⛔ AN ARRIVING CALL ENDS THE PREVIEW RATHER THAN BEING REFUSED. Revenue arriving
    /// from somebody who cannot be told anything wins over an audition, and the operator
    /// is told which thing took it.
    func testAnArrivingCallEndsThePreviewThroughTheCallStack() async {
        let harness = Harness()
        await harness.model.start()
        await harness.callStack.endRoom(.telephoneCall)
        XCTAssertEqual(harness.model.phase, .ended(.yielded(.telephoneCall)))
        XCTAssertEqual(harness.engine.disconnects, 1)
        XCTAssertFalse(harness.callStack.hasLiveRoom)
    }

    // MARK: - Endings

    /// ⛔ A REMOTE DROP IS NOT "you stopped it". `end()` cancels the pump before it
    /// disconnects and sets the phase itself, so this branch is only ever a disconnect
    /// the operator did not cause.
    func testADisconnectNobodyAskedForIsReportedAsOne() async {
        let harness = Harness()
        await harness.model.start()
        harness.engine.emit(.disconnected(reason: "token expired"))
        await waitUntil { harness.model.phase == .ended(.droppedRemotely(reason: "token expired")) }
        XCTAssertEqual(harness.model.phase, .ended(.droppedRemotely(reason: "token expired")))
        XCTAssertFalse(harness.callStack.hasLiveRoom)
    }

    /// ⛔ THE TEARDOWN RUNS FROM EVERY STATE. A session that failed mid-call still holds
    /// an engine and a socket — the reducer sets the phase, it does not disconnect — so
    /// a dismissed sheet would otherwise leave a room publishing with nothing able to
    /// reach it.
    func testDismissingAfterAFailureStillDisconnects() async {
        let harness = Harness()
        await harness.model.start()
        harness.engine.emit(.failed(message: "media server refused"))
        await waitUntil { harness.model.phase == .failed }
        XCTAssertEqual(harness.model.phase, .failed)
        await harness.model.end()
        XCTAssertEqual(harness.engine.disconnects, 1)
    }

    /// ⛔ A FAILED MINT IS FINAL AND BUILDS NO ENGINE. The route is not idempotent and
    /// each token starts a billed session, so nothing here retries.
    func testARefusedMintFailsWithoutBuildingAnEngine() async {
        let harness = Harness(status: 429)
        await harness.model.start()
        XCTAssertEqual(harness.model.phase, .failed)
        XCTAssertNotNil(harness.model.failure)
        XCTAssertTrue(harness.keys.isEmpty)
        XCTAssertFalse(harness.callStack.hasLiveRoom)
    }

    /// ⛔ THE COOLDOWN IS THE ONLY THING BETWEEN A TWITCHY THUMB AND TEN BILLED SESSIONS
    /// A MINUTE, and it runs on a refusal too — which is the case it matters most in,
    /// since the commonest refusal is that very ceiling.
    func testTheStartControlStaysDisabledForAMomentAfterASession() async {
        let harness = Harness()
        await harness.model.start()
        await harness.model.end()
        XCTAssertTrue(harness.model.cooling)
        XCTAssertFalse(harness.model.canStart)
        XCTAssertEqual(harness.model.refusal, SettingsCopy.previewCooldown)

        await harness.model.cooldownTask?.value
        XCTAssertFalse(harness.model.cooling)
        XCTAssertTrue(harness.model.canStart)
    }

    /// ⚠️ A SECOND PRESS WHILE ONE IS RUNNING IS DROPPED, NOT QUEUED: it would tear down
    /// the media it just established and spend another slot doing it.
    func testASecondPressWhileRunningIsIgnored() async {
        let harness = Harness()
        await harness.model.start()
        await harness.model.start()
        XCTAssertEqual(harness.engine.connects.count, 1)
        XCTAssertEqual(harness.transport.paths.count, 1)
    }

    // ⚠️ THE PUMP IS A `Task`, so an emitted event has not been reduced when `emit`
    // returns, and `Task.yield()` alone is not a guarantee that another task on this actor
    // ran. Each test therefore waits, bounded, for the state it expects (`waitUntil`, in
    // WaitUntil.swift) rather than sleeping a fixed time.

    // MARK: - Harness

    /// ⚠️ ONE OBJECT SO EVERY TEST READS AS A SEQUENCE OF ACTS rather than as six lines
    /// of wiring. It is `@MainActor` because the model is.
    @MainActor
    private final class Harness {
        static let e2eeKey = "YfxKDUkaaGp2WrLLGHCHbe2nn5ArCWBd+x+k7EzDr/8="

        let transport: SettingsTransport
        let callStack = CallStack()
        let engine = FakePreviewEngine()
        /// ⚠️ A BOX RATHER THAN A PROPERTY ON THIS CLASS, because the factory is
        /// `@Sendable` and recording through an actor hop would let an assertion run
        /// before the value it is about was written.
        let keyBox = KeyBox()
        private(set) var model: PersonaPreviewModel!

        var keys: [String?] {
            keyBox.keys
        }

        init(
            token: String =
                #"{"success":true,"token":"t","url":"wss://eu","roomName":"preview_1","e2ee":{"key":"\#(Harness.e2eeKey)"}}"#,
            status: Int = 200,
            microphoneGranted: Bool = true
        ) {
            transport = SettingsTransport([token], status: status)
            let engine = engine
            model = PersonaPreviewModel(
                workspaces: .settingsTest(transport),
                workspaceId: "ws_1",
                form: PersonaPreviewForm(name: "Ada"),
                callStack: callStack,
                makeEngine: { [keyBox] key in
                    keyBox.keys.append(key)
                    return engine
                },
                // ⚠️ An immediate cooldown, awaited through `cooldownTask` rather than
                // slept through: a five-second wait in a unit test is five seconds of CI.
                cooldown: {},
                requestMicrophone: { microphoneGranted }
            )
        }

        static func agent(level: Double) -> RoomParticipantSnapshot {
            RoomParticipantSnapshot(
                identity: "agent-1",
                name: "District",
                isAgent: true,
                isMicrophoneEnabled: true,
                isSpeaking: level > 0,
                audioLevel: level,
                video: nil
            )
        }
    }
}

/// Somewhere to record what the engine factory was handed, from a `@Sendable` closure.
private final class KeyBox: @unchecked Sendable {
    var keys: [String?] = []
}

/// A media session that records what it was asked to do and emits what a test tells it
/// to.
///
/// ⚠️ `@unchecked Sendable` FOR THE REASON `RoomEngine` IS: the SDK's own seam is
/// nonisolated, so a fake standing in for it has to be too. Every property is touched
/// from the main actor by the tests above.
private final class FakePreviewEngine: PersonaPreviewEngine, @unchecked Sendable {
    let events: AsyncStream<RoomEngineEvent>
    private let continuation: AsyncStream<RoomEngineEvent>.Continuation

    private(set) var connects: [(url: String, token: String)] = []
    private(set) var disconnects = 0
    private(set) var microphoneRequests: [Bool] = []
    private(set) var speakerRequests: [Bool] = []
    /// ⚠️ NAMED FOR WHAT IT HOLDS RATHER THAN FOR THE METHOD, because Swift will not
    /// take a stored property and a method of the same base name on one type.
    var participants: [RoomParticipantSnapshot] = []

    init() {
        let (stream, continuation) = AsyncStream<RoomEngineEvent>.makeStream()
        events = stream
        self.continuation = continuation
    }

    func emit(_ event: RoomEngineEvent) {
        continuation.yield(event)
    }

    func connect(url: String, token: String) async throws {
        connects.append((url, token))
    }

    func disconnect() async {
        disconnects += 1
    }

    func setMicrophone(enabled: Bool) async -> Bool {
        microphoneRequests.append(enabled)
        return enabled
    }

    func setSpeakerphone(_ enabled: Bool) {
        speakerRequests.append(enabled)
    }

    func roster() -> [RoomParticipantSnapshot] {
        participants
    }
}
