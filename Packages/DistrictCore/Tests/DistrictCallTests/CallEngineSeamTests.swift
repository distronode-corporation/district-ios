@testable import DistrictCall
import XCTest

/// A ``CallEngine`` whose every call is recorded and whose event stream a test
/// drives.
///
/// ⛔ IT EXISTS TO PROVE THE PROTOCOL IS SATISFIABLE ON LINUX, WHICH IS NOT A
/// TAUTOLOGY. The production implementation of this seam links LiveKit and
/// CallKit and can only be compiled on the macOS tier, so if the protocol had
/// grown a requirement that needed a Darwin type, nothing on this side would
/// notice until a macOS build picked it up. A conforming type here is
/// the compile-time half of the banned-import grep.
///
/// ⚠️ AN ACTOR, because the protocol is `Sendable` and the recorder is mutable
/// state a driver reaches from another task.
private actor RecordingCallEngine: CallEngine {
    private let continuation: AsyncStream<CallEngineEvent>.Continuation
    nonisolated let events: AsyncStream<CallEngineEvent>

    private(set) var calls: [CallCommand] = []
    var connectFailure: (any Error)?

    init() {
        var escaped: AsyncStream<CallEngineEvent>.Continuation!
        events = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    func failNextConnect(_ error: any Error) {
        connectFailure = error
    }

    func connect(url: String, token: String) async throws {
        calls.append(.connect(url: url, token: token))
        if let failure = connectFailure {
            // ⚠️ MIRRORS THE REAL ENGINE: the failure is emitted BEFORE the
            // throw, because a stream that only threw would leave the state
            // machine on `connecting` and a spinner over a call that will never
            // happen.
            continuation.yield(.failed(message: "\(failure)"))
            throw failure
        }
        continuation.yield(.connected)
    }

    func disconnect() async {
        calls.append(.disconnect)
        continuation.yield(.disconnected(reason: nil))
        continuation.finish()
    }

    func setMuted(_ muted: Bool) async {
        calls.append(.setMuted(muted))
        continuation.yield(.microphoneChanged(enabled: !muted))
    }

    func setSpeakerphone(_ enabled: Bool) async {
        calls.append(.setSpeakerphone(enabled))
    }

    /// Push a room event in, the way the SDK's own callbacks would.
    nonisolated func emit(_ event: CallEngineEvent) {
        continuation.yield(event)
    }
}

private struct SeamError: Error {}

final class CallEngineSeamTests: XCTestCase {
    /// Perform whatever a reducer asked for, the way a real driver would.
    private func perform(_ commands: [CallCommand], on engine: RecordingCallEngine) async throws {
        for command in commands {
            switch command {
            case let .connect(url, token):
                try await engine.connect(url: url, token: token)
            case .disconnect:
                await engine.disconnect()
            case let .setMuted(muted):
                await engine.setMuted(muted)
            case let .setSpeakerphone(enabled):
                await engine.setSpeakerphone(enabled)
            }
        }
    }

    /// Perform what the OUTBOUND reducer asked for.
    ///
    /// ⛔ IT UNWRAPS ``SoftphoneCommand/engine(_:)`` AND THE OTHER CASE REACHES NO
    /// SEAM ON THIS TIER, DELIBERATELY. ``SoftphoneCommand/reportCallEnded`` is a
    /// CallKit instruction and CallKit cannot be imported into this package at
    /// all, so what is provable here is that the list still carries the engine's
    /// half in the right order; that the report is EMITTED on the right endings is
    /// asserted against the reducer directly, in `SoftphoneSessionTests`.
    private func drive(_ commands: [SoftphoneCommand], on engine: RecordingCallEngine) async throws {
        for command in commands {
            guard case let .engine(engineCommand) = command else { continue }
            try await perform([engineCommand], on: engine)
        }
    }

    func testACallWalksFromTheEngineIntoTheReducerAndBack() async throws {
        let engine = RecordingCallEngine()
        var session = SoftphoneSession(number: testNumber)
        session.handle(.dialRequested)

        let credential = SoftphoneEvent.dialAccepted(
            url: testDialURL,
            token: testDialToken,
            callId: testDialCallId
        )
        try await drive(session.handle(credential), on: engine)
        session.handle(.engine(.connected))
        // ⚠️ The unmute the join produced is performed here, which is what makes
        // the recorded order real rather than asserted.
        try await perform([.setMuted(false)], on: engine)
        session.handle(.engine(.participantJoined(testCallee)))

        XCTAssertEqual(.connected, session.state.phase)
        let calls = await engine.calls
        XCTAssertEqual([.connect(url: testDialURL, token: testDialToken), .setMuted(false)], calls)
    }

    func testAThrowingConnectIsSwallowedAndSurfacesAsAFailedPhase() async {
        // ⛔ LETTING IT ESCAPE WOULD CRASH THE PROCESS OVER A NETWORK CONDITION.
        // The connection state IS the user-facing outcome.
        let engine = RecordingCallEngine()
        await engine.failNextConnect(SeamError())
        var session = SoftphoneSession.inDialing()

        let commands = session.handle(.dialAccepted(url: testDialURL, token: testDialToken, callId: testDialCallId))
        do {
            try await drive(commands, on: engine)
            XCTFail("the seam is documented as rethrowing")
        } catch {
            session.handle(.engine(.failed(message: "SeamError()")))
        }

        XCTAssertEqual(.ended(.failed(message: "SeamError()")), session.state.phase)
    }

    func testTheStreamDeliversEventsInTheOrderTheEngineEmittedThem() async {
        let engine = RecordingCallEngine()
        engine.emit(.connected)
        engine.emit(.audioRouteChanged(.bluetooth))
        engine.emit(.reconnecting)

        var session = SoftphoneSession.inConnecting()
        var seen = 0
        for await event in engine.events {
            session.handle(.engine(event))
            seen += 1
            if seen == 3 {
                break
            }
        }

        XCTAssertEqual(.ringing, session.state.phase)
        XCTAssertEqual(.bluetooth, session.state.media.audioRoute)
        XCTAssertTrue(session.state.media.reconnecting)
    }
}
