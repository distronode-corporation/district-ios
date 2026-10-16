import DistrictCall
import Foundation
import LiveKit
import OSLog

/// The SDK's own words for a failed join, a dropped room or a microphone that would not start.
///
/// ⛔ THE LOG IS WHERE THEY GO, NEVER THE SCREEN: they are LiveKit's English error
/// descriptions ("Room deleted"), and the end screen words every end from the catalog
/// (`InCallCopy.word(for:endedByOperator:)`). Public, because they carry no personal data.
private let callLog = Logger(subsystem: "com.distronode.district", category: "Call")

/// The one place in this app that talks to the LiveKit SDK.
///
/// ⛔ THIN BY POLICY, EXACTLY LIKE THE KOTLIN `LiveKitCallEngine`. Every line here
/// needs a device and a live socket to exercise, so it can carry no decision: the
/// state machines that decide anything are ``SoftphoneSession`` and
/// ``IncomingCallController`` in `DistrictCall`, where they are tested on Linux with
/// no media server. This class forwards, and it maps SDK callbacks onto
/// ``CallEngineEvent``. Anything that could be a pure function belongs on the other
/// side of the seam.
///
/// ⛔ ONE ENGINE PER CALL. ``CallEngine``'s own note says why: the engine holds a live
/// socket and a claim on the device's audio route, and a LiveKit `Room` does not
/// support a second `connect` after it has disconnected. This type builds its `Room`
/// once, in `init`, and is discarded with the call.
///
/// ⚠️ ``events`` IS READ EXACTLY ONCE, BY THE FEATURE MODEL THAT OWNS THE CALL — it is
/// handed over by ``CallStack/beginCall()``, and the reader is the dialer's model.
/// `AsyncStream` hands each element to a single consumer, so a second `for await`
/// would SPLIT the events between two readers rather than mirroring them, and the
/// reducer would silently miss half of them.
///
/// ⚠️ THE STREAM IS NEVER FINISHED. ``disconnect()`` is not the end of the events: the
/// SDK reports `didDisconnectWithError` afterwards and that is what carries the
/// reason. The owner stops reading when its reducer reaches a terminal phase, and the
/// continuation dies with this object.
///
/// ⚠️ `@unchecked Sendable` BECAUSE ``CallEngine`` REQUIRES `Sendable` AND NOTHING HERE
/// IS ISOLATED. Every stored property is a `let`; the only mutable state in the whole
/// path is inside the `Room` (which the SDK owns) and behind the coordinator's lock.
final class LiveKitCallEngine: CallEngine, @unchecked Sendable {
    let events: AsyncStream<CallEngineEvent>

    private let continuation: AsyncStream<CallEngineEvent>.Continuation

    private let audio: AudioSessionCoordinator

    /// ⚠️ HELD SO THE SDK'S WEAK DELEGATE REFERENCE HAS AN OWNER. `Room` does not
    /// retain its delegate; a bridge that lived only as an argument to `Room.init`
    /// would be deallocated immediately and every callback would go nowhere, with no
    /// error anywhere to say so.
    private let bridge: RoomEventBridge

    private let room: any CallRoom

    /// What runs before the join: the SDK's audio-session automation turned off, see
    /// ``connect(url:token:)``.
    private let prepareAudio: @Sendable () async -> Void

    /// Whether the join (and the microphone started after it) is still on its way.
    ///
    /// ⛔ ONE MICROPHONE TRACK PER CALL: see ``setMuted(_:)`` and `DistrictCall.CallJoinGate`.
    private let joinGate = CallJoinGate()

    convenience init(audio: AudioSessionCoordinator) {
        self.init(
            audio: audio,
            prepareAudio: { AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false },
            makeRoom: { LiveKitCallRoom(delegate: $0) }
        )
    }

    /// ⚠️ THE SEAM FOR TESTS: `makeRoom` is handed the bridge the room must report to.
    init(
        audio: AudioSessionCoordinator,
        prepareAudio: @escaping @Sendable () async -> Void,
        makeRoom: (RoomEventBridge) -> any CallRoom
    ) {
        let (stream, continuation) = AsyncStream<CallEngineEvent>.makeStream()
        events = stream
        self.continuation = continuation
        self.audio = audio
        self.prepareAudio = prepareAudio

        let bridge = RoomEventBridge(continuation: continuation)
        self.bridge = bridge
        room = makeRoom(bridge)

        // ⚠️ THE COORDINATOR IS THE ONLY SOURCE OF ``CallEngineEvent/audioRouteChanged(_:)``.
        // LiveKit has no route callback once its own audio-session automation is off,
        // and `AVAudioSession` publishes route changes whether or not a call is up.
        audio.observeRouteChanges { route in
            continuation.yield(.audioRouteChanged(route))
        }
    }

    /// Join the room.
    ///
    /// ⛔ THE AUDIO-SESSION AUTOMATION IS TURNED OFF BEFORE `connect`, NOT AFTER, AND
    /// THE SDK'S OWN SOURCE SAYS SO TWICE. LiveKit configures and activates
    /// `AVAudioSession` itself by default; with CallKit in the picture that is a second
    /// owner of the session, and the loser of that race is whichever one the system
    /// asked last. Setting it after `connect` leaves the first configuration already
    /// applied. ⛔ `customConfigureAudioSessionFunc` is deprecated (since 2.16.0) and
    /// must not be used to do this instead.
    ///
    /// ⛔ THE JOIN FIRST, THEN THE MICROPHONE, ONCE. The join publishes nothing
    /// (``LiveKitCallRoom``), so a slow Core Audio start can no longer hold the peer
    /// connections back until the transport times out (District AI for Mac 3.0.1,
    /// 2026-10-16: the session started and never became active; this engine joined the
    /// same way). ⛔ IT IS THE CALL'S ONE MICROPHONE TRACK, and the join gate opens only
    /// after it (``setMuted(_:)``), so the reducers' unmute on `.connected` is still
    /// dropped rather than publishing a second one.
    ///
    /// ⚠️ IT EMITS ``CallEngineEvent/failed(message:)`` AND THEN RETHROWS when the JOIN
    /// fails, which is what ``CallEngine/connect(url:token:)`` asks for: the connection
    /// state is the user-facing outcome and the owner swallows the error. The SDK may ALSO
    /// report `didFailToConnectWithError`, so a failed join can yield `.failed` twice, and
    /// both reducers make the first one terminal and absorb the second, so the duplicate
    /// costs nothing and is cheaper than trying to suppress one of them. A microphone that
    /// fails AFTER the join does not end the call, see ``startMicrophone()``.
    func connect(url: String, token: String) async throws {
        await prepareAudio()
        await joinGate.begin()
        do {
            try await room.connect(url: url, token: token)
        } catch {
            callLog.info("join failed: \(error.localizedDescription, privacy: .public)")
            await joinGate.finish(joined: false)
            continuation.yield(.failed(message: error.localizedDescription))
            throw error
        }
        await startMicrophone()
        await joinGate.finish(joined: true)
    }

    /// Publish the call's one microphone track, on a room already joined.
    ///
    /// ⛔ A MICROPHONE THAT CANNOT START LEAVES THE CALL CONNECTED AND SHOWN MUTED. The
    /// caller is on the line and can still be heard; ending the call would drop them, and
    /// `.failed` would word it "could not be connected", which is not what happened. The
    /// engine reports ``CallEngineEvent/microphoneChanged(enabled:)`` `false`, so the screen
    /// says muted (the truth: nobody hears this side), and the Unmute press reaches the SDK
    /// once the gate opens, which tries the microphone again. ⚠️ Yielded only after the
    /// room's `.connected` (``ConnectedLatch``): a reducer still answering drops it.
    private func startMicrophone() async {
        do {
            try await room.setMicrophone(enabled: true)
        } catch {
            callLog.info("microphone did not start: \(error.localizedDescription, privacy: .public)")
            await bridge.connectedReported()
            continuation.yield(.microphoneChanged(enabled: false))
        }
    }

    /// Leave and release the audio device.
    ///
    /// ⛔ IDEMPOTENT, AND EVERY HANG-UP PATH DEPENDS ON IT. `Room.disconnect()` is
    /// non-throwing and absorbs a room that has already gone; the button, the OS's own
    /// end-call affordance, a failed join and the owner tearing down all reach here.
    func disconnect() async {
        await room.disconnect()
    }

    /// Mute or unmute the local microphone.
    ///
    /// ⛔ NOTE THE POLARITY, AND NOTE WHAT IS EMITTED. `muted == true` means the caller
    /// hears silence, so the SDK is told the opposite. ``CallEngineEvent/microphoneChanged(enabled:)``
    /// is yielded ONLY after the SDK accepted the change — a refusal leaves
    /// ``CallMediaState/microphoneEnabled`` saying the microphone is live, which is the
    /// truth and the one direction that matters: the alternative invites somebody to
    /// speak on a line nobody can hear.
    ///
    /// ⛔ NOTHING REACHES THE SDK WHILE ``connect(url:token:)`` IS STILL STARTING THE
    /// MICROPHONE, and an unmute in that window is dropped (`CallJoinGate.admitsMute(_:)`).
    /// The room reports connected BEFORE the microphone is published, both reducers answer
    /// `.connected` with an unmute, and `setMicrophone(enabled: true)` in that gap would find
    /// no publication and publish a SECOND track (District AI for Mac 3.0.0, 2026-10-15, the
    /// same engine and the same reducers as here).
    func setMuted(_ muted: Bool) async {
        guard await joinGate.admitsMute(muted) else { return }
        let enabled = !muted
        do {
            try await room.setMicrophone(enabled: enabled)
            continuation.yield(.microphoneChanged(enabled: enabled))
        } catch {
            // ⛔ DELIBERATELY SILENT. See above: the state already says the microphone
            // is live, which is what the SDK just told us by refusing.
        }
    }

    /// ⚠️ NOT THE SDK'S JOB HERE. `AudioManager.shared.isSpeakerOutputPreferred` is
    /// documented as ignored once the host configures the session itself, which is
    /// exactly what `connect` arranges, so the route is overridden on `AVAudioSession`
    /// by ``AudioSessionCoordinator``.
    func setSpeakerphone(_ enabled: Bool) async {
        audio.setSpeakerphone(enabled)
    }
}

/// Turns `RoomDelegate` callbacks into ``CallEngineEvent`` values.
///
/// ⛔ AN `NSObject` BECAUSE `RoomDelegate` IS AN `@objc` PROTOCOL WHOSE MEMBERS ARE ALL
/// `@objc optional`, AND THAT MAKES EVERY SIGNATURE HERE LOAD-BEARING IN A WAY THE
/// COMPILER CANNOT CHECK. An optional requirement whose selector does not match is not
/// an error: the method simply never fires, and the symptom is a call that connects
/// and then reports nothing at all. Any change to a name or an argument label here has
/// to be checked against the SDK's declaration rather than against the build.
///
/// ⛔ FILE SCOPE, NOT NESTED IN ``LiveKitCallEngine``. A helper nested inside a type
/// that conforms to a protocol with associated types can be picked up as the witness,
/// and the error then surfaces somewhere else entirely — see `DistrictButtonVariant`.
///
/// ⚠️ THE CALLBACKS ARE NONISOLATED AND TOUCH NOTHING BUT THE CONTINUATION
/// AND THE LOG (`Logger` is thread-safe and needs no hop).
/// `AsyncStream.Continuation` is `Sendable` and `yield` is safe from any thread, so
/// nothing here needs an actor hop and nothing here may grow one: a hop would reorder
/// events, and the reducers on the other side of the seam are order-sensitive by
/// design.
///
/// ⚠️ NOT `private`: it is the argument of ``LiveKitCallEngine``'s room factory, the seam
/// the join-order tests use.
final class RoomEventBridge: NSObject, RoomDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CallEngineEvent>.Continuation

    /// Opens once the first `.connected` is on the stream; see ``ConnectedLatch``.
    private let connected = ConnectedLatch()

    init(continuation: AsyncStream<CallEngineEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Put `.connected` on the stream, then open the latch: in that order, so whatever waits
    /// on the latch is yielded after it.
    func reportConnected() {
        continuation.yield(.connected)
        connected.open()
    }

    /// Return once ``reportConnected()`` has run.
    func connectedReported() async {
        await connected.wait()
    }

    /// ⛔ `.disconnected` IS DELIBERATELY NOT MAPPED HERE. `didDisconnectWithError` is
    /// the callback that carries the reason, and it is the one that ends the call;
    /// yielding a bare `.disconnected(reason: nil)` from this callback as well would
    /// race it, and whichever arrived first would win — turning a reported failure into
    /// an ordinary hang-up half the time.
    ///
    /// ⚠️ AND THIS CALLBACK DOES NOT FIRE FOR A QUICK RECONNECT AT ALL, which is why
    /// `didStartReconnectWithMode` and `didCompleteReconnectWithMode` are implemented
    /// below rather than left to the connection state.
    @objc
    func room(
        _ room: Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        switch connectionState {
        case .connected:
            reportConnected()
        case .reconnecting:
            continuation.yield(.reconnecting)
        default:
            break
        }
    }

    /// ⚠️ A BANNER OVER A LIVE CALL, NEVER A FAILURE. See ``CallEngineEvent/reconnecting``:
    /// a phone handing over between wifi and its radio reconnects routinely.
    @objc
    func room(_ room: Room, didStartReconnectWithMode mode: ReconnectMode) {
        continuation.yield(.reconnecting)
    }

    /// ⚠️ ``CallEngineEvent/connected`` IS ALSO THE RECOVERY SIGNAL, which is exactly
    /// what this is. Without it a quick reconnect would leave the reconnecting banner
    /// up for the rest of a call that had already recovered.
    @objc
    func room(_ room: Room, didCompleteReconnectWithMode mode: ReconnectMode) {
        continuation.yield(.connected)
    }

    @objc
    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        if let error {
            callLog.info("join failed: \(error.localizedDescription, privacy: .public)")
        }
        continuation.yield(.failed(message: error?.localizedDescription))
    }

    /// ⚠️ A nil ERROR IS THE CLEAN DISCONNECT, and `reason: nil` is what both reducers
    /// read as an ordinary end rather than a fault.
    @objc
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        if let error {
            callLog.info("room disconnected: \(error.localizedDescription, privacy: .public)")
        }
        continuation.yield(.disconnected(reason: error?.localizedDescription))
    }

    /// ⛔ ON AN OUTBOUND CALL THIS IS THE ANSWER SIGNAL AND THE ONLY ONE THIS CLIENT
    /// HAS. See ``CallEngineEvent/participantJoined(_:)``: the dial route returns as
    /// soon as the carrier accepts, and the SIP bridge adds the callee at pickup.
    @objc
    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        continuation.yield(.participantJoined(Self.participant(participant)))
    }

    @objc
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        continuation.yield(.participantLeft(Self.participant(participant)))
    }

    /// ⚠️ THE SDK'S OWN CLASSIFICATION FOR `isAgent`, NEVER AN IDENTITY PREFIX. The
    /// transcription companion joins with the Agents framework's agent kind and a
    /// default `agent-<jobId>` identity; the prefix is a fallback the web keeps for a
    /// retired browser-side participant, not the primary test.
    ///
    /// ⚠️ A BLANK NAME BECOMES nil, matching the Kotlin mapper: an empty string would
    /// render as a participant with a name that is one space wide.
    private static func participant(_ participant: RemoteParticipant) -> CallParticipant {
        let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CallParticipant(
            identity: participant.identity?.stringValue ?? "",
            name: (name?.isEmpty ?? true) ? nil : name,
            isAgent: participant.kind == .agent
        )
    }
}
