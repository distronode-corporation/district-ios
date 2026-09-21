import DistrictCall
import Foundation
import LiveKit

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

    private let room: Room

    init(audio: AudioSessionCoordinator) {
        let (stream, continuation) = AsyncStream<CallEngineEvent>.makeStream()
        events = stream
        self.continuation = continuation
        self.audio = audio

        let bridge = RoomEventBridge(continuation: continuation)
        self.bridge = bridge
        // ⚠️ NO `roomOptions`. `adaptiveStream` and `dynacast` are video-only knobs and
        // ⛔ the softphone publishes no video at all, in either direction; the audio
        // capture and publish defaults are what a phone call wants.
        room = Room(delegate: bridge)

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
    /// ⚠️ IT EMITS ``CallEngineEvent/failed(message:)`` AND THEN RETHROWS, which is
    /// what ``CallEngine/connect(url:token:)`` asks for: the connection state is the
    /// user-facing outcome and the owner swallows the error. The SDK may ALSO report
    /// `didFailToConnectWithError`, so a failed join can yield `.failed` twice — both
    /// reducers make the first one terminal and absorb the second, so the duplicate
    /// costs nothing and is cheaper than trying to suppress one of them.
    func connect(url: String, token: String) async throws {
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        do {
            // ⚠️ `enableMicrophone: true` PUBLISHES THE MIC CONCURRENTLY WITH THE JOIN
            // rather than after it, which is what stops the first second of a call
            // being silent. It matches ``CallMediaState/microphoneEnabled`` defaulting
            // to true: a softphone that joined muted would put the operator on a call
            // the callee cannot hear.
            try await room.connect(
                url: url,
                token: token,
                connectOptions: ConnectOptions(enableMicrophone: true)
            )
        } catch {
            continuation.yield(.failed(message: error.localizedDescription))
            throw error
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
    func setMuted(_ muted: Bool) async {
        let enabled = !muted
        do {
            try await room.localParticipant.setMicrophone(enabled: enabled)
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
/// ⚠️ THE CALLBACKS ARE NONISOLATED AND TOUCH NOTHING BUT THE CONTINUATION.
/// `AsyncStream.Continuation` is `Sendable` and `yield` is safe from any thread, so
/// nothing here needs an actor hop and nothing here may grow one: a hop would reorder
/// events, and the reducers on the other side of the seam are order-sensitive by
/// design.
private final class RoomEventBridge: NSObject, RoomDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CallEngineEvent>.Continuation

    init(continuation: AsyncStream<CallEngineEvent>.Continuation) {
        self.continuation = continuation
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
            continuation.yield(.connected)
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
        continuation.yield(.failed(message: error?.localizedDescription))
    }

    /// ⚠️ A nil ERROR IS THE CLEAN DISCONNECT, and `reason: nil` is what both reducers
    /// read as an ordinary end rather than a fault.
    @objc
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
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
