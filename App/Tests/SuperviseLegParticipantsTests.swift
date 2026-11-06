@testable import DistrictAI
import DistrictCall
import DistrictModel
import Foundation
import XCTest

/// ⛔ A PARTICIPANT PRESENT BEFORE THE JOIN LEAVES, AND THE SUPERVISION GOES ON (xhigh review of
/// PR #101, item 1).
///
/// The fake room behaves as LiveKit 2.17.0 does: the people already in the room are in its
/// connect response and are NEVER announced as `participantDidConnect`, while their leave still
/// fires `participantDidDisconnect`. Before the fix a supervise leg's count stayed at 0, so a web
/// supervisor who stopped listening read as the room emptying and `SuperviseSession` ended the
/// call.
@MainActor
final class SuperviseLegParticipantsTests: XCTestCase {
    private final class PresentRoom: CallRoom, @unchecked Sendable {
        let bridge: RoomEventBridge
        let present: [CallParticipant]

        init(bridge: RoomEventBridge, present: [CallParticipant]) {
            self.bridge = bridge
            self.present = present
        }

        func connect(url _: String, token _: String) async throws {
            // ⚠️ NO JOIN EVENTS FOR THE PEOPLE ALREADY HERE, exactly like the SDK.
            bridge.reportConnected()
        }

        func setMicrophone(enabled _: Bool) async throws {}
        func disconnect() async {}

        func presentParticipants() -> [CallParticipant] {
            present
        }
    }

    private let caller = CallParticipant(identity: "sip_caller", name: nil, isAgent: false)
    private let agent = CallParticipant(identity: "agent-1", name: "Ava", isAgent: true)
    private let webSupervisor = CallParticipant(identity: "user-web", name: "Alex (Supervisor)", isAgent: false)

    private func engine(announcing: Bool) -> (LiveKitCallEngine, PresentRoom) {
        var made: PresentRoom?
        let present = [caller, agent, webSupervisor]
        let engine = LiveKitCallEngine(
            audio: AudioSessionCoordinator(notificationCenter: NotificationCenter()),
            publishesMicrophone: false,
            announcesPresentParticipants: announcing,
            prepareAudio: {},
            makeRoom: { bridge in
                let room = PresentRoom(bridge: bridge, present: present)
                made = room
                return room
            }
        )
        guard let room = made else { fatalError("no room") }
        return (engine, room)
    }

    private func first(_ count: Int, of engine: LiveKitCallEngine) async -> [CallEngineEvent] {
        var events: [CallEngineEvent] = []
        for await event in engine.events {
            events.append(event)
            if events.count == count {
                break
            }
        }
        return events
    }

    /// The listen leg reaches `listening` with the reducer the app runs.
    private func listening(_ events: [CallEngineEvent]) -> SuperviseSession {
        var session = SuperviseSession(callId: "cmh1live", role: .agency)
        session.handle(.listenPressed)
        let commands = session.handle(.listenGranted(url: "wss://sfu.example.test", token: "t"))
        guard case let .join(_, generation, _, _)? = commands.first else { fatalError("no join") }
        for event in events {
            session.handle(.engine(.listen, generation: generation, event))
        }
        return session
    }

    func testAPresentParticipantLeavingDoesNotEndTheSupervision() async throws {
        let (engine, room) = engine(announcing: true)
        try await engine.connect(url: "wss://sfu.example.test", token: "t")
        // A late duplicate join is not counted twice; the web supervisor stops listening.
        room.bridge.participantConnected(agent)
        room.bridge.participantDisconnected(webSupervisor)

        let events = await first(5, of: engine)

        XCTAssertEqual(events, [
            .connected,
            .participantJoined(caller),
            .participantJoined(agent),
            .participantJoined(webSupervisor),
            .participantLeft(webSupervisor),
        ])
        let session = listening(events)
        XCTAssertEqual(session.state.phase, .listening)
        XCTAssertEqual(session.state.media.remoteParticipants, 2)
    }

    /// The room really emptying still ends it: the caller and the agent both leave.
    func testTheRoomEmptyingStillEndsTheSupervision() async throws {
        let (engine, room) = engine(announcing: true)
        try await engine.connect(url: "wss://sfu.example.test", token: "t")
        room.bridge.participantDisconnected(webSupervisor)
        room.bridge.participantDisconnected(agent)
        room.bridge.participantDisconnected(caller)

        let session = await listening(first(7, of: engine))

        XCTAssertEqual(session.state.phase, .over)
    }

    /// A leave for someone never counted is dropped, so the count cannot go below the room.
    func testALeaveForSomeoneNeverCountedIsDropped() async throws {
        let (engine, room) = engine(announcing: true)
        try await engine.connect(url: "wss://sfu.example.test", token: "t")
        room.bridge.participantDisconnected(CallParticipant(identity: "stranger", name: nil, isAgent: false))
        room.bridge.participantConnected(CallParticipant(identity: "late", name: nil, isAgent: false))

        let events = await first(5, of: engine)

        XCTAssertEqual(events.last, .participantJoined(CallParticipant(identity: "late", name: nil, isAgent: false)))
    }

    /// ⛔ THE DIALLER'S PATH IS UNCHANGED: without the flag nothing present is announced and a
    /// leave is passed through as before.
    func testWithoutTheFlagNothingPresentIsAnnounced() async throws {
        let (engine, room) = engine(announcing: false)
        try await engine.connect(url: "wss://sfu.example.test", token: "t")
        room.bridge.participantDisconnected(webSupervisor)

        let events = await first(2, of: engine)

        XCTAssertEqual(events, [.connected, .participantLeft(webSupervisor)])
    }

    // MARK: - The max review

    /// ⛔ THE SDK'S TEARDOWN LEAVES ARE NOT THE ROOM EMPTYING (item 3): on an eviction, a network
    /// loss or a full reconnect they fire while the room still lists everyone.
    func testTeardownLeavesWhileStillListedAreDropped() async throws {
        let (engine, room) = engine(announcing: true)
        try await engine.connect(url: "wss://sfu.example.test", token: "t")
        room.bridge.participantDisconnected(caller, stillInRoom: true)
        room.bridge.participantDisconnected(agent, stillInRoom: true)
        room.bridge.participantDisconnected(webSupervisor, stillInRoom: false)

        let events = await first(5, of: engine)

        XCTAssertEqual(events.last, .participantLeft(webSupervisor), "only the real leave")
        let session = listening(events)
        XCTAssertEqual(session.state.phase, .listening)
        XCTAssertEqual(session.state.media.remoteParticipants, 2)
    }

    /// A full reconnect brings the count back to the room as it now is.
    func testAFullReconnectRecountsTheRoom() async throws {
        let (engine, room) = engine(announcing: true)
        try await engine.connect(url: "wss://sfu.example.test", token: "t")
        let newAgent = CallParticipant(identity: "agent-2", name: "Ava", isAgent: true)
        room.bridge.recount([caller, newAgent])

        let events = await first(7, of: engine)

        XCTAssertEqual(Array(events.suffix(3)), [
            .participantLeft(CallParticipant(identity: "agent-1", name: nil, isAgent: false)),
            .participantLeft(CallParticipant(identity: "user-web", name: nil, isAgent: false)),
            .participantJoined(newAgent),
        ])
        XCTAssertEqual(listening(events).state.media.remoteParticipants, 2)
    }
}

/// ⛔ A TAKEOVER OVER THE REAL ENGINE: THE CARD SAYS THE MICROPHONE IS LIVE (max review of PR
/// #101, item 1). The reducer's unmute on `.connected` reaches the engine while its microphone
/// start is still on its way and is dropped by the join gate; only the engine reporting the start
/// tells the session the microphone is live. The fakes used to echo it and hid the bug.
@MainActor
final class SuperviseTakeoverMicrophoneTests: XCTestCase {
    private final class HeldMicrophoneRoom: CallRoom, @unchecked Sendable {
        let bridge: RoomEventBridge
        private let lock = NSLock()
        private var held: CheckedContinuation<Void, Never>?
        private var recorded: [String] = []

        init(bridge: RoomEventBridge) {
            self.bridge = bridge
        }

        var calls: [String] {
            lock.withLock { recorded }
        }

        var isHolding: Bool {
            lock.withLock { held != nil }
        }

        func connect(url _: String, token _: String) async throws {
            lock.withLock { recorded.append("connect") }
            bridge.reportConnected()
        }

        func setMicrophone(enabled: Bool) async throws {
            lock.withLock { recorded.append("setMicrophone(\(enabled))") }
            if enabled, calls.count == 2 {
                await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
            }
        }

        func release() {
            let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
                defer { held = nil }
                return held
            }
            continuation?.resume()
        }

        func disconnect() async {}
    }

    func testTheCoachMicrophoneIsReportedLiveOverTheRealEngine() async throws {
        var made: HeldMicrophoneRoom?
        let engine = LiveKitCallEngine(
            audio: AudioSessionCoordinator(notificationCenter: NotificationCenter()),
            publishesMicrophone: true,
            announcesPresentParticipants: true,
            prepareAudio: {},
            makeRoom: { bridge in
                let room = HeldMicrophoneRoom(bridge: bridge)
                made = room
                return room
            }
        )
        let room = try XCTUnwrap(made)

        var session = SuperviseSession(callId: "cmh1live", role: .agency)
        session.handle(.listenPressed)
        guard case let .join(_, listenGeneration, _, _)? = session.handle(.listenGranted(url: "u", token: "t")).first
        else { return XCTFail("no listen join") }
        session.handle(.engine(.listen, generation: listenGeneration, .connected))
        session.handle(.takeOverPressed)
        let granted = session.handle(.takeoverGranted(url: "u", token: "t"))
        guard case let .join(.takeover, generation, _, _)? = granted.last else { return XCTFail("no coach join") }

        let joining = Task { try await engine.connect(url: "u", token: "t") }
        var stream = engine.events.makeAsyncIterator()
        let connected = await stream.next()
        XCTAssertEqual(connected, .connected)
        for command in session.handle(.engine(.takeover, generation: generation, .connected)) {
            if case let .engine(_, .setMuted(muted)) = command {
                await engine.setMuted(muted)
            }
        }
        await waitUntil { room.isHolding }
        XCTAssertEqual(session.state.phase, .takenOver)
        XCTAssertFalse(session.state.media.microphoneEnabled, "still starting")

        room.release()
        try await joining.value
        let started = await stream.next()
        XCTAssertEqual(started, .microphoneChanged(enabled: true))
        try session.handle(.engine(.takeover, generation: generation, XCTUnwrap(started)))

        XCTAssertTrue(session.state.media.microphoneEnabled, "the card says the microphone is live")
        XCTAssertEqual(room.calls, ["connect", "setMicrophone(true)"], "one microphone track")
    }
}
