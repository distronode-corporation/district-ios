/// The seam between this app and the realtime-media SDK.
///
/// ⛔ NO LIVEKIT TYPE CROSSES THIS PROTOCOL, AND ON THIS TARGET THAT IS ENFORCED
/// RATHER THAN AGREED. CI's `verify` job greps `Packages/DistrictCore` for an
/// `import LiveKit` (and for UIKit, SwiftUI, Security, AuthenticationServices,
/// CallKit and PushKit) and fails the job, so the SDK — and its WebRTC natives —
/// stays in `App/`, behind this. A capability the call surface needs is a member
/// HERE, never a reason to hand the SDK's own objects up.
///
/// ⛔ ONE ENGINE PER CALL, OWNED BY WHOEVER OWNS THE SESSION. The engine holds a
/// live socket and the device's audio route; two instances fight over audio
/// focus, and the LiveKit `Room` a production implementation wraps does not
/// support a second `connect` after it has disconnected.
///
/// ⚠️ THE KOTLIN CLIENT EXPOSES FOUR `StateFlow`s WHERE THIS EXPOSES ONE STREAM,
/// and the reason is that a `StateFlow` is a live object that cannot be replayed
/// into a synchronous reducer. Everything those flows carried is a
/// ``CallEngineEvent`` here — the connection state, the participant list, the
/// microphone flag — so a state machine can be driven by handing it a list of
/// events with no clock, no task and no media server. That is the whole reason
/// this target exists.
///
/// ⚠️ ``events`` IS ONE STREAM PER ENGINE AND MUST BE READ ONCE.
/// `AsyncStream` delivers each element to a single consumer, so a second `for
/// await` over the same engine silently splits the events between two readers
/// rather than mirroring them. The owner reads it and feeds the reducer.
public protocol CallEngine: Sendable {
    /// Everything the media session reports, in order. See the note on reading
    /// it exactly once.
    var events: AsyncStream<CallEngineEvent> { get }

    /// Join the room.
    ///
    /// ⛔ THE url/token PAIR IS USED VERBATIM AND IS NEVER DERIVED. The room
    /// exists only on the deployment that CREATED it — the TRUNK's for an
    /// outbound dial, the US SIP bridge's for an inbound call, neither of which
    /// is necessarily the workspace's own region — so a client that built a URL
    /// from its region would join a bus that has never heard of this room while
    /// the call it belongs to is live and billed.
    ///
    /// ⚠️ IT THROWS, AND THE OWNER SWALLOWS IT. A production implementation
    /// emits ``CallEngineEvent/failed(message:)`` and then rethrows; the
    /// connection state is the user-facing outcome, so letting the error escape
    /// would crash the process over a network condition.
    func connect(url: String, token: String) async throws

    /// Leave and release the audio device.
    ///
    /// ⛔ IDEMPOTENT, AND EVERY HANG-UP PATH DEPENDS ON IT. The button, the OS's
    /// own end-call affordance, a failed join and the owner tearing down all
    /// reach a disconnect, and a call that has already ended must absorb a second
    /// one without error. The reducers here emit exactly one, but they cannot
    /// stop the OS from ending a call that ended a moment ago.
    func disconnect() async

    /// Mute or unmute the local microphone.
    ///
    /// ⛔ THE POLARITY IS INVERTED FROM THE KOTLIN CLIENT'S
    /// `setMicrophoneEnabled(enabled)`, AND THE TWO ARE ONE `!` APART. `muted ==
    /// true` means the caller hears silence. ``CallMediaState/microphoneEnabled``
    /// is stated the Kotlin way because it is what a screen renders; the command
    /// is stated the CallKit way because that is what the platform's own mute
    /// action carries. Read both spellings before changing either.
    func setMuted(_ muted: Bool) async

    /// Route audio to the loudspeaker (true) or to the earpiece/default (false).
    func setSpeakerphone(_ enabled: Bool) async
}

/// What the media session reports.
///
/// ⛔ ALL VALUE TYPES, WITH NO HANDLE TO ANYTHING THE SDK OWNS. In particular
/// there is no video-track case: the Kotlin `CallEngine` carries an opaque
/// `VideoTrackHandle` for the meeting grid, and a CALL never needs one — ⛔ the
/// softphone publishes no video at all, in either direction. Keeping the box out
/// of this target is what makes that structural instead of a comment.
public enum CallEngineEvent: Sendable, Equatable {
    /// The room is joined. ⚠️ ALSO THE RECOVERY SIGNAL after
    /// ``reconnecting``, so it is not only a first-connect event.
    case connected

    /// The session ended. `reason` is display-safe or nil.
    case disconnected(reason: String?)

    /// The SDK lost the session and is resuming it by itself.
    ///
    /// ⚠️ A BANNER OVER A LIVE CALL, NEVER A FAILURE AND NEVER A PHASE. A phone
    /// handing over between wifi and its radio reconnects routinely; a client
    /// that treated this as ``failed(message:)`` would hang up calls that were
    /// about to survive the ordinary event this case exists to describe.
    case reconnecting

    /// Someone other than the local participant joined.
    ///
    /// ⛔ ON AN OUTBOUND CALL THIS IS THE ANSWER SIGNAL AND THE ONLY ONE THIS
    /// CLIENT HAS. `POST /api/district/calls/dial` returns as soon as the carrier
    /// accepts, deliberately, so the app can be in the room hearing ring-back
    /// while the far end is still ringing; the SIP bridge adds the callee as a
    /// participant at pickup. ⛔ It means nothing of the kind on an INBOUND call,
    /// where the room already contains the caller and the AI — see
    /// ``IncomingCallController``.
    case participantJoined(CallParticipant)

    /// Someone left. ⚠️ After the answer, an emptying room is the far end hanging
    /// up rather than a room that was never occupied.
    case participantLeft(CallParticipant)

    /// The device changed where call audio is going.
    ///
    /// ⚠️ THE KOTLIN CLIENT HAS NO EQUIVALENT AND SAYS SO: its `CallEngine`
    /// "exposes no route to read back", so its speaker flag is documented as the
    /// screen's own belief rather than the device's state. AVAudioSession does
    /// publish route changes, so this client can hold both — what was ASKED for
    /// in ``CallMediaState/speakerRequested`` and what the device REPORTED in
    /// ``CallMediaState/audioRoute`` — and never has to pass one off as the
    /// other.
    case audioRouteChanged(AudioRoute)

    /// The local microphone's real state, as the SDK sees it.
    ///
    /// ⛔ THE STATE MIRRORS THIS RATHER THAN THE COMMAND. A reducer that flipped
    /// its own flag on ``CallCommand/setMuted(_:)`` would show an unmuted
    /// microphone for a mute that the SDK refused, which is the one direction
    /// that matters: it invites someone to speak on a line nobody can hear.
    case microphoneChanged(enabled: Bool)

    /// The session could not be established, or was lost for good.
    case failed(message: String?)
}

/// One remote participant, as much of them as a call surface renders.
public struct CallParticipant: Hashable, Sendable {
    /// The server-derived stable identity (`user-<hash>` from the token routes).
    ///
    /// ⚠️ THE EVICTION KEY, which is what stops the same human appearing twice
    /// after a reconnect.
    public let identity: String

    /// The display name, when the server sent one.
    public let name: String?

    /// True for a participant the server joined as a service rather than a
    /// person.
    ///
    /// ⛔ REPORTED BY THE SDK, NEVER INFERRED FROM ``identity``. The
    /// transcription companion joins with the Agents framework's `kind = AGENT`
    /// and a default `agent-<jobId>` identity and publishes no media; the
    /// identity prefix is a fallback the web keeps for a retired browser-side
    /// participant, not the primary test.
    public let isAgent: Bool

    public init(identity: String, name: String? = nil, isAgent: Bool = false) {
        self.identity = identity
        self.name = name
        self.isAgent = isAgent
    }
}

/// Where the device is putting call audio.
///
/// ⚠️ REPORTED, NOT REQUESTED. ``CallMediaState/speakerRequested`` is the ask;
/// this is the answer, and they disagree whenever something with a stronger claim
/// (a headset, a car) is attached.
public enum AudioRoute: String, Sendable, Equatable {
    case earpiece
    case speaker
    case bluetooth
    case wired
    /// The platform reported a route this build does not model. ⚠️ Rendered as
    /// "unknown", never silently as ``earpiece``.
    case unknown
}

/// What a state machine asks the engine to do.
///
/// ⛔ COMMANDS RATHER THAN CALLS, WHICH IS WHAT MAKES ORDER TESTABLE WITHOUT A
/// MEDIA SERVER. "The microphone is turned on before the OS is told the call is
/// active", "hang-up disconnects exactly once", "a decline sends nothing" are all
/// assertions about a list of values here, on Linux, rather than about a
/// recorder wrapped around a live SDK.
///
/// ⛔ THERE IS NO CAMERA COMMAND, ON PURPOSE. See ``CallEngineEvent``.
///
/// ⚠️ NEITHER REDUCER EMITS ONE OF THESE BARE, AND THAT IS DELIBERATE RATHER THAN
/// CEREMONY. Each wraps it — ``IncomingCallCommand/engine(_:)`` and
/// ``SoftphoneCommand/engine(_:)`` — because a call also has to tell the OS
/// things the engine knows nothing about, and the OS half cannot be expressed
/// here: this enum is the seam onto ``CallEngine`` and the whole of its meaning
/// is "hand this to the media session". A `reportCallEnded` case added to THIS
/// type would reach `CallStack.perform(_:)`, which drops any command that arrives
/// with no engine — silently, on exactly the refused-dial path that needs it
/// most.
public enum CallCommand: Sendable, Equatable {
    /// ⛔ Both halves verbatim. See ``CallEngine/connect(url:token:)``.
    case connect(url: String, token: String)
    case disconnect
    /// ⛔ Note the polarity. See ``CallEngine/setMuted(_:)``.
    case setMuted(Bool)
    case setSpeakerphone(Bool)
}

/// Why a call is over.
///
/// ⛔ ONE VOCABULARY FOR BOTH DIRECTIONS, SO A SCREEN CANNOT LEARN THE OUTCOME OF
/// AN INBOUND CALL AND AN OUTBOUND ONE FROM TWO DIFFERENT ENUMS. The Kotlin
/// client derives its ended-ness from three separate flags spread over two
/// classes (`ended`, a `Disconnected` connection state, and a `FailureText`),
/// which is why its outbound phase computation carries a comment explaining that
/// two of its phases look identical in the connection state alone.
public enum CallEndReason: Sendable, Equatable {
    /// This device hung up: the button, or the OS's own end-call affordance.
    ///
    /// ⛔ BOTH HALVES OF THAT SENTENCE WENT THROUGH A `CXEndCallAction`, WHICH IS
    /// WHAT MAKES THIS REASON LOAD-BEARING RATHER THAN DESCRIPTIVE. The in-app
    /// button asks CallKit for one before it feeds the reducer and the OS's own
    /// affordance IS one, so the system already knows the call is over and must
    /// not be told again — see ``SoftphoneSession/exitCommands(for:)``, which
    /// decides on exactly this case.
    case hungUpLocally

    /// The far end left an ANSWERED call. ⚠️ Distinguished from
    /// ``remoteEnded(reason:)`` because it is the ordinary way a conversation
    /// finishes, and the elapsed duration is the billed length.
    case remoteHungUp

    /// The media session ended without this device asking. Before the answer
    /// that is the callee declining or the dial failing at the carrier; after it,
    /// the far end dropping.
    case remoteEnded(reason: String?)

    /// The media session could not be established.
    ///
    /// ⚠️ DISTINCT FROM A REFUSED DIAL, which never produced a call at all — see
    /// ``SoftphoneEvent/dialRefused``.
    case failed(message: String?)

    /// The user refused an inbound call.
    ///
    /// ⛔ NOTHING IS SENT TO THE SERVER FOR THIS, AND THE SAME IS TRUE OF
    /// ``ringTimedOut``. See ``IncomingCallController``, which owns the reasoning
    /// — the two must be indistinguishable from outside, and the only way to
    /// guarantee that is for neither to send anything.
    case declined

    /// Nobody answered before the local ring timeout.
    case ringTimedOut

    /// The caller hung up before the answer landed.
    ///
    /// ⚠️ LEARNED AT ANSWER TIME RATHER THAN PUSHED. There is no cancel push on
    /// either client, so the only way this becomes known is that the answer round
    /// trip comes back saying the call is already over.
    case callerCancelled

    /// The server refused this device's answer, e.g. a viewer's 403.
    ///
    /// ⚠️ REACHABLE BY AN ORDINARY USER. The ring is fanned out to every
    /// registered device in the workspace without consulting roles, so a viewer's
    /// phone genuinely rings and then meets the refusal.
    case answerRefused(message: String?)
}
