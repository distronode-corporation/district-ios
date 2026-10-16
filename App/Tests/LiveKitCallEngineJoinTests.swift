@testable import DistrictAI
import DistrictCall
import Foundation
import LiveKit
import XCTest

/// The order of the SDK calls a softphone call makes (3.0.1): the join publishes nothing,
/// then exactly one microphone start, and the reducers' unmute on `.connected` never
/// reaches the SDK while that start is on its way. And (3.0.2) the join subscribes to
/// nothing, the room's audio being subscribed after it by `RemoteAudioSubscriber`.
///
/// ⛔ WHY: LiveKit's concurrent microphone mode ran the Core Audio start on the queue the
/// join builds its peer connections on, and a slow start held the join until its transport
/// timed out (District AI for Mac 3.0.1, 2026-10-16, 05:46:05Z: the session started, never
/// became active, and the call ended "could not be connected"). This engine joined the same
/// way.
@MainActor
final class LiveKitCallEngineJoinTests: XCTestCase {
    private struct Refused: Error {}

    /// A room that records every SDK call, and can hold the microphone start open.
    private final class FakeRoom: CallRoom, @unchecked Sendable {
        private let lock = NSLock()
        private let bridge: RoomEventBridge
        private var recorded: [String] = []
        private var heldStart: CheckedContinuation<Void, Never>?
        private var holdsStart = false

        var connectError: Error?
        var microphoneError: Error?

        init(bridge: RoomEventBridge) {
            self.bridge = bridge
        }

        var calls: [String] {
            lock.withLock { recorded }
        }

        var isHoldingStart: Bool {
            lock.withLock { heldStart != nil }
        }

        func holdMicrophoneStart() {
            lock.withLock { holdsStart = true }
        }

        func releaseMicrophoneStart() {
            let held: CheckedContinuation<Void, Never>? = lock.withLock {
                let held = heldStart
                heldStart = nil
                holdsStart = false
                return held
            }
            held?.resume()
        }

        func connect(url _: String, token _: String) async throws {
            record("connect")
            if let connectError {
                throw connectError
            }
            bridge.reportConnected()
        }

        func setMicrophone(enabled: Bool) async throws {
            record("setMicrophone(\(enabled))")
            let hold = lock.withLock { holdsStart }
            if hold {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.withLock { heldStart = continuation }
                }
            }
            if enabled, let microphoneError {
                throw microphoneError
            }
        }

        func disconnect() async {
            record("disconnect")
        }

        private func record(_ call: String) {
            lock.withLock { recorded.append(call) }
        }
    }

    private func makeEngine() -> (LiveKitCallEngine, FakeRoom) {
        var made: FakeRoom?
        let audio = AudioSessionCoordinator(notificationCenter: NotificationCenter())
        let engine = LiveKitCallEngine(audio: audio, prepareAudio: {}, makeRoom: { bridge in
            let room = FakeRoom(bridge: bridge)
            made = room
            return room
        })
        guard let room = made else {
            fatalError("the engine did not build its room")
        }
        return (engine, room)
    }

    private func firstEvents(_ engine: LiveKitCallEngine, _ count: Int) async -> [CallEngineEvent] {
        var events: [CallEngineEvent] = []
        for await event in engine.events {
            events.append(event)
            if events.count == count {
                break
            }
        }
        return events
    }

    func testTheJoinPublishesNothingAndThenStartsTheMicrophoneOnce() async throws {
        let (engine, room) = makeEngine()

        try await engine.connect(url: "wss://media.example", token: "token")

        XCTAssertEqual(room.calls, ["connect", "setMicrophone(true)"])
    }

    func testAnUnmuteWhileTheMicrophoneStartsNeverReachesTheSDK() async throws {
        let (engine, room) = makeEngine()
        room.holdMicrophoneStart()

        let joining = Task { try await engine.connect(url: "wss://media.example", token: "token") }
        await waitUntil(state: "\(room.calls)") { room.isHoldingStart }
        // The reducers answer `.connected` with exactly this.
        await engine.setMuted(false)
        room.releaseMicrophoneStart()
        try await joining.value

        XCTAssertEqual(room.calls, ["connect", "setMicrophone(true)"])
    }

    func testAMuteWhileTheMicrophoneStartsWaitsForItAndThenMutesIt() async throws {
        let (engine, room) = makeEngine()
        room.holdMicrophoneStart()

        let joining = Task { try await engine.connect(url: "wss://media.example", token: "token") }
        await waitUntil(state: "\(room.calls)") { room.isHoldingStart }
        let muting = Task { await engine.setMuted(true) }
        room.releaseMicrophoneStart()
        try await joining.value
        await muting.value

        XCTAssertEqual(room.calls, ["connect", "setMicrophone(true)", "setMicrophone(false)"])
    }

    func testAMicrophoneThatCannotStartLeavesTheCallConnectedAndShownMuted() async throws {
        let (engine, room) = makeEngine()
        room.microphoneError = Refused()

        try await engine.connect(url: "wss://media.example", token: "token")
        let events = await firstEvents(engine, 2)

        XCTAssertEqual(events, [.connected, .microphoneChanged(enabled: false)])
        // The Unmute press reaches the SDK and tries the microphone again.
        room.microphoneError = nil
        await engine.setMuted(false)
        XCTAssertEqual(room.calls, ["connect", "setMicrophone(true)", "setMicrophone(true)"])
    }

    func testAFailedJoinStartsNoMicrophoneAndReportsTheFailure() async {
        let (engine, room) = makeEngine()
        room.connectError = Refused()

        do {
            try await engine.connect(url: "wss://media.example", token: "token")
            XCTFail("a failed join must rethrow")
        } catch {}
        let events = await firstEvents(engine, 1)

        XCTAssertEqual(room.calls, ["connect"])
        guard case .failed = events.first else {
            return XCTFail("expected .failed, got \(events)")
        }
        // Nothing is left to mute after a failed join.
        await engine.setMuted(true)
        XCTAssertEqual(room.calls, ["connect"])
    }

    // ── Below the seam: what `LiveKitCallRoom` hands the SDK ─────────────────────────

    /// ⛔ WHY (3.0.2): with auto-subscribe the server's first offer carries the remote audio,
    /// applying it starts the speaker on WebRTC's worker thread, and the answer the join
    /// waits for is sent only after that (District AI for Mac 3.0.1 build 20062,
    /// 2026-10-16, 07:07:03Z). The subscribe itself needs a media server, so the order is
    /// pinned here by its two halves: these options, and the subscriber's callback below.
    func testTheSoftphoneJoinsWithNothingPublishedAndNothingSubscribed() {
        XCTAssertFalse(LiveKitCallRoom.connectOptions.autoSubscribe)
        XCTAssertFalse(LiveKitCallRoom.connectOptions.enableMicrophone)
    }

    /// ⛔ AN `@objc optional` SELECTOR THAT DOES NOT MATCH IS NO ERROR, the callback simply
    /// never fires, and a track published after the join would never be heard. Both sides
    /// are checked: the SDK still declares the selector, and the subscriber answers it.
    func testTheAudioSubscriberAnswersTheSDKsRemotePublishCallback() {
        let selector = NSSelectorFromString("room:remoteParticipant:didPublishTrack:")
        let declared = protocol_getMethodDescription(RoomDelegate.self, selector, false, true)

        XCTAssertEqual(declared.name, selector, "RoomDelegate no longer declares \(selector)")
        XCTAssertTrue(RemoteAudioSubscriber().responds(to: selector))
    }
}
