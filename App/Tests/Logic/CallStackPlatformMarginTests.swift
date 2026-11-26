@testable import DistrictAI
import UIKit
import XCTest

/// The parts of ``CallStack`` that hold no CallKit call and no LiveKit room: who owns the
/// device's audio, what a workspace switch and a ring end, and how the HQ voice session is
/// ended in the foreground and in the background. ⚠️ `beginCall` and `perform` build a LiveKit
/// engine and are not exercised here.
@MainActor
final class CallStackPlatformMarginTests: XCTestCase {
    private func makeStack() -> CallStack {
        CallStack(microphone: FakeMicrophoneAccess(status: .granted))
    }

    // MARK: - CallTeardown

    func testOnlyAMoveBetweenTwoKnownWorkspacesIsASwitch() {
        XCTAssertTrue(CallTeardown.isWorkspaceSwitch(from: "ws_a", to: "ws_b"))
        XCTAssertFalse(CallTeardown.isWorkspaceSwitch(from: "ws_a", to: "ws_a"))
        XCTAssertFalse(CallTeardown.isWorkspaceSwitch(from: nil, to: "ws_a"), "the first selection")
        XCTAssertFalse(CallTeardown.isWorkspaceSwitch(from: "ws_a", to: nil), "no workspace yet")
        XCTAssertFalse(CallTeardown.isWorkspaceSwitch(from: nil, to: nil))
        XCTAssertTrue(CallTeardown.isWorkspaceSwitch(from: "", to: "ws_a"), "an empty id is still an id")
        XCTAssertTrue(CallTeardown.isWorkspaceSwitch(from: "ws_A", to: "ws_a"), "ids are compared exactly")
    }

    // MARK: - The room claim

    func testOnlyTheOwnerReleasesTheRoom() {
        let stack = makeStack()
        let owner = MarginRoom()
        let other = MarginRoom()
        stack.claimRoom(owner)

        stack.releaseRoom(other)
        XCTAssertTrue(stack.hasLiveRoom, "a stranger cannot release another's room")

        stack.releaseRoom(owner)
        XCTAssertFalse(stack.hasLiveRoom)
        XCTAssertEqual(owner.yields, [], "a release is not a yield")
    }

    func testEndingWithNoRoomIsHarmless() async {
        let stack = makeStack()
        await stack.endRoom(.telephoneCall)
        await stack.ringArrived()
        XCTAssertFalse(stack.hasLiveRoom)
    }

    /// ⚠️ A meeting keeps its audio through the ring; HQ by voice gives it up at the ring.
    func testARingEndsOnlyARoomThatYieldsAtTheRing() async {
        let stack = makeStack()
        let meeting = MarginRoom(yieldsAtRing: false)
        stack.claimRoom(meeting)
        await stack.ringArrived()
        XCTAssertTrue(stack.hasLiveRoom)
        XCTAssertEqual(meeting.yields, [])

        let voice = MarginRoom(yieldsAtRing: true)
        stack.claimRoom(voice)
        await stack.ringArrived()
        XCTAssertFalse(stack.hasLiveRoom)
        XCTAssertEqual(voice.yields, [.telephoneCall])
    }

    // MARK: - Switching workspaces

    func testTheFirstSelectionAndReselectingEndNothing() async throws {
        let stack = makeStack()
        let room = MarginRoom()
        let supervisor = MarginSupervisor()
        stack.claimRoom(room)
        stack.supervisor = supervisor

        stack.workspaceSelected("ws_a")
        stack.workspaceSelected(nil)
        stack.workspaceSelected("ws_a")
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(stack.hasLiveRoom)
        XCTAssertEqual(room.yields, [])
        XCTAssertEqual(supervisor.ends, 0)
    }

    /// ⛔ A SWITCH ENDS THE SUPERVISION, THE PENDING HQ ROOM AND THE ROOM, saying why.
    func testASwitchEndsSupervisionThePendingRoomAndTheRoom() async {
        let stack = makeStack()
        let room = MarginRoom()
        let supervisor = MarginSupervisor()
        let voice = MarginVoiceSession()
        stack.supervisor = supervisor
        stack.hqVoice = voice
        stack.workspaceSelected("ws_a")
        stack.claimRoom(room)

        stack.workspaceSelected("ws_b")
        await waitUntil(state: "yields=\(room.yields)") { !room.yields.isEmpty }

        XCTAssertEqual(room.yields, [.workspaceChanged])
        XCTAssertEqual(supervisor.ends, 1)
        XCTAssertEqual(voice.abandons, 1)
        XCTAssertFalse(stack.hasLiveRoom)
    }

    /// A nil between two workspaces is not forgotten as the last one: ws_a, nil, ws_b switches.
    func testANilBetweenTwoWorkspacesStillCountsAsASwitch() async {
        let stack = makeStack()
        let room = MarginRoom()
        stack.workspaceSelected("ws_a")
        stack.workspaceSelected(nil)
        stack.claimRoom(room)

        stack.workspaceSelected("ws_b")
        await waitUntil(state: "yields=\(room.yields)") { !room.yields.isEmpty }
        XCTAssertEqual(room.yields, [.workspaceChanged])
    }

    // MARK: - The softphone and the supervisor

    func testEndSoftphoneReachesOnlyASoftphone() async {
        let stack = makeStack()
        let softphone = MarginSoftphone()
        stack.softphone = softphone
        await stack.endSoftphone()
        XCTAssertEqual(softphone.ends, 1)

        let notOne = NSObject()
        stack.softphone = notOne
        await stack.endSoftphone()
        XCTAssertEqual(softphone.ends, 1)
    }

    func testEndSupervisionWithNoSupervisorIsHarmless() async {
        let stack = makeStack()
        await stack.endSupervision()
        let supervisor = MarginSupervisor()
        stack.supervisor = supervisor
        await stack.endSupervision()
        XCTAssertEqual(supervisor.ends, 1)
    }

    // MARK: - Ending HQ by voice

    func testEndVoiceSessionWaitsForAnEndThatFinishes() async {
        let stack = makeStack()
        let voice = MarginVoiceSession()
        stack.hqVoice = voice
        stack.voiceEndDeadline = { _ in try? await Task.sleep(for: .seconds(30)) }

        await stack.endVoiceSession()

        XCTAssertEqual(voice.ends, 1)
    }

    /// ⛔ AN END THAT NEVER RETURNS IS GIVEN UP ON AT THE DEADLINE, which is asked for in seconds.
    func testEndVoiceSessionGivesUpAtTheDeadline() async {
        let stack = makeStack()
        let voice = MarginVoiceSession(hangs: true)
        stack.hqVoice = voice
        let asked = MarginBox<TimeInterval>()
        stack.voiceEndDeadline = { seconds in await asked.set(seconds) }

        await stack.endVoiceSession()

        let seconds = await asked.value
        XCTAssertEqual(seconds, CallStack.voiceEndSeconds)
        XCTAssertEqual(CallStack.voiceEndSeconds, 3)
        await waitUntil(state: "ends=\(voice.ends)") { voice.ends == 1 }
        voice.release()
    }

    func testEndVoiceSessionWithoutASessionReturnsAtOnce() async {
        let stack = makeStack()
        stack.hqVoice = NSObject()
        let asked = MarginBox<TimeInterval>()
        stack.voiceEndDeadline = { seconds in await asked.set(seconds) }
        await stack.endVoiceSession()
        let seconds = await asked.value
        XCTAssertNil(seconds, "no session, no deadline")
    }

    func testABackgroundEndHoldsALeaseAroundTheEnd() async {
        let stack = makeStack()
        let voice = MarginVoiceSession()
        stack.hqVoice = voice
        let tasks = FakeBackgroundTasks()

        await stack.endVoiceSessionInBackground(on: tasks)

        XCTAssertEqual(voice.ends, 1)
        XCTAssertEqual(tasks.begun.count, 1)
        XCTAssertEqual(tasks.ended, tasks.begun)
    }

    func testABackgroundEndWithoutASessionTakesNoLease() async {
        let stack = makeStack()
        let tasks = FakeBackgroundTasks()
        await stack.endVoiceSessionInBackground(on: tasks)
        XCTAssertEqual(tasks.begun, [])
    }

    // MARK: - No call

    func testANewStackHasNoCallNoRoomAndNoEngine() {
        let stack = makeStack()
        XCTAssertFalse(stack.hasLiveCall)
        XCTAssertFalse(stack.hasLiveRoom)
        XCTAssertNil(stack.engine)
        stack.endCall()
        XCTAssertNil(stack.engine)
    }
}

// MARK: - Fakes

@MainActor
final class MarginRoom: RoomAudio {
    let yieldsAtRing: Bool
    private(set) var yields: [RoomAudioYield] = []

    init(yieldsAtRing: Bool = false) {
        self.yieldsAtRing = yieldsAtRing
    }

    func yieldAudio(_ reason: RoomAudioYield) async {
        yields.append(reason)
    }
}

@MainActor
final class MarginSupervisor: SupervisionEnding {
    private(set) var ends = 0

    func endSupervision() async {
        ends += 1
    }
}

@MainActor
final class MarginSoftphone: SoftphoneEnding {
    private(set) var ends = 0

    func endSoftphone() async {
        ends += 1
    }
}

@MainActor
final class MarginVoiceSession: PendingRoom, VoiceSessionEnding {
    private let hangs: Bool
    private var held: CheckedContinuation<Void, Never>?
    private(set) var ends = 0
    private(set) var abandons = 0

    init(hangs: Bool = false) {
        self.hangs = hangs
    }

    func abandon() async {
        abandons += 1
    }

    func end() async {
        ends += 1
        guard hangs else { return }
        await withCheckedContinuation { held = $0 }
    }

    /// Lets a hung end finish, so no continuation outlives the test.
    func release() {
        held?.resume()
        held = nil
    }
}

actor MarginBox<Value: Sendable> {
    private(set) var value: Value?

    func set(_ value: Value) {
        self.value = value
    }
}
